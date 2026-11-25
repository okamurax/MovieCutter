import SwiftUI
import AVKit
import AVFoundation
import UniformTypeIdentifiers

/// 動画 1 本の切り出し画面 (プレビュー・開始／終了スライダー・書き出し)。
/// MovieCutter の窓と、DownloadsShelf (Zero-Reach Keyboard Interface Mac) のプレビュー欄の両方で使う。
/// DownloadsShelf はこのファイルと PlayerView.swift・VideoTrimmer.swift を直接ビルドに含めるので、
/// ここを直すと両方に効く。MovieCutter 専用の部品 (ファイルを開く・ドロップ・最前面固定) はここに置かない。
/// 別の動画に替えるときは、呼ぶ側で .id(url) を付けて作り直す。
struct CutterView: View {
    let url: URL
    /// ← → ↑ ↓ と Space を受け取ってよいか。MovieCutter の窓では常に受け取る。
    /// DownloadsShelf では、この画面をクリックして入力先にしている時だけ受け取る (一覧の矢印キー移動と取り合わないため)
    var acceptsKeys: () -> Bool = { true }

    @State private var player: AVPlayer?
    @State private var duration: Double = 0
    @State private var startTime: Double = 0
    @State private var endTime: Double = 0

    // カットはキーフレーム単位。ここに解析したキーフレーム時刻（秒）が入る。
    @State private var keyframeTimes: [Double] = []
    @State private var isAnalyzing = true

    @State private var isExporting = false
    @State private var statusMessage: String?
    @State private var isError = false

    // 再生をカット範囲内に制限するためのオブザーバ。
    @State private var timeObserver: Any?          // 開始位置ガード用の周期オブザーバ
    @State private var endObserver: NSObjectProtocol?  // 終了到達（ループ）用の通知オブザーバ

    // キーボード操作。← → で選択中のエッジを移動、↑ ↓ で切替、Space で再生/停止。
    @State private var selectedEdge: TrimEdge = .start
    @State private var keyMonitor: Any?

    // 音量と消音。次の動画にも引き継ぐ (下げて使っている時に毎回下げ直さなくて済むように)
    @AppStorage("cutterVolume") private var volume: Double = 1
    @AppStorage("cutterMuted") private var isMuted = false

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
        VStack(spacing: 12) {
            if let player {
                PlayerView(player: player)
                    .frame(minHeight: 120)
                    .cornerRadius(8)
                    // 映像のクリックで再生/停止 (AVPlayerView は SwiftUI のジェスチャーを受けないので、透明な面を上に重ねる)
                    .overlay(
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { togglePlayback() }
                    )
            }

            trimControls

            if let statusMessage {
                Text(statusMessage)
                    .font(.callout)
                    .foregroundColor(isError ? .red : .green)
                    .lineLimit(3)
            }
        }
        .onAppear {
            load()
            installKeyMonitor()
        }
        .onDisappear {
            // 別のファイルを選んだ・窓を閉じた時に音が鳴り続けないよう止める
            player?.pause()
            teardownPlaybackObservers()
            if let keyMonitor {
                NSEvent.removeMonitor(keyMonitor)
            }
            keyMonitor = nil
        }
    }

    // MARK: - Sections

    // 動画の表示を広く取るため、行の間は詰める。説明は 1 行にまとめ、書き出しボタンと同じ行に置く
    private var trimControls: some View {
        VStack(spacing: 4) {
            HStack {
                Text("開始: \(timeString(startTime))")
                Spacer()
                Text("長さ: \(timeString(endTime - startTime))")
                Spacer()
                Text("終了: \(timeString(endTime))")
                volumeControl
                    .padding(.leading, 12)
            }
            .font(.system(.body, design: .monospaced))

            trimRow(title: "開始位置", edge: .start, binding: startBinding, step: { stepStart($0) })
            trimRow(title: "終了位置", edge: .end, binding: endBinding, step: { stepEnd($0) })

            HStack {
                if isAnalyzing {
                    ProgressView().controlSize(.small)
                    Text("キーフレームを解析中…")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("← → 移動 ・ ↑ ↓ 開始／終了の切替 ・ Space 再生／停止 ・ 再エンコードなし（カットのみ）")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
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
            .padding(.top, 2)
        }
    }

    /// 消音ボタンと音量スライダー。
    private var volumeControl: some View {
        HStack(spacing: 4) {
            Button {
                isMuted.toggle()
                player?.isMuted = isMuted
            } label: {
                Image(systemName: isMuted || volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .frame(width: 18)
            }
            .buttonStyle(.borderless)
            .help(isMuted ? "消音を解除" : "消音")
            Slider(value: Binding(
                get: { volume },
                set: { v in
                    volume = v
                    player?.volume = Float(v)
                    if isMuted { isMuted = false; player?.isMuted = false }   // 音量を動かしたら消音を解く
                }
            ), in: 0...1)
            .frame(width: 80)
            .controlSize(.small)
        }
    }

    /// スライダー＋前後キーフレーム移動ボタンの1行。選択中のエッジはハイライトする。
    private func trimRow(title: String, edge: TrimEdge, binding: Binding<Double>, step: @escaping (Int) -> Void) -> some View {
        let isSelected = selectedEdge == edge
        return VStack(alignment: .leading, spacing: 1) {
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
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.08) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { selectedEdge = edge }
    }

    // MARK: - Loading

    private func load() {
        let newPlayer = AVPlayer(url: url)
        newPlayer.volume = Float(volume)
        newPlayer.isMuted = isMuted
        player = newPlayer
        installRangeObserver(on: newPlayer)

        Task {
            let seconds = await VideoTrimmer.duration(of: url)
            let keyframes = await VideoTrimmer.keyframeTimes(of: url)
            await MainActor.run {
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

    // MARK: - Keyboard

    /// ← → ↑ ↓ と Space を横取りして操作する。acceptsKeys が false の間は素通しする。
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // 修飾キー付き（⌘S など）は既存のショートカットに任せる
            guard acceptsKeys(), !event.modifierFlags.contains(.command) else { return event }

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
        // 保存ダイアログなし。元と同じフォルダ・同じ名前に "_" を足して自動書き出し。
        let outputURL = VideoTrimmer.outputURL(for: url)

        isExporting = true
        statusMessage = nil

        Task {
            do {
                try await VideoTrimmer.trim(
                    sourceURL: url,
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

/// キーボード操作の対象（開始位置か終了位置か）。
enum TrimEdge {
    case start
    case end
}

/// 切り出せる動画か (拡張子で判定)。
func isVideoFile(_ url: URL) -> Bool {
    guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else {
        return false
    }
    return type.conforms(to: .movie) || type.conforms(to: .video)
}
