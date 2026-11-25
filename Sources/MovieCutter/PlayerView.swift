import SwiftUI
import AVKit

/// AppKit の AVPlayerView を SwiftUI で使うためのラッパー。
/// SwiftUI 標準の VideoPlayer は SPM ビルドの .app で不安定なため、こちらを使う。
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        // 操作部 (シークバー等) は出さない。再生範囲は開始・終了のスライダーで決め、再生/停止は Space か映像のクリック、
        // 音量は CutterView の自前の部品で扱う (標準の操作部はシークバーだけを消すことができないため)
        view.controlsStyle = .none
        view.showsFullScreenToggleButton = false
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }
}
