import Foundation
import Darwin
import CoreGraphics

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

private let MPV_RENDER_PARAM_API_TYPE: Int32           = 1
private let MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME: Int32 = 12
private let MPV_RENDER_PARAM_SW_SIZE: Int32            = 17
private let MPV_RENDER_PARAM_SW_FORMAT: Int32          = 18
private let MPV_RENDER_PARAM_SW_STRIDE: Int32          = 19
private let MPV_RENDER_PARAM_SW_POINTER: Int32         = 20

// C 结构体 mpv_render_param { enum(4B) + pad(4B) + void*(8B) }
private struct MPVRenderParam {
    var type: Int32
    var _pad: Int32
    var data: UnsafeMutableRawPointer?
    init(_ t: Int32, _ d: UnsafeMutableRawPointer?) { type = t; _pad = 0; data = d }
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

private typealias mpv_render_context_create_fn = @convention(c) (
    UnsafeMutableRawPointer, OpaquePointer, UnsafeMutableRawPointer
) -> Int32

private typealias mpv_render_context_set_update_callback_fn = @convention(c) (
    OpaquePointer,
    (@convention(c) (UnsafeMutableRawPointer?) -> Void)?,
    UnsafeMutableRawPointer?
) -> Void

private typealias mpv_render_context_render_fn = @convention(c) (
    OpaquePointer, UnsafeMutableRawPointer
) -> Int32

private typealias mpv_render_context_free_fn = @convention(c) (OpaquePointer) -> Void

// mpv 有新帧时的回调（文件级函数，不能从回调内部再调用任何 mpv API）
private func mpvRenderUpdateCallback(_ ctx: UnsafeMutableRawPointer?) {
    guard let ctx else { return }
    let ctrl = Unmanaged<MPVController>.fromOpaque(ctx).takeUnretainedValue()
    DispatchQueue.main.async { ctrl.onNeedsDisplay?() }
}

// MARK: - MPVController

/// 通过 dlopen 加载 libmpv，使用 SW Render API 将视频帧输出为 CGImage。
/// 不创建原生窗口，不依赖 OpenGL/Metal。
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
    /// 主线程调用；有新帧时触发，调用方负责调用 renderFrameAsCGImage 并更新显示
    var onNeedsDisplay: (() -> Void)?

    private var fn_create:    mpv_create_fn?
    private var fn_init:      mpv_initialize_fn?
    private var fn_terminate: mpv_terminate_fn?
    private var fn_optStr:    mpv_set_optstr_fn?
    private var fn_cmd:       mpv_command_fn?
    private var fn_observe:   mpv_observe_fn?
    private var fn_wait:      mpv_wait_event_fn?

    private var fn_renderCreate:      mpv_render_context_create_fn?
    private var fn_renderSetCallback: mpv_render_context_set_update_callback_fn?
    private var fn_renderRender:      mpv_render_context_render_fn?
    private var fn_renderFree:        mpv_render_context_free_fn?

    private func sym<T>(_ name: String) -> T? {
        guard let s = dlsym(lib, name) else { return nil }
        return unsafeBitCast(s, to: T.self)
    }

    // MARK: - 公开 API

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
        opt("libmpv", "vo")

        guard fn_init?(mpvCtx) == 0 else { return false }

        // render context 必须在 loadfile 之前建立，否则 mpv 找不到 VO 直接跳过视频
        setupRenderContext()

        _ = fn_observe?(mpvCtx, 1, "time-pos", MPV_FORMAT_DOUBLE)
        cmd(["loadfile", url.path])

        Thread.detachNewThread { [weak self] in self?.eventLoop() }
        return true
    }

    func setupRenderContext() {
        guard let mpvCtx = ctx, renderCtx == nil,
              let fn_renderCreate, let fn_renderSetCallback else { return }

        var renderOut: OpaquePointer? = nil
        "sw".withCString { apiType in
            withUnsafeMutablePointer(to: &renderOut) { outPtr in
                var params: [MPVRenderParam] = [
                    MPVRenderParam(MPV_RENDER_PARAM_API_TYPE,
                                   UnsafeMutableRawPointer(mutating: apiType)),
                    MPVRenderParam(0, nil),
                ]
                params.withUnsafeMutableBytes { buf in
                    let err = fn_renderCreate(
                        UnsafeMutableRawPointer(outPtr), mpvCtx, buf.baseAddress!)
                    print("[MPV] render_context_create(sw) → \(err)")
                }
            }
        }

        guard let rc = renderOut else { print("[MPV] renderOut nil"); return }
        renderCtx = rc
        // 注册新帧回调；注册后会立即触发一次回调
        fn_renderSetCallback(rc, mpvRenderUpdateCallback,
                             Unmanaged.passUnretained(self).toOpaque())
    }

    /// 将当前帧渲染为 CGImage（在专用后台线程调用，非主线程）
    func renderFrameAsCGImage(width: Int32, height: Int32) -> CGImage? {
        guard let rc = renderCtx,
              let fn_renderRender,
              width > 0, height > 0 else { return nil }

        let w = Int(width), h = Int(height)
        // 64 字节对齐的 stride，满足 mpv SW 渲染的 SIMD 要求
        let pixelBytes = 4
        let strideRaw  = w * pixelBytes
        let alignment  = 64
        let stride     = ((strideRaw + alignment - 1) / alignment) * alignment
        let byteCount  = stride * h

        // 分配 64 字节对齐的像素缓冲区，由 CGDataProvider 释放
        let ptr = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: alignment)

        var sz: [Int32]  = [width, height]
        var strideVal: Int = stride
        // BLOCK_FOR_TARGET_TIME=0：禁止阻塞等待帧时间，避免并发调用 render 时死锁/黑屏
        var noBlock: Int32 = 0

        let err: Int32 = sz.withUnsafeMutableBytes { szBuf in
            "rgb0".withCString { fmt in
                withUnsafeMutableBytes(of: &strideVal) { strideBuf in
                    withUnsafeMutableBytes(of: &noBlock) { noBlockBuf in
                        var params: [MPVRenderParam] = [
                            MPVRenderParam(MPV_RENDER_PARAM_SW_SIZE,
                                           szBuf.baseAddress!),
                            MPVRenderParam(MPV_RENDER_PARAM_SW_FORMAT,
                                           UnsafeMutableRawPointer(mutating: fmt)),
                            MPVRenderParam(MPV_RENDER_PARAM_SW_STRIDE,
                                           strideBuf.baseAddress!),
                            MPVRenderParam(MPV_RENDER_PARAM_SW_POINTER,
                                           ptr),
                            MPVRenderParam(MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME,
                                           noBlockBuf.baseAddress!),
                            MPVRenderParam(0, nil),
                        ]
                        return params.withUnsafeMutableBytes { buf in
                            fn_renderRender(rc, buf.baseAddress!)
                        }
                    }
                }
            }
        }

        guard err == 0 else { ptr.deallocate(); return nil }

        // CGDataProvider 拥有 ptr 的所有权，释放时调用 deallocate
        let releasePtr: CGDataProviderReleaseDataCallback = { info, _, _ in
            info?.deallocate()
        }
        guard let provider = CGDataProvider(
            dataInfo: ptr, data: ptr, size: byteCount, releaseData: releasePtr)
        else { ptr.deallocate(); return nil }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
        return CGImage(width: w, height: h,
                       bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: stride, space: colorSpace,
                       bitmapInfo: bitmapInfo, provider: provider,
                       decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)
    }

    func seek(to time: TimeInterval) { cmd(["seek", String(time), "absolute"]) }
    func setPlaying(_ playing: Bool) { cmd(["set_property", "pause", playing ? "no" : "yes"]) }
    func setVolume(_ volume: Double) { cmd(["set_property", "volume", String(volume)]) }

    func stop() {
        stopping = true
        if let rc = renderCtx { fn_renderFree?(rc); renderCtx = nil }
        if let c  = ctx       { fn_terminate?(c);   ctx = nil }
        if lib != nil         { dlclose(lib);        lib = nil }
    }

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
