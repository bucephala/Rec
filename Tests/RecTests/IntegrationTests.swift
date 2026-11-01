import Testing
import Foundation
import AVFoundation
import ScreenCaptureKit
@testable import RecLib

// Real capture of the main display. Needs Screen Recording permission for the
// process running the tests (your terminal). Run with:
//   REC_INTEGRATION=1 swift test --filter Integration
@Suite("Integration", .enabled(if: ProcessInfo.processInfo.environment["REC_INTEGRATION"] == "1"))
struct IntegrationTests {
    @Test func recordsDisplayForFourSeconds() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rec-it-\(UUID().uuidString)")
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let display = try #require(content.displays.first)

        let rec = Recorder(outputDirectory: dir)
        rec.quality = .medium
        rec.captureSystemAudio = true
        rec.captureMic = false

        let url: URL = try await withCheckedThrowingContinuation { cont in
            rec.onStop = { cont.resume(returning: $0) }
            rec.onError = { cont.resume(throwing: $0) }
            Task {
                do {
                    try await rec.start(target: .display(display), content: content)
                } catch {
                    cont.resume(throwing: error)
                    return
                }
                try? await Task.sleep(for: .seconds(4))
                let s = rec.stats
                print("frames total=\(s.videoFrames) complete=\(s.completeFrames) sysAudioBuffers=\(s.system.bufferCount) sysPeak=\(s.system.maxPeak)")
                rec.stop()
            }
        }

        let stats = rec.stats
        #expect(stats.videoFrames > 0)
        #expect(stats.completeFrames > 0)
        #expect(stats.system.bufferCount > 0, "system audio buffers should flow even when silent")

        let size = try #require(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        #expect(size > 10_000)

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        #expect(duration > 2.5 && duration < 6, "duration was \(duration)")
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        #expect(video.count == 1)
        #expect(audio.count == 1)
        let dims = try await video[0].load(.naturalSize)
        #expect(dims.width <= 1920 && dims.height <= 1920)
        #expect(dims.width >= 128)

        // the post step must leave a playable single track file
        if Exporter.ffmpegPath != nil {
            let mixed = await Exporter.mixdown(url, keepRaw: true)
            let mixedAsset = AVURLAsset(url: mixed)
            let mixedDuration = try await mixedAsset.load(.duration).seconds
            #expect(abs(mixedDuration - duration) < 0.6)
            #expect(try await mixedAsset.loadTracks(withMediaType: .audio).count == 1)
            let raw = url.deletingPathExtension().appendingPathExtension("raw.mp4")
            #expect(FileManager.default.fileExists(atPath: raw.path))
        }
        print("integration output: \(url.path)")
    }
}
