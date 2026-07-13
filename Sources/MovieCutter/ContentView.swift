import SwiftUI
import AVKit
import AVFoundation
import UniformTypeIdentifiers

/// キーボード操作の対象（開始位置か終了位置か）。
enum TrimEdge {
    case start
    case end
}

struct ContentView: View {
    @State private var videoURL: URL?
    @State private var player: AVPlayer?
    @State private var duration: Double = 0
    @State private var startTime: Double = 0
    @State private var endTime: Double = 0

    // カットはキーフレーム単位。ここに解析したキーフレーム時刻（秒）が入る。
    @State private var keyframeTimes: [Double] = []
    @State private var isAnalyzing = false

    @State private var isExporting = false
    @State private var isDropTargeted = false
    @State private var statusMessage: String?
    @State private var isError = false

    // 読み込みの世代番号。古い非同期読み込みが新しい動画の状態を上書きしないようにする。
    @State private var loadGeneration = 0

    // 再生をカット範囲内に制限するためのオブザーバ。
    @State private var timeObserver: Any?          // 開始位置ガード用の周期オブザーバ
    @State private var endObserver: NSObjectProtocol?  // 終了到達（ループ）用の通知オブザーバ

    // キーボード操作。← → で選択中のエッジを移動、↑ ↓ で切替、Space で再生/停止。
    @State private var selectedEdge: TrimEdge = .start
    @State private var keyMonitor: Any?

    private var sliderRange: ClosedRange<Double> {
        0...max(duration, 0.1)
    }

    /// 終了位置のスナップ候補。キーフレームに加え、末尾（duration）も含めて全体を選べるようにする。
    private var endSnapPoints: [Double] {
        var points = keyframeTimes
        if duration > 0, points.last != duration {
            points.append(duration)
        }
        return points
    }

    /// スライダーはキーフレームにのみスナップする。
    private var startBinding: Binding<Double> {
        Binding(
            get: { startTime },
            set: { raw in
                let snapped = min(VideoTrimmer.nearestKeyframe(to: raw, in: keyframeTimes), endTime)
                if snapped != startTime {
                    startTime = snapped
                    seek(to: snapped)
                }
            }
        )
    }

    private var endBinding: Binding<Double> {
        Binding(
            get: { endTime },
            set: { raw in
                let snapped = max(VideoTrimmer.nearestKeyframe(to: raw, in: endSnapPoints), startTime)
                if snapped != endTime {
                    endTime = snapped
                    updateEndBoundary()
                    seek(to: snapped)
                }
            }
        )
    }

    var body: some View {
        VStack(spacing: 16) {
            header

            if let player {
                PlayerView(player: player)
                    .frame(minHeight: 260)
                    .cornerRadius(8)
            } else {
                dropPlaceholder
            }

            if videoURL != nil {
                trimControls
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.callout)
                    .foregroundColor(isError ? .red : .green)
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        // ウィンドウ全体でドラッグ&ドロップを受け付ける
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
        .onAppear {
            installKeyMonitor()
        }
        .onDisappear {
            teardownPlaybackObservers()
            if let keyMonitor {
                NSEvent.removeMonitor(keyMonitor)
            }
            keyMonitor = nil
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

    private var trimControls: some View {
        VStack(spacing: 12) {
            HStack {
                Text("開始: \(timeString(startTime))")
                Spacer()
                Text("長さ: \(timeString(endTime - startTime))")
                Spacer()
                Text("終了: \(timeString(endTime))")
            }
            .font(.system(.body, design: .monospaced))

            HStack {
                if isAnalyzing {
                    ProgressView().controlSize(.small)
                    Text("キーフレームを解析中…")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("← → で移動 ・ ↑ ↓ で開始／終了を切替 ・ Space で再生／停止")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            trimRow(title: "開始位置", edge: .start, binding: startBinding, step: { stepStart($0) })
            trimRow(title: "終了位置", edge: .end, binding: endBinding, step: { stepEnd($0) })

            HStack {
                Text("※ 再エンコードなし・カットのみ（高速）")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button {
                    export()
                } label: {
                    if isExporting {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("書き出す", systemImage: "square.and.arrow.down")
                    }
                }
                .disabled(isExporting || isAnalyzing || endTime <= startTime)
                .keyboardShortcut("s", modifiers: .command)
            }
        }
    }

    /// スライダー＋前後キーフレーム移動ボタンの1行。選択中のエッジはハイライトする。
    private func trimRow(title: String, edge: TrimEdge, binding: Binding<Double>, step: @escaping (Int) -> Void) -> some View {
        let isSelected = selectedEdge == edge
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                if isSelected {
                    Image(systemName: "arrowtriangle.right.fill")
                        .font(.system(size: 8))
                        .foregroundColor(.accentColor)
                }
                Text(title)
                    .font(.caption)
                    .foregroundColor(isSelected ? .accentColor : .secondary)
            }
            HStack(spacing: 8) {
                Button { selectedEdge = edge; step(-1) } label: { Image(systemName: "chevron.left") }
                    .help("前のキーフレームへ")
                Slider(value: binding, in: sliderRange)
                Button { selectedEdge = edge; step(1) } label: { Image(systemName: "chevron.right") }
                    .help("次のキーフレームへ")
            }
            .disabled(isAnalyzing || keyframeTimes.isEmpty)
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.08) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { selectedEdge = edge }
    }

    // MARK: - File loading

    private func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        if panel.runModal() == .OK, let url = panel.url {
            loadVideo(url)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            DispatchQueue.main.async {
                guard let url else { return }
                if isVideoFile(url) {
                    loadVideo(url)
                } else {
                    isError = true
                    statusMessage = "動画ファイルではありません: \(url.lastPathComponent)"
                }
            }
        }
        return true
    }

    private func isVideoFile(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else {
            return false
        }
        return type.conforms(to: .movie) || type.conforms(to: .video)
    }

    private func loadVideo(_ url: URL) {
        loadGeneration += 1
        let generation = loadGeneration

        // 前の動画のオブザーバを外してから差し替える。
        teardownPlaybackObservers()

        videoURL = url
        let newPlayer = AVPlayer(url: url)
        player = newPlayer
        installRangeObserver(on: newPlayer)
        statusMessage = nil
        isError = false
        keyframeTimes = []
        startTime = 0
        endTime = 0
        isAnalyzing = true

        Task {
            let seconds = await VideoTrimmer.duration(of: url)
            let keyframes = await VideoTrimmer.keyframeTimes(of: url)
            await MainActor.run {
                // 別の動画が読み込まれていたら、この結果は破棄する
                guard generation == loadGeneration else { return }
                duration = seconds
                keyframeTimes = keyframes
                startTime = keyframes.first ?? 0
                endTime = seconds
                updateEndBoundary()
                isAnalyzing = false
            }
        }
    }

    private func seek(to seconds: Double) {
        player?.seek(
            to: CMTime(seconds: seconds, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    // MARK: - Playback range

    /// 再生をカット範囲 [startTime, endTime] 内にループさせるオブザーバ群を取り付ける。
    /// - 終了位置は forwardPlaybackEndTime で止め、到達通知で開始位置へ戻して再生し続ける（ループ）。
    /// - 開始位置より前へ出た場合は周期オブザーバで開始位置へ引き戻す。
    private func installRangeObserver(on player: AVPlayer) {
        player.actionAtItemEnd = .none

        // 開始位置ガード
        let interval = CMTime(seconds: 0.05, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            guard let player = self.player, player.rate > 0, endTime > startTime else { return }
            if CMTimeGetSeconds(time) < startTime - 0.05 {
                seek(to: startTime)
            }
        }

        // 終了位置（forwardPlaybackEndTime）到達 → 先頭へ戻してループ
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { _ in
            guard let player = self.player, endTime > startTime else { return }
            seek(to: startTime)
            player.play()
        }
    }

    /// 終了位置を forwardPlaybackEndTime に反映し、そこで再生が止まる（＝ループの折り返し点）ようにする。
    private func updateEndBoundary() {
        guard let item = player?.currentItem, endTime > 0 else { return }
        item.forwardPlaybackEndTime = CMTime(seconds: endTime, preferredTimescale: 600)
    }

    // MARK: - Keyboard

    /// ← → ↑ ↓ と Space を横取りして操作する。動画未読込のときは素通しする。
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // 修飾キー付き（⌘S など）は既存のショートカットに任せる
            guard videoURL != nil, !event.modifierFlags.contains(.command) else { return event }

            switch event.keyCode {
            case 123: // ←
                stepSelected(-1); return nil
            case 124: // →
                stepSelected(1); return nil
            case 126: // ↑
                selectedEdge = .start; return nil
            case 125: // ↓
                selectedEdge = .end; return nil
            case 49:  // Space
                togglePlayback(); return nil
            default:
                return event
            }
        }
    }

    /// 選択中のエッジ（開始/終了）を1キーフレーム移動する。
    private func stepSelected(_ direction: Int) {
        guard !isAnalyzing else { return }
        switch selectedEdge {
        case .start: stepStart(direction)
        case .end:   stepEnd(direction)
        }
    }

    /// Space の挙動: 停止中なら開始位置から再生、再生中なら停止。
    private func togglePlayback() {
        guard let player else { return }
        if player.rate > 0 {
            player.pause()
        } else {
            seek(to: startTime)
            player.play()
        }
    }

    /// 再生関連のオブザーバを解放する。
    private func teardownPlaybackObservers() {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        timeObserver = nil
        endObserver = nil
    }

    // MARK: - Keyframe stepping

    private func stepStart(_ direction: Int) {
        let points = keyframeTimes
        guard !points.isEmpty else { return }
        let index = nearestIndex(of: startTime, in: points)
        let newIndex = min(max(index + direction, 0), points.count - 1)
        let value = min(points[newIndex], endTime)
        startTime = value
        seek(to: value)
    }

    private func stepEnd(_ direction: Int) {
        let points = endSnapPoints
        guard !points.isEmpty else { return }
        let index = nearestIndex(of: endTime, in: points)
        let newIndex = min(max(index + direction, 0), points.count - 1)
        let value = max(points[newIndex], startTime)
        endTime = value
        updateEndBoundary()
        seek(to: value)
    }

    private func nearestIndex(of time: Double, in points: [Double]) -> Int {
        var bestIndex = 0
        var bestDiff = Double.infinity
        for (index, value) in points.enumerated() {
            let diff = abs(value - time)
            if diff < bestDiff {
                bestDiff = diff
                bestIndex = index
            }
        }
        return bestIndex
    }

    // MARK: - Export

    private func export() {
        guard let videoURL else { return }

        // 保存ダイアログなし。元と同じフォルダ・同じ名前に "_" を足して自動書き出し。
        let outputURL = VideoTrimmer.outputURL(for: videoURL)

        isExporting = true
        statusMessage = nil

        Task {
            do {
                try await VideoTrimmer.trim(
                    sourceURL: videoURL,
                    start: startTime,
                    end: endTime,
                    outputURL: outputURL
                )
                await MainActor.run {
                    isExporting = false
                    isError = false
                    statusMessage = "書き出し完了: \(outputURL.lastPathComponent)"
                }
            } catch {
                await MainActor.run {
                    isExporting = false
                    isError = true
                    statusMessage = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Helpers

    private func timeString(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00.000" }
        let totalMillis = Int((seconds * 1000).rounded())
        let minutes = totalMillis / 60000
        let secs = (totalMillis % 60000) / 1000
        let millis = totalMillis % 1000
        return String(format: "%02d:%02d.%03d", minutes, secs, millis)
    }
}
