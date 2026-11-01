import Testing
import Foundation
@testable import RecLib

@Suite("Recovery")
struct RecoveryTests {
    @Test func markerRoundTrip() {
        let rec = URL(fileURLWithPath: "/x/Recordings/rec_2026-01-01_00-00-00.mp4")
        let marker = Recorder.markerURL(for: rec)
        #expect(marker.lastPathComponent == ".rec_2026-01-01_00-00-00.mp4.inprogress")
        #expect(Recovery.recordingURL(forMarker: marker) == rec)
    }

    @Test func sweepDropsEmptyLeftover() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rec-recovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let rec = dir.appendingPathComponent("rec_a.mp4")
        try Data().write(to: rec)
        try Data().write(to: Recorder.markerURL(for: rec))
        let orphan = Recorder.markerURL(for: dir.appendingPathComponent("rec_gone.mp4"))
        try Data().write(to: orphan)
        #expect(Recovery.markers(in: dir).count == 2)

        let result = await Recovery.sweep(dir: dir, mixdown: false)
        #expect(result.discarded.map(\.lastPathComponent) == [rec.lastPathComponent])
        #expect(result.recovered.isEmpty)
        #expect(Recovery.markers(in: dir).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: rec.path))
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
    }

    @Test func sweepIgnoresNormalFiles() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rec-recovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: dir.appendingPathComponent("rec_fine.mp4"))
        let result = await Recovery.sweep(dir: dir, mixdown: false)
        #expect(result.recovered.isEmpty && result.discarded.isEmpty)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("rec_fine.mp4").path))
    }
}
