import SwiftUI
import AVKit

/// Wraps AVPlayerView in a properly Auto-Layout-constrained container.
/// Plain `NSViewRepresentable { AVPlayerView() }` leaves frame at zero in HSplitView.
final class VideoContainerView: NSView {
    private let playerView = AVPlayerView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        playerView.controlsStyle = .inline
        playerView.allowsPictureInPicturePlayback = true
        playerView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(playerView)
        NSLayoutConstraint.activate([
            playerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            playerView.topAnchor.constraint(equalTo: topAnchor),
            playerView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func setPlayer(_ p: AVPlayer) {
        playerView.player = p
    }
}

struct VideoPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> VideoContainerView {
        let v = VideoContainerView()
        v.setPlayer(player)
        return v
    }

    func updateNSView(_ nsView: VideoContainerView, context: Context) {
        nsView.setPlayer(player)
    }
}
