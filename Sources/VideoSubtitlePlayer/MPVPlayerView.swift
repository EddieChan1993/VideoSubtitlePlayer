import AppKit
import SwiftUI

// MARK: - 渲染 NSView

/// 渲染驱动方式：mpv 的 onNeedsDisplay 回调触发（有新帧时才渲染）
/// 渲染在专用后台队列执行，主线程只负责更新 CALayer.contents
/// 彻底避免 CVDisplayLink 方案中因并发调用 mpv_render_context_render 导致的死锁/黑屏
final class MPVHostView: NSView {

    weak var mpvController: MPVController?

    private let renderQueue = DispatchQueue(label: "mpv.render", qos: .userInteractive)
    private var contextReady  = false
    private var pendingRender = false   // 主线程访问，防止 render 任务堆积

    // 主线程写、renderQueue 读；Int32 原子读写足够
    private var renderW = Int32(0)
    private var renderH = Int32(0)

    init(controller: MPVController) {
        self.mpvController = controller
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity  = .resize
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isOpaque: Bool { true }

    // MARK: - 生命周期

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }

        layer?.contentsScale = window.backingScaleFactor

        if !contextReady {
            contextReady = true
            // render context 已在 prepare() 中建立；此处只需连接回调并立即渲染当前帧
            mpvController?.onNeedsDisplay = { [weak self] in self?.scheduleRender() }
        }
        // 立即尝试渲染——即使 onNeedsDisplay 之前已触发过但因 view 未就绪而错过
        scheduleRender()
    }

    // SwiftUI 通过 setFrameSize 设置尺寸，不触发 layout()
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1.0
        layer?.contentsScale = scale
        let newW = Int32((newSize.width  * scale).rounded())
        let newH = Int32((newSize.height * scale).rounded())
        let firstValidSize = (renderW == 0 || renderH == 0) && newW > 0 && newH > 0
        renderW = newW
        renderH = newH
        // 首次获得有效尺寸时，主动渲染一帧（避免等待下一次 onNeedsDisplay）
        if firstValidSize { scheduleRender() }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let scale = window?.backingScaleFactor {
            layer?.contentsScale = scale
            renderW = Int32((bounds.width  * scale).rounded())
            renderH = Int32((bounds.height * scale).rounded())
        }
    }

    // MARK: - 渲染调度（主线程）

    private func scheduleRender() {
        // pendingRender 防止 renderQueue 任务堆积
        guard !pendingRender else { return }
        let w = renderW, h = renderH
        guard w > 0, h > 0 else { return }

        pendingRender = true
        renderQueue.async { [weak self] in
            guard let self else { return }
            let img = self.mpvController?.renderFrameAsCGImage(width: w, height: h)
            DispatchQueue.main.async { [weak self] in
                self?.pendingRender = false
                guard let img else { return }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self?.layer?.contents = img
                CATransaction.commit()
            }
        }
    }
}

// MARK: - SwiftUI 包装

struct MPVPlayerView: NSViewRepresentable {
    let controller: MPVController

    func makeNSView(context: Context) -> MPVHostView {
        MPVHostView(controller: controller)
    }

    func updateNSView(_ nsView: MPVHostView, context: Context) {}
}
