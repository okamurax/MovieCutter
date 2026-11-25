import SwiftUI
import AppKit

/// MovieCutter の窓。動画の受け取り (開く・ドロップ・外から渡される) と最前面固定だけを持ち、
/// 切り出しの画面そのものは CutterView (DownloadsShelf のプレビュー欄と共有) に任せる。
struct ContentView: View {
    @State private var videoURL: URL?
    @State private var isDropTargeted = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 16) {
            header

            if let videoURL {
                CutterView(url: videoURL)
                    .id(videoURL)   // 別の動画に替えたら作り直す (前の動画の状態を持ち越さない)
            } else {
                dropPlaceholder
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundColor(.red)
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        // ウィンドウを常に最前面（フローティング）に固定する
        .background(WindowConfigurator())
        // ウィンドウ全体でドラッグ&ドロップを受け付ける
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
        // Finder の「このアプリで開く」や Parallels からファイルが渡されると呼ばれる。
        // 起動直後・起動済みのどちらでも受け取れる。
        .onOpenURL { url in
            bringToFront()
            open(url)
        }
        .onAppear {
            bringToFront()
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            Text("MovieCutter")
                .font(.title2.bold())
            Spacer()
            Button {
                openFile()
            } label: {
                Label("動画を開く", systemImage: "folder")
            }
        }
    }

    private var dropPlaceholder: some View {
        RoundedRectangle(cornerRadius: 8)
            .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
            .foregroundColor(isDropTargeted ? .accentColor : .secondary)
            .frame(minHeight: 260)
            .background(
                (isDropTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
                    .cornerRadius(8)
            )
            .overlay(
                VStack(spacing: 8) {
                    Image(systemName: "film")
                        .font(.system(size: 40))
                    Text("ここに動画をドラッグ&ドロップ")
                        .foregroundColor(.secondary)
                    Text("または「動画を開く」から選択")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            )
    }

    // MARK: - File loading

    private func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        if panel.runModal() == .OK, let url = panel.url {
            open(url)
        }
    }

    private func open(_ url: URL) {
        if isVideoFile(url) {
            videoURL = url
            errorMessage = nil
        } else {
            errorMessage = "動画ファイルではありません: \(url.lastPathComponent)"
        }
    }

    /// 起動・ファイル受け取り時にアプリを最前面へ出す。
    /// Parallels 経由で起動すると背面に隠れることがあるため。
    private func bringToFront() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApplication.shared.windows.first?.makeKeyAndOrderFront(nil)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            DispatchQueue.main.async {
                if let url { open(url) }
            }
        }
        return true
    }
}

/// ホストしている NSWindow を掴んで、常に最前面（フローティング）に固定する。
/// 他アプリ（Directory Opus など）にフォーカスを移しても背面に回らないようにする。
private struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        configure(nsView.window)
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        // 通常ウィンドウより上のレベルに固定
        window.level = .floating
        // フルスクリーンの他アプリや全 Space 上でも表示されるようにする
        window.collectionBehavior.insert(.canJoinAllSpaces)
        window.collectionBehavior.insert(.fullScreenAuxiliary)
    }
}
