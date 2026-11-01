import AVFoundation
import Cocoa
import Foundation

public enum RecError: LocalizedError {
    case screenPermission
    case noDisplay
    case lowDiskSpace(freeMB: Int)
    case outputNotWritable(String)
    case writerFailed(String)
    case noVideoFrames
    case alreadyRecording

    public var errorDescription: String? {
        switch self {
        case .screenPermission:
            return "Screen Recording permission is missing. Enable Rec in System Settings → Privacy & Security → Screen Recording."
        case .noDisplay:
            return "No display available to record."
        case .lowDiskSpace(let mb):
            return "Only \(mb) MB free. Free up space before recording."
        case .outputNotWritable(let path):
            return "Cannot write to \(path)."
        case .writerFailed(let detail):
            return "Recording file could not be written: \(detail)"
        case .noVideoFrames:
            return "No video frames arrived. Screen Recording permission was probably revoked, re-enable it and restart Rec."
        case .alreadyRecording:
            return "Already recording."
        }
    }
}

public struct PreflightReport {
    public var warnings: [String] = []
    public var micUsable = true
}

public enum Preflight {
    public static let minFreeMB = 500

    public static func hasScreenPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    public static func requestScreenPermission() {
        CGRequestScreenCaptureAccess()
    }

    public static func micAuthorized() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    public static func micDeviceName() -> String? {
        AVCaptureDevice.default(for: .audio)?.localizedName
    }

    public static func freeMegabytes(at url: URL) -> Int? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let bytes = values?.volumeAvailableCapacityForImportantUsage else { return nil }
        return Int(bytes / 1_000_000)
    }

    /// Pure check used by tests and by run().
    public static func diskCheck(freeMB: Int?) -> RecError? {
        guard let free = freeMB else { return nil }
        return free < minFreeMB ? .lowDiskSpace(freeMB: free) : nil
    }

    /// Everything that must be true before a recording starts. Throws on hard failures,
    /// returns warnings for soft ones (mic missing, mic denied).
    public static func run(outputDir: URL, wantMic: Bool) async throws -> PreflightReport {
        var report = PreflightReport()

        guard hasScreenPermission() else {
            requestScreenPermission()
            throw RecError.screenPermission
        }

        do {
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
            let probe = outputDir.appendingPathComponent(".rec-write-test")
            try Data().write(to: probe)
            try FileManager.default.removeItem(at: probe)
        } catch {
            throw RecError.outputNotWritable(outputDir.path)
        }

        if let err = diskCheck(freeMB: freeMegabytes(at: outputDir)) { throw err }

        if wantMic {
            switch micAuthorized() {
            case .authorized:
                break
            case .notDetermined:
                let granted = await AVCaptureDevice.requestAccess(for: .audio)
                if !granted {
                    report.micUsable = false
                    report.warnings.append("Microphone permission denied, recording without mic")
                }
            default:
                report.micUsable = false
                report.warnings.append("Microphone permission denied, recording without mic")
            }
            if report.micUsable && micDeviceName() == nil {
                report.micUsable = false
                report.warnings.append("No microphone found, recording without mic")
            }
        } else {
            report.micUsable = false
        }

        return report
    }
}
