import AVFoundation
import Foundation
import os.log

/// 動画のトリミング処理をまとめたユーティリティ。
/// 速度重視のため再エンコードせず、パススルー（ストリームコピー）でカットする。
enum VideoTrimmer {

    enum TrimError: LocalizedError {
        case noExportSession
        case exportFailed(String)
        case invalidRange

        var errorDescription: String? {
            switch self {
            case .noExportSession:
                return "エクスポートセッションを作成できませんでした。"
            case .exportFailed(let message):
                return "書き出しに失敗しました: \(message)"
            case .invalidRange:
                return "開始位置は終了位置より前にしてください。"
            }
        }
    }

    /// 拡張子から出力コンテナ種別を推定する。
    static func fileType(for url: URL) -> AVFileType {
        switch url.pathExtension.lowercased() {
        case "mov": return .mov
        case "m4v": return .m4v
        case "mp4": return .mp4
        default: return .mp4
        }
    }

    /// 元動画のパスから「1文字だけ足した」書き出し先URLを作る。
    /// 例: movie.mp4 -> movie_.mp4 （衝突する場合は "_" を足して回避）
    static func outputURL(for sourceURL: URL) -> URL {
        let dir = sourceURL.deletingLastPathComponent()
        let ext = sourceURL.pathExtension
        let base = sourceURL.deletingPathExtension().lastPathComponent

        var suffix = "_"
        var candidate = dir.appendingPathComponent(base + suffix).appendingPathExtension(ext)
        while FileManager.default.fileExists(atPath: candidate.path) {
            suffix += "_"
            candidate = dir.appendingPathComponent(base + suffix).appendingPathExtension(ext)
        }
        return candidate
    }

    /// 指定した時間範囲で動画を再エンコードなしで書き出す。
    /// - Parameters:
    ///   - sourceURL: 元動画のURL
    ///   - start: 開始時間（秒）
    ///   - end: 終了時間（秒）
    ///   - outputURL: 書き出し先URL
    static func trim(sourceURL: URL, start: Double, end: Double, outputURL: URL) async throws {
        guard end > start else { throw TrimError.invalidRange }

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }

        // 出力が 4GB を超えると AVAssetExportSession のパススルーは -16364 で失敗する
        // （MP4/MOV マルチプレクサの 32bit 制限）。ffmpeg の stream copy は 64bit
        // atom を書けるため 4GB 超でも切り出せる。ffmpeg があれば優先して使う。
        if let ffmpeg = ffmpegPath() {
            try await runFFmpeg(ffmpeg, source: sourceURL, start: start, end: end, output: outputURL)
        } else {
            try await runAVExport(source: sourceURL, start: start, end: end, output: outputURL)
        }
    }

    // MARK: - ffmpeg（4GB 超対応・再エンコードなし）

    /// よくあるインストール先から ffmpeg を探す。
    /// GUI アプリは PATH が最小限なので絶対パスで探す必要がある。
    private static func ffmpegPath() -> String? {
        let candidates = [
            "/opt/homebrew/bin/ffmpeg",  // Apple Silicon Homebrew
            "/usr/local/bin/ffmpeg",     // Intel Homebrew
            "/opt/local/bin/ffmpeg",     // MacPorts
            "/usr/bin/ffmpeg",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// ffmpeg で [start, end] を stream copy で切り出す。
    private static func runFFmpeg(_ ffmpeg: String, source: URL, start: Double, end: Double, output: URL) async throws {
        // 進捗ログ（stderr）でパイプが詰まらないよう、一時ファイルへ流す。
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("moviecutter-ffmpeg-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: logURL)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffmpeg)
        proc.arguments = [
            "-y",
            "-ss", String(format: "%.6f", start),   // 入力側シーク（キーフレーム精度・高速）
            "-i", source.path,
            "-t", String(format: "%.6f", end - start),
            "-map", "0:v?", "-map", "0:a?",          // 映像・音声のみ（あれば）コピー
            "-c", "copy",                            // 再エンコードなし
            "-avoid_negative_ts", "make_zero",
            output.path,
        ]
        proc.standardError = logHandle
        proc.standardOutput = logHandle

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            proc.terminationHandler = { p in
                try? logHandle.close()
                if p.terminationStatus == 0 {
                    try? FileManager.default.removeItem(at: logURL)
                    cont.resume()
                } else {
                    let log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
                    try? FileManager.default.removeItem(at: logURL)
                    let tail = String(log.suffix(800))
                    os_log("ffmpeg failed code=%d: %{public}@", log: Self.logger, type: .error,
                           Int(p.terminationStatus), tail)
                    cont.resume(throwing: TrimError.exportFailed("ffmpeg 失敗 (code \(p.terminationStatus))\n\(tail)"))
                }
            }
            do {
                try proc.run()
            } catch {
                try? logHandle.close()
                try? FileManager.default.removeItem(at: logURL)
                cont.resume(throwing: error)
            }
        }
    }

    // MARK: - AVAssetExportSession（ffmpeg 不在時のフォールバック・4GB 未満のみ）

    private static func runAVExport(source: URL, start: Double, end: Double, output: URL) async throws {
        let asset = AVURLAsset(url: source)
        guard let exportSession = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetPassthrough
        ) else {
            throw TrimError.noExportSession
        }

        let timescale: CMTimeScale = 600
        exportSession.outputURL = output
        exportSession.outputFileType = fileType(for: output)
        exportSession.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: timescale),
            end: CMTime(seconds: end, preferredTimescale: timescale)
        )

        await exportSession.export()

        switch exportSession.status {
        case .completed:
            return
        case .failed, .cancelled:
            let detail = describe(exportSession.error)
            os_log("AVExport failed: %{public}@ | %{public}@",
                   log: Self.logger, type: .error, output.path, detail)
            // 4GB 超が原因のことが多い旨を添える
            throw TrimError.exportFailed("\(detail)\n（出力が 4GB を超える場合は ffmpeg のインストールが必要です）")
        default:
            throw TrimError.exportFailed("予期しない状態: \(exportSession.status.rawValue)")
        }
    }

    private static let logger = OSLog(subsystem: "com.example.MovieCutter", category: "export")

    /// NSError をドメイン・コード・下位エラーまで含めて読める文字列にする。
    private static func describe(_ error: Error?) -> String {
        guard let ns = error as NSError? else { return "不明なエラー" }
        var parts = ["\(ns.localizedDescription) [\(ns.domain) \(ns.code)]"]
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            parts.append("← \(underlying.domain) \(underlying.code): \(underlying.localizedDescription)")
        }
        return parts.joined(separator: " ")
    }

    /// 動画の長さ（秒）を取得する。
    static func duration(of url: URL) async -> Double {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return 0 }
        return CMTimeGetSeconds(duration)
    }

    /// 動画のキーフレーム（同期サンプル）の表示時刻（秒）を昇順で取得する。
    /// 圧縮サンプルの属性だけを読むためデコードは行わず、比較的高速。
    static func keyframeTimes(of url: URL) async -> [Double] {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let reader = try? AVAssetReader(asset: asset) else {
            return []
        }

        // outputSettings: nil で圧縮サンプルのまま読み出す（デコードなし）
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        guard reader.startReading() else { return [] }

        var times: [Double] = []
        while let sample = output.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            if isSyncSample(sample), pts.isValid {
                times.append(CMTimeGetSeconds(pts))
            }
        }
        reader.cancelReading()

        // 昇順に並べ、ごく近接した重複（1ms 未満）を除去する。
        var result: [Double] = []
        for time in times.sorted() where result.last.map({ time - $0 > 0.001 }) ?? true {
            result.append(time)
        }
        return result
    }

    /// サンプルがキーフレーム（同期サンプル）かどうか。
    /// 属性配列が無い、または NotSync が無い場合はキーフレーム扱い。
    private static func isSyncSample(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                as? [[CFString: Any]],
              let first = attachments.first,
              let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool else {
            return true
        }
        return !notSync
    }

    /// 指定した時刻に最も近いキーフレーム時刻を返す。キーフレームが無ければ time をそのまま返す。
    static func nearestKeyframe(to time: Double, in keyframes: [Double]) -> Double {
        guard !keyframes.isEmpty else { return time }
        return keyframes.min(by: { abs($0 - time) < abs($1 - time) }) ?? time
    }
}
