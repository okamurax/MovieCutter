import AVFoundation
import Foundation

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

        let asset = AVURLAsset(url: sourceURL)

        // パススルー = 再エンコードなしのストリームコピー（高速）
        guard let exportSession = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetPassthrough
        ) else {
            throw TrimError.noExportSession
        }

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }

        let timescale: CMTimeScale = 600
        let startTime = CMTime(seconds: start, preferredTimescale: timescale)
        let endTime = CMTime(seconds: end, preferredTimescale: timescale)
        let timeRange = CMTimeRange(start: startTime, end: endTime)

        exportSession.outputURL = outputURL
        exportSession.outputFileType = fileType(for: outputURL)
        exportSession.timeRange = timeRange

        await exportSession.export()

        switch exportSession.status {
        case .completed:
            return
        case .failed, .cancelled:
            let message = exportSession.error?.localizedDescription ?? "不明なエラー"
            throw TrimError.exportFailed(message)
        default:
            throw TrimError.exportFailed("予期しない状態: \(exportSession.status.rawValue)")
        }
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
