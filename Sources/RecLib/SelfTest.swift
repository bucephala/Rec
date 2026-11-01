import AVFoundation
import Foundation
import ScreenCaptureKit

/// Headless pipeline check: `Rec --selftest [seconds] [--keep] [--no-mic]`.
/// Records the main display, prints what flowed, verifies the file. Exit 0 on pass.
public enum SelfTest {
    public static func run(arguments: [String]) -> Int32 {
        let seconds = arguments.compactMap { Double($0) }.first ?? 4
        let keep = arguments.contains("--keep")
        let noMic = arguments.contains("--no-mic")
        let settings = Settings()
        var exit: Int32 = 1
        var done = false

        Task {
            defer { done = true }
            do {
                print("rec selftest: \(Int(seconds))s of the main display")
                if !noMic && Preflight.micAuthorized() == .notDetermined {
                    print("  mic permission not decided yet, macOS will prompt now (or pass --no-mic)")
                }
                let report = try await Preflight.run(outputDir: settings.outputDirectory, wantMic: settings.micEnabled && !noMic)
                for w in report.warnings { print("  warn: \(w)") }
                print("  screen permission ok, disk ok, mic \(report.micUsable ? "on (\(Preflight.micDeviceName() ?? "?"))" : "off")")

                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = CaptureTarget.displayUnderMouse(in: content) else { throw RecError.noDisplay }

                let rec = Recorder(outputDirectory: settings.outputDirectory)
                rec.quality = settings.quality
                rec.captureSystemAudio = settings.systemAudioEnabled
                rec.captureMic = report.micUsable

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
                        print("  recording -> \(rec.outputURL?.lastPathComponent ?? "?")")
                        for i in 1...Int(seconds) {
                            try? await Task.sleep(for: .seconds(1))
                            let s = rec.stats
                            print(String(format: "  %ds  frames=%d  sys=%d bufs peak=%.4f  mic=%d bufs peak=%.4f",
                                         i, s.completeFrames, s.system.bufferCount, s.system.maxPeak,
                                         s.mic.bufferCount, s.mic.maxPeak))
                        }
                        rec.stop()
                    }
                }

                let s = rec.stats
                var problems: [String] = []
                if s.completeFrames == 0 { problems.append("no video frames") }
                if rec.captureSystemAudio && s.system.bufferCount == 0 { problems.append("no system audio buffers") }
                if rec.captureMic && s.mic.looksSilent { problems.append("mic silent (muted, wrong device, or nothing said)") }

                let asset = AVURLAsset(url: url)
                let duration = try await asset.load(.duration).seconds
                let video = try await asset.loadTracks(withMediaType: .video).count
                let audio = try await asset.loadTracks(withMediaType: .audio).count
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                print(String(format: "  file: %.1fs, %d video + %d audio tracks, %.1f MB", duration, video, audio, Double(size) / 1_000_000))
                if duration < seconds * 0.6 { problems.append("file too short") }
                if video != 1 { problems.append("bad video track count") }

                if problems.isEmpty {
                    print("PASS")
                    exit = 0
                } else {
                    print("FAIL: " + problems.joined(separator: ", "))
                    exit = 2
                }
                if keep { print("  kept \(url.path)") } else { try? FileManager.default.removeItem(at: url) }
            } catch {
                print("FAIL: \(error.localizedDescription)")
                exit = 1
            }
        }

        // Recorder delivers callbacks on main, so pump the run loop instead of blocking it.
        let deadline = Date().addingTimeInterval(seconds + 30)
        while !done && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
        if !done { print("FAIL: timed out") }
        return exit
    }
}
