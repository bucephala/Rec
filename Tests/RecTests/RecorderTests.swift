import Testing
import Foundation
@testable import RecLib

@Suite("Recorder helpers")
struct RecorderTests {
    @Test func outputName() {
        let dir = URL(fileURLWithPath: "/tmp/x")
        var comps = DateComponents()
        comps.year = 2026; comps.month = 3; comps.day = 7; comps.hour = 14; comps.minute = 5; comps.second = 9
        let date = Calendar.current.date(from: comps)!
        let url = Recorder.makeOutputURL(in: dir, date: date)
        #expect(url.lastPathComponent == "rec_2026-03-07_14-05-09.mp4")
        #expect(url.deletingLastPathComponent().path == "/tmp/x")
    }

    @Test func fitNoCap() {
        #expect(Recorder.fit(width: 3024, height: 1964, maxDimension: nil) == (3024, 1964))
    }

    @Test func fitForcesEven() {
        #expect(Recorder.fit(width: 1001, height: 601, maxDimension: nil) == (1000, 600))
    }

    @Test func fitMinimum() {
        #expect(Recorder.fit(width: 20, height: 10, maxDimension: nil) == (128, 128))
    }

    @Test func fitLandscapeCap() {
        let (w, h) = Recorder.fit(width: 3840, height: 2160, maxDimension: 1920)
        #expect(w == 1920)
        #expect(h == 1080)
    }

    @Test func fitPortraitCap() {
        let (w, h) = Recorder.fit(width: 1080, height: 2400, maxDimension: 1920)
        #expect(h == 1920)
        #expect(w == 864)
    }

    @Test func fitUnderCapUntouched() {
        #expect(Recorder.fit(width: 1280, height: 720, maxDimension: 1920) == (1280, 720))
    }
}

@Suite("Preflight")
struct PreflightTests {
    @Test func diskCheckUnknownPasses() {
        #expect(Preflight.diskCheck(freeMB: nil) == nil)
    }

    @Test func diskCheckLowFails() {
        guard case .lowDiskSpace(let mb)? = Preflight.diskCheck(freeMB: 120) else {
            Issue.record("expected lowDiskSpace")
            return
        }
        #expect(mb == 120)
    }

    @Test func diskCheckEnoughPasses() {
        #expect(Preflight.diskCheck(freeMB: Preflight.minFreeMB) == nil)
        #expect(Preflight.diskCheck(freeMB: 50_000) == nil)
    }

    @Test func errorsHaveDescriptions() {
        let all: [RecError] = [.screenPermission, .noDisplay, .lowDiskSpace(freeMB: 1), .outputNotWritable("/x"),
                               .writerFailed("boom"), .noVideoFrames, .alreadyRecording]
        for e in all { #expect(!(e.errorDescription ?? "").isEmpty) }
        #expect(RecError.writerFailed("boom").errorDescription!.contains("boom"))
        #expect(RecError.outputNotWritable("/x").errorDescription!.contains("/x"))
    }
}
