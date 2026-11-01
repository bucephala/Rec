import Testing
@testable import RecLib

@Suite("AudioMeter")
struct AudioMeterTests {
    @Test func peakOfSamples() {
        let samples: [Float] = [0.1, -0.7, 0.3, 0.0]
        samples.withUnsafeBufferPointer { #expect(AudioMeter.peak(of: $0) == 0.7) }
    }

    @Test func peakOfEmpty() {
        let samples: [Float] = []
        samples.withUnsafeBufferPointer { #expect(AudioMeter.peak(of: $0) == 0) }
    }

    @Test func silentWhenNoBuffers() {
        let m = AudioMeter()
        #expect(m.looksSilent)
    }

    @Test func silentWhenOnlyNoiseFloor() {
        var m = AudioMeter()
        for _ in 0..<100 { m.ingest(peak: 0.0001) }
        #expect(m.looksSilent)
        #expect(m.bufferCount == 100)
    }

    @Test func notSilentAfterRealSignal() {
        var m = AudioMeter()
        for _ in 0..<50 { m.ingest(peak: 0) }
        m.ingest(peak: 0.05)
        m.ingest(peak: 0)
        #expect(!m.looksSilent)
        #expect(m.maxPeak == 0.05)
        #expect(m.currentPeak == 0)
    }

    @Test func resetClears() {
        var m = AudioMeter()
        m.ingest(peak: 0.5)
        m.reset()
        #expect(m.bufferCount == 0)
        #expect(m.maxPeak == 0)
        #expect(m.looksSilent)
    }

    @Test func meterLevelScale() {
        #expect(AudioMeter.meterLevel(peak: 0) == 0)
        #expect(AudioMeter.meterLevel(peak: 1) == 1)
        #expect(AudioMeter.meterLevel(peak: 2) == 1)
        let quiet = AudioMeter.meterLevel(peak: 0.001) // -60 dB
        #expect(quiet >= 0 && quiet < 0.01)
        let mid = AudioMeter.meterLevel(peak: 0.0316) // about -30 dB
        #expect(mid > 0.45 && mid < 0.55)
    }
}
