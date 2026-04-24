import Foundation
import Darwin

// MARK: - libmpv 核心 ABI

private let MPV_FORMAT_DOUBLE: Int32 = 5
private let MPV_EVENT_SHUTDOWN: Int32 = 1
private let MPV_EVENT_PROPERTY_CHANGE: Int32 = 22

private struct MPVEvent {
    var eventId: Int32
    var error: Int32
    var replyUserdata: UInt64
    var data: UnsafeMutableRawPointer?
}

private struct MPVEventProperty {
    var name: UnsafePointer<CChar>?
    var format: Int32
    var _pad: Int32
    var data: UnsafeMutableRawPointer?
}

// MARK: - Render API 常量

private let MPV_RENDER_PARAM_API_TYPE: Int32 = 1
private let MPV_RENDER_PARAM_OPENGL_INIT_PARAMS: Int32 = 2
private let MPV_RENDER_PARAM_OPENGL_FBO: Int32 = 3
private let MPV_RENDER_PARAM_FLIP_Y: Int32 = 4

// 对应 C 结构体 mpv_render_param { enum(4B) + pad(4B) + void*(8B) }
private struct MPVRenderParam {
    var type: Int32
    var _pad: Int32
    var data: UnsafeMutableRawPointer?
    init(_ t: Int32, _ d: UnsafeMutableRawPointer?) { type = t; _pad = 0; data = d }
}

// mpv_opengl_init_params
private struct MPVOpenGLInitParams {
    var get_proc_address: (@convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> UnsafeMutableRawPointer?)?
    var get_proc_address_ctx: UnsafeMutableRawPointer?
    var extra_exts: UnsafePointer<CChar>?
}

// mpv_opengl_fbo
private struct MPVOpenGLFBO {
    var fbo: Int32
    var w: Int32
    var h: Int32
    var internal_format: Int32
}

// MARK: - 函数指针（核心）

private typealias mpv_create_fn     = @convention(c) () -> OpaquePointer?
private typealias mpv_initialize_fn = @convention(c) (OpaquePointer) -> Int32
private typealias mpv_terminate_fn  = @convention(c) (OpaquePointer) -> Void
private typealias mpv_set_optstr_fn = @convention(c) (OpaquePointer, UnsafePointer<CChar>, UnsafePointer<CChar>) -> Int32
private typealias mpv_command_fn    = @convention(c) (OpaquePointer, UnsafePointer<UnsafePointer<CChar>?>) -> Int32
private typealias mpv_observe_fn    = @convention(c) (OpaquePointer, UInt64, UnsafePointer<CChar>, Int32) -> Int32
private typealias mpv_wait_event_fn = @convention(c) (OpaquePointer, Double) -> UnsafeRawPointer?

// MARK: - 函数指针（Render API）
// 参数用 UnsafeMutableRawPointer 回避 @convention(c) 对泛型指针的限制

private typealias mpv_render_context_create_fn = @convention(c) (
    UnsafeMutableRawPointer,   // mpv_render_context **res
    OpaquePointer,             // mpv_handle *mpv
    UnsafeMutableRawPointer    // mpv_render_param *params
) -> Int32

private typealias mpv_render_context_set_update_callback_fn = @convention(c) (
    OpaquePointer,
    (@convention(c) (UnsafeMutableRawPointer?) -> Void)?,
    UnsafeMutableRawPointer?
) -> Void

private typealias mpv_render_context_render_fn = @convention(c) (
    OpaquePointer,
    UnsafeMutableRawPointer   // mpv_render_param *params
) -> Int32

private typealias mpv_render_context_free_fn = @convention(c) (OpaquePointer) -> Void

// MARK: - OpenGL 符号查找（文件级函数，无捕获）

private let openGLHandle: UnsafeMutableRawPointer? =
    dlopen("/System/Library/Frameworks/OpenGL.framework/OpenGL", RTLD_LAZY | RTLD_LOCAL)

private func mpvGLGetProcAddress(
    _ ctx: UnsafeMutableRawPointer?,
    _ name: UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? {
    dlsym(openGLHandle, name)
}

// mpv 有新帧时的回调（不能捕获变量，通过 ctx 传递 MPVController 指针）
private func mpvRenderUpdateCallback(_ ctx: UnsafeMutableRawPointer?) {
    guard let ctx else { return }
    let ctrl = Unmanaged<MPVController>.fromOpaque(ctx).takeUnretainedValue()
    DispatchQueue.main.async { ctrl.onNeedsDisplay?() }
}

// MARK: - MPVController

/// 通过 dlopen 加载 libmpv.dylib，使用 Render API 将视频渲染到调用方提供的 GL FBO。
/// 不创建任何原生窗口。
final class MPVController {

    static let libraryPath: String? = [
        "/opt/homebrew/lib/libmpv.dylib",
        "/opt/homebrew/lib/libmpv.2.dylib",
        "/usr/local/lib/libmpv.dylib",
        "/usr/local/lib/libmpv.2.dylib",
    ].first { FileManager.default.fileExists(atPath: $0) }

    static var isAvailable: Bool { libraryPath != nil }

    private var lib: UnsafeMutableRawPointer?
    private(set) var ctx: OpaquePointer?
    private(set) var renderCtx: OpaquePointer?
    private var stopping = false

    var onTimeUpdate:   ((TimeInterval) -> Void)?
    var onNeedsDisplay: (() -> Void)?          // GL 层设置，新帧时触发 setNeedsDisplay

    // 核心
    private var fn_create:    mpv_create_fn?
    private var fn_init:      mpv_initialize_fn?
    private var fn_terminate: mpv_terminate_fn?
    private var fn_optStr:    mpv_set_optstr_fn?
    private var fn_cmd:       mpv_command_fn?
    private var fn_observe:   mpv_observe_fn?
    private var fn_wait:      mpv_wait_event_fn?

    // Render API
    private var fn_renderCreate:      mpv_render_context_create_fn?
    private var fn_renderSetCallback: mpv_render_context_set_update_callback_fn?
    private var fn_renderRender:      mpv_render_context_render_fn?
    private var fn_renderFree:        mpv_render_context_free_fn?

    private func sym<T>(_ name: String) -> T? {
        guard let s = dlsym(lib, name) else { return nil }
        return unsafeBitCast(s, to: T.self)
    }

    // MARK: - 公开 API

    /// 第一步：加载 libmpv、初始化、开始解码（可在 GL 层就绪前调用）
    @discardableResult
    func prepare(url: URL) -> Bool {
        guard let path = Self.libraryPath,
              let handle = dlopen(path, RTLD_NOW | RTLD_GLOBAL) else { return false }
        lib = handle

        fn_create    = sym("mpv_create")
        fn_init      = sym("mpv_initialize")
        fn_terminate = sym("mpv_terminate_destroy")
        fn_optStr    = sym("mpv_set_option_string")
        fn_cmd       = sym("mpv_command")
        fn_observe   = sym("mpv_observe_property")
        fn_wait      = sym("mpv_wait_event")

        fn_renderCreate      = sym("mpv_render_context_create")
        fn_renderSetCallback = sym("mpv_render_context_set_update_callback")
        fn_renderRender      = sym("mpv_render_context_render")
        fn_renderFree        = sym("mpv_render_context_free")

        guard let mpvCtx = fn_create?() else { return false }
        ctx = mpvCtx

        opt("no",     "osc")
        opt("no",     "input-default-bindings")
        opt("yes",    "keep-open")
        opt("quiet",  "msg-level")
        opt("libmpv", "vo")     // 使用 Render API，不创建原生窗口

        guard fn_init?(mpvCtx) == 0 else { return false }

        _ = fn_observe?(mpvCtx, 1, "time-pos", MPV_FORMAT_DOUBLE)
        cmd(["loadfile", url.path])

        Thread.detachNewThread { [weak self] in self?.eventLoop() }
        return true
    }

    /// 第二步：GL 上下文已 current 时调用，建立 mpv Render Context
    func setupRenderContext() {
        guard let mpvCtx = ctx, renderCtx == nil,
              let fn_renderCreate, let fn_renderSetCallback else {
            print("[MPV] setupRenderContext guard failed: ctx=\(ctx != nil) renderCtx=\(renderCtx != nil)")
            return
        }
        print("[MPV] setupRenderContext: creating render context...")

        var initParams = MPVOpenGLInitParams(
            get_proc_address: mpvGLGetProcAddress,
            get_proc_address_ctx: nil,
            extra_exts: nil
        )

        var renderOut: OpaquePointer? = nil

        // 用 withCString 保证 "opengl" 字符串在 C 调用期间指针有效
        "opengl".withCString { apiType in
            withUnsafeMutablePointer(to: &initParams) { initPtr in
                withUnsafeMutablePointer(to: &renderOut) { outPtr in
                    var params: [MPVRenderParam] = [
                        MPVRenderParam(MPV_RENDER_PARAM_API_TYPE,
                                       UnsafeMutableRawPointer(mutating: apiType)),
                        MPVRenderParam(MPV_RENDER_PARAM_OPENGL_INIT_PARAMS,
                                       UnsafeMutableRawPointer(initPtr)),
                        MPVRenderParam(0, nil),
                    ]
                    params.withUnsafeMutableBytes { buf in
                        let err = fn_renderCreate(
                            UnsafeMutableRawPointer(outPtr),
                            mpvCtx,
                            buf.baseAddress!
                        )
                        print("[MPV] mpv_render_context_create returned: \(err)")
                    }
                }
            }
        }

        guard let rc = renderOut else {
            print("[MPV] renderOut is nil after create!")
            return
        }
        print("[MPV] Render context created: \(rc)")
        renderCtx = rc

        fn_renderSetCallback(rc, mpvRenderUpdateCallback,
                             Unmanaged.passUnretained(self).toOpaque())
    }

    /// 第三步：每帧在 draw(inCGLContext:) 中调用
    func renderFrame(width: Int32, height: Int32) {
        guard let rc = renderCtx, width > 0, height > 0 else { return }

        var fbo   = MPVOpenGLFBO(fbo: 0, w: width, h: height, internal_format: 0)
        var flipY: Int32 = 1

        withUnsafeMutablePointer(to: &fbo) { fboPtr in
            withUnsafeMutablePointer(to: &flipY) { flipPtr in
                var params: [MPVRenderParam] = [
                    MPVRenderParam(MPV_RENDER_PARAM_OPENGL_FBO,  UnsafeMutableRawPointer(fboPtr)),
                    MPVRenderParam(MPV_RENDER_PARAM_FLIP_Y,      UnsafeMutableRawPointer(flipPtr)),
                    MPVRenderParam(0, nil),
                ]
                params.withUnsafeMutableBytes { buf in
                    _ = fn_renderRender?(rc, buf.baseAddress!)
                }
            }
        }
    }

    func seek(to time: TimeInterval) { cmd(["seek", String(time), "absolute"]) }
    func setPlaying(_ playing: Bool) { cmd(["set_property", "pause", playing ? "no" : "yes"]) }

    func stop() {
        stopping = true
        if let rc = renderCtx { fn_renderFree?(rc); renderCtx = nil }
        if let c  = ctx       { fn_terminate?(c);   ctx = nil }
        if lib != nil         { dlclose(lib);        lib = nil }
    }

    // MARK: - 内部工具

    private func opt(_ value: String, _ key: String) {
        guard let c = ctx else { return }
        _ = fn_optStr?(c, key, value)
    }

    private func cmd(_ args: [String]) {
        guard let c = ctx else { return }
        let ns = args.map { $0 as NSString }
        var ptrs: [UnsafePointer<CChar>?] = ns.map { $0.utf8String }
        ptrs.append(nil)
        _ = fn_cmd?(c, &ptrs)
    }

    private func eventLoop() {
        guard let c = ctx else { return }
        while !stopping {
            guard let raw = fn_wait?(c, 1.0) else { continue }
            let ev = raw.assumingMemoryBound(to: MPVEvent.self).pointee
            if ev.eventId == MPV_EVENT_SHUTDOWN { break }
            if ev.eventId == MPV_EVENT_PROPERTY_CHANGE, let d = ev.data {
                let prop = d.assumingMemoryBound(to: MPVEventProperty.self).pointee
                if prop.format == MPV_FORMAT_DOUBLE,
                   let dp = prop.data?.assumingMemoryBound(to: Double.self) {
                    let t = dp.pointee
                    if t >= 0 { DispatchQueue.main.async { [weak self] in self?.onTimeUpdate?(t) } }
                }
            }
        }
    }

    deinit { stop() }
}
