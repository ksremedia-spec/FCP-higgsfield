#if os(macOS)
import AVFoundation
import AppKit
import Foundation
import HiggsfieldKit

/// Reads duration, frame rate, size and audio presence with AVFoundation.
public struct AVMediaProbe: MediaProbing {
    public init() {}

    public func probe(_ url: URL) async -> MediaInfo? {
        let ext = url.pathExtension
        if MediaKind(fileExtension: ext) == .image {
            guard let rep = NSImageRep(contentsOf: url) else { return MediaInfo(kind: .image, isPlayable: false) }
            return MediaInfo(kind: .image, width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        let asset = AVURLAsset(url: url)
        do {
            let (duration, playable) = try await asset.load(.duration, .isPlayable)
            let video = try await asset.loadTracks(withMediaType: .video).first
            let audio = try await asset.loadTracks(withMediaType: .audio)
            var width: Int?
            var height: Int?
            var fps: Double?
            if let video {
                let (size, transform, rate) = try await video.load(.naturalSize, .preferredTransform, .nominalFrameRate)
                let rect = CGRect(origin: .zero, size: size).applying(transform)
                width = Int(abs(rect.width).rounded())
                height = Int(abs(rect.height).rounded())
                fps = rate > 0 ? Double(rate) : nil
            }
            let kind: MediaKind = video == nil && !audio.isEmpty ? .audio : .video
            return MediaInfo(kind: kind, duration: duration.seconds.isFinite ? duration.seconds : nil, frameRate: fps,
                             width: width, height: height, hasAudio: !audio.isEmpty, isPlayable: playable && video != nil)
        } catch {
            return MediaInfo(kind: MediaKind(fileExtension: ext) ?? .video, isPlayable: false)
        }
    }
}

/// Cuts the In/Out selection out of a clip before upload, so only the chosen
/// range is sent (and billed). Passthrough when the codec allows it.
public struct AVMediaTrimmer: MediaTrimming {
    public let workDirectory: URL

    public init(workDirectory: URL) {
        self.workDirectory = workDirectory
    }

    public func trim(_ source: URL, start: Double, end: Double) async throws -> URL {
        guard end > start else { throw HiggsfieldError.invalidInput("The In point must be before the Out point.") }
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        let asset = AVURLAsset(url: source)
        let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                end: CMTime(seconds: end, preferredTimescale: 600))
        for preset in [AVAssetExportPresetPassthrough, AVAssetExportPresetHighestQuality] {
            let output = workDirectory.appendingPathComponent("trim-\(UUID().uuidString).mov")
            guard let session = AVAssetExportSession(asset: asset, presetName: preset) else { continue }
            session.outputURL = output
            session.outputFileType = .mov
            session.timeRange = range
            session.shouldOptimizeForNetworkUse = true
            let box = ExportSessionBox(session)
            let ok: Bool = await withCheckedContinuation { continuation in
                box.session.exportAsynchronously {
                    continuation.resume(returning: box.session.status == .completed)
                }
            }
            if ok { return output }
            try? FileManager.default.removeItem(at: output)
        }
        throw HiggsfieldError.invalidInput("Couldn’t trim “\(source.lastPathComponent)”.")
    }
}

/// Carries the export session into the `@Sendable` completion handler;
/// the session is only read after export finishes.
private final class ExportSessionBox: @unchecked Sendable {
    let session: AVAssetExportSession
    init(_ session: AVAssetExportSession) { self.session = session }
}

/// Grabs still frames for thumbnails and the Draw to Edit canvas.
public enum FrameGrabber {
    public static func image(from url: URL, at seconds: Double, maximumSize: CGSize? = nil) async -> CGImage? {
        if MediaKind(fileExtension: url.pathExtension) == .image {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)
        if let maximumSize { generator.maximumSize = maximumSize }
        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        return await withCheckedContinuation { continuation in
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, image, _, _, _ in
                continuation.resume(returning: image)
            }
        }
    }

    public static func pngData(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}
#endif
