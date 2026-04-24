import AppKit
import SwiftUI
import OpenGL.GL
import CoreVideo

// MARK: - CVDisplayLink 文件级回调（不捕获变量）

private func mpvDisplayLinkOutput(
    _ link: CVDisplayLink,
    _ now: UnsafePointer<CVTimeStamp>,
    _ out: UnsafePointer<CVTimeStamp>,
    _ flagsIn: CVOptionFlags,
    _ flagsOut: UnsafeMutablePointer<CVOptionFlags>,
    _ ctx: UnsafeMutableRawPointer?) -> CVReturn {
    guard let ctx else { return kCVReturnSuccess }
    Unmanaged<MPVHostView>.fromOpaque(ctx).takeUnretainedValue().drawFrame()
    return kCVReturnSuccess
}

// MARK: - 渲染 NSView

/// 使用 NSOpenGLContext + CVDisplayLink 渲染 mpv 画面。
/// 不依赖 CAOpenGLLayer（SwiftUI/Metal 层树中无法可靠驱动）。
final class MPVHostView: NSView {

    weak var mpvController: MPVController?

    private var glCtx: NSOpenGLContext?
    private var displayLink: CVDisplayLink?
    private var renderContextReady = false

    // 在主线程写、display link 线程读，Int32 原子读写已足够
    private var renderW = Int32(0)
    private var renderH = Int32(0)

    init(controller: MPVController) {
        self.mpvController = controller
        super.init(frame: .zero)

        // 创建双缓冲 OpenGL 上下文
        let attrs: [NSOpenGLPixelFormatAttribute] = [
            UInt32(NSOpenGLPFADoubleBuffer),
            UInt32(NSOpenGLPFAAllowOfflineRenderers),
            UInt32(NSOpenGLPFABackingStore),
            0
        ]
        if let pf = NSOpenGLPixelFormat(attributes: attrs),
           let ctx = NSOpenGLContext(format: pf, share: nil) {
            glCtx = ctx
        }

        // layer-backed：让 NSOpenGLContext 渲染到 Core Animation 表面
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isOpaque: Bool { true }

    // MARK: - 生命周期

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else {
            stopDisplayLink()
            return
        }

        // 把 GL 上下文绑定到这个 layer-backed view
        glCtx?.view = self

        if !renderContextReady {
            renderContextReady = true
            glCtx?.makeCurrentContext()
            print("[MPV] viewDidMoveToWindow → setupRenderContext")
            mpvController?.setupRenderContext()
            print("[MPV] renderCtx = \(String(describing: mpvController?.renderCtx))")
        }

        updateRenderSize(scaleFactor: window.backingScaleFactor)
        startDisplayLink()
    }

    override func layout() {
        super.layout()
        glCtx?.update()   // 通知 GL 上下文尺寸已变
        if let s = window?.backingScaleFactor { updateRenderSize(scaleFactor: s) }
    }

    private func updateRenderSize(scaleFactor: CGFloat) {
        renderW = Int32((bounds.width  * scaleFactor).rounded())
        renderH = Int32((bounds.height * scaleFactor).rounded())
    }

    // MARK: - 渲染（由 CVDisplayLink 在后台线程调用）

    func drawFrame() {
        guard let glCtx,
              let cglCtx = glCtx.cglContextObj,
              renderW > 0, renderH > 0 else { return }

        CGLLockContext(cglCtx)
        glCtx.makeCurrentContext()

        if let ctrl = mpvController, ctrl.renderCtx != nil {
            ctrl.renderFrame(width: renderW, height: renderH)
        } else {
            // 还未就绪：填黑
            glClearColor(0, 0, 0, 1)
            glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
        }

        CGLFlushDrawable(cglCtx)    // 交换双缓冲
        CGLUnlockContext(cglCtx)
    }

    // MARK: - Display Link

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        var dl: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&dl)
        guard let dl else { return }
        CVDisplayLinkSetOutputCallback(dl, mpvDisplayLinkOutput,
                                       Unmanaged.passUnretained(self).toOpaque())
        CVDisplayLinkStart(dl)
        displayLink = dl
        print("[MPV] CVDisplayLink started")
    }

    private func stopDisplayLink() {
        guard let dl = displayLink else { return }
        CVDisplayLinkStop(dl)
        displayLink = nil
    }

    deinit { stopDisplayLink() }
}

// MARK: - SwiftUI 包装

struct MPVPlayerView: NSViewRepresentable {
    let controller: MPVController

    func makeNSView(context: Context) -> MPVHostView {
        MPVHostView(controller: controller)
    }

    func updateNSView(_ nsView: MPVHostView, context: Context) {}
}
