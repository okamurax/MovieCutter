import SwiftUI
import AVKit

/// AppKit の AVPlayerView を SwiftUI で使うためのラッパー。
/// SwiftUI 標準の VideoPlayer は SPM ビルドの .app で不安定なため、こちらを使う。
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = false
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }
}
