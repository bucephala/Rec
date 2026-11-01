import Testing
import Foundation
@testable import RecLib

@Suite("Exporter")
struct ExporterTests {
    @Test func bitrateHitsTarget() {
        // 60s under 10 MB: 10*0.92*8e6/60 - 96000 = 1,130,666
        let br = Exporter.videoBitrate(forDuration: 60, targetMB: 10)
        #expect(br > 1_100_000 && br < 1_160_000)
    }

    @Test func bitrateFloor() {
        #expect(Exporter.videoBitrate(forDuration: 3600, targetMB: 10) == 150_000)
        #expect(Exporter.videoBitrate(forDuration: 0, targetMB: 10) == 1_000_000)
    }

    @Test func bitrateShortClipIsHuge() {
        #expect(Exporter.videoBitrate(forDuration: 2, targetMB: 10) > 30_000_000)
    }

    @Test func mixdownTwoTracksUsesAmix() {
        let args = Exporter.mixdownArgs(input: "in.mp4", output: "out.mp4", audioTracks: 2)
        #expect(args.contains("-filter_complex"))
        let fc = args[args.firstIndex(of: "-filter_complex")! + 1]
        #expect(fc.hasPrefix("[0:a:0][0:a:1]amix=inputs=2"))
        #expect(args.contains("copy"))
        #expect(args.last == "out.mp4")
        #expect(args.contains("+faststart"))
    }

    @Test func mixdownOneTrackCopies() {
        let args = Exporter.mixdownArgs(input: "in.mp4", output: "out.mp4", audioTracks: 1)
        #expect(!args.contains("-filter_complex"))
        #expect(args.contains("0:a:0"))
    }

    @Test func mixdownNoAudio() {
        let args = Exporter.mixdownArgs(input: "in.mp4", output: "out.mp4", audioTracks: 0)
        #expect(!args.contains("-c:a"))
        #expect(args.contains("0:v:0"))
    }

    @Test func compressArgsCarryBitrate() {
        let args = Exporter.compressArgs(input: "a", output: "b", videoBitrate: 800_000, audioTracks: 2)
        #expect(args.contains("800000"))
        #expect(args.contains("libx264"))
        #expect(args.contains("-filter_complex"))
    }
}
