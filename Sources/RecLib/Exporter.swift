import AVFoundation
import Cocoa
import Foundation

/// Post processing through ffmpeg when it exists. Everything here is optional,
/// the raw recording is always a valid file on its own.
public enum Exporter {
    public static let discordLimitMB = 10.0

    public static var ffmpegPath: String? {
        let candidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return found }
        let r = Service.run("/bin/sh", ["-lc", "command -v ffmpeg"])
        let path = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return r.status == 0 && !path.isEmpty ? path : nil
    }

    public static func copyToClipboard(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([url as NSURL])
    }

    /// Video bitrate (bits/s) that lands a file under targetMB including audio and container slack.
    public static func videoBitrate(forDuration seconds: Double, targetMB: Double, audioBitrate: Int = 96_000) -> Int {
        guard seconds > 0 else { return 1_000_000 }
        let budgetBits = targetMB * 0.92 * 8_000_000
        let video = budgetBits / seconds - Double(audioBitrate)
        return max(150_000, Int(video))
    }

    static func audioTrackCount(_ url: URL) async -> Int {
        let asset = AVURLAsset(url: url)
        return (try? await asset.loadTracks(withMediaType: .audio).count) ?? 0
    }

    static func duration(_ url: URL) async -> Double {
        let asset = AVURLAsset(url: url)
        return (try? await asset.load(.duration).seconds) ?? 0
    }

    /// Builds the ffmpeg arguments that fold every audio track into one. Video is copied as is.
    public static func mixdownArgs(input: String, output: String, audioTracks: Int) -> [String] {
        var args = ["-y", "-hide_banner", "-loglevel", "error", "-i", input, "-map", "0:v:0", "-c:v", "copy"]
        if audioTracks >= 2 {
            let inputs = (0..<audioTracks).map { "[0:a:\($0)]" }.joined()
            args += ["-filter_complex", "\(inputs)amix=inputs=\(audioTracks):duration=longest:normalize=0[a]",
                     "-map", "[a]", "-c:a", "aac", "-b:a", "192k"]
        } else if audioTracks == 1 {
            args += ["-map", "0:a:0", "-c:a", "copy"]
        }
        args += ["-movflags", "+faststart", output]
        return args
    }

    public static func compressArgs(input: String, output: String, videoBitrate: Int, audioTracks: Int) -> [String] {
        var args = ["-y", "-hide_banner", "-loglevel", "error", "-i", input, "-map", "0:v:0",
                    "-c:v", "libx264", "-preset", "fast", "-pix_fmt", "yuv420p",
                    "-vf", "scale='min(1920,iw)':-2",
                    "-b:v", "\(videoBitrate)", "-maxrate", "\(Int(Double(videoBitrate) * 1.15))",
                    "-bufsize", "\(videoBitrate * 2)"]
        if audioTracks >= 2 {
            let inputs = (0..<audioTracks).map { "[0:a:\($0)]" }.joined()
            args += ["-filter_complex", "\(inputs)amix=inputs=\(audioTracks):duration=longest:normalize=0[a]",
                     "-map", "[a]", "-c:a", "aac", "-b:a", "96k"]
        } else if audioTracks == 1 {
            args += ["-map", "0:a:0", "-c:a", "aac", "-b:a", "96k"]
        }
        args += ["-movflags", "+faststart", output]
        return args
    }

    /// Replace the fragmented multitrack recording with a clean single audio track mp4.
    /// Returns the final URL. On any failure the original is left untouched and returned.
    public static func mixdown(_ url: URL, keepRaw: Bool) async -> URL {
        guard let ffmpeg = ffmpegPath else { return url }
        let tracks = await audioTrackCount(url)
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).mix.mp4")
        let r = Service.run(ffmpeg, mixdownArgs(input: url.path, output: tmp.path, audioTracks: tracks))
        guard r.status == 0, (try? tmp.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0 > 0 else {
            NSLog("Rec: mixdown failed: %@", r.output)
            try? FileManager.default.removeItem(at: tmp)
            return url
        }
        if keepRaw {
            let raw = url.deletingPathExtension().appendingPathExtension("raw.mp4")
            try? FileManager.default.moveItem(at: url, to: raw)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
        do {
            try FileManager.default.moveItem(at: tmp, to: url)
            return url
        } catch {
            return tmp
        }
    }

    /// Writes name_discord.mp4 next to the input, under the Discord upload limit.
    public static func compressForDiscord(_ url: URL) async throws -> URL {
        guard let ffmpeg = ffmpegPath else {
            throw NSError(domain: "Rec", code: 1, userInfo: [NSLocalizedDescriptionKey: "ffmpeg not found (brew install ffmpeg)"])
        }
        let seconds = await duration(url)
        let tracks = await audioTrackCount(url)
        let out = url.deletingPathExtension().appendingPathExtension("discord.mp4")
        var bitrate = videoBitrate(forDuration: seconds, targetMB: discordLimitMB)
        for _ in 0..<2 {
            let r = Service.run(ffmpeg, compressArgs(input: url.path, output: out.path, videoBitrate: bitrate, audioTracks: tracks))
            guard r.status == 0 else {
                throw NSError(domain: "Rec", code: 2, userInfo: [NSLocalizedDescriptionKey: "ffmpeg failed: \(r.output)"])
            }
            let size = Double((try? out.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) / 1_000_000
            if size <= discordLimitMB { return out }
            bitrate = Int(Double(bitrate) * 0.8)
        }
        return out
    }
}
