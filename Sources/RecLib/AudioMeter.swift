import CoreMedia
import Foundation

/// Peak tracking for one audio track. Not thread safe, callers lock.
public struct AudioMeter {
    public private(set) var bufferCount = 0
    public private(set) var currentPeak: Float = 0
    public private(set) var maxPeak: Float = 0

    /// Below this the input is considered dead (muted, unplugged, wrong device). About -66 dBFS.
    public static let silenceThreshold: Float = 0.0005

    public init() {}

    public mutating func reset() {
        bufferCount = 0
        currentPeak = 0
        maxPeak = 0
    }

    public mutating func ingest(peak: Float) {
        bufferCount += 1
        currentPeak = peak
        if peak > maxPeak { maxPeak = peak }
    }

    public mutating func ingest(_ sample: CMSampleBuffer) {
        ingest(peak: AudioMeter.peak(of: sample))
    }

    /// True when enough buffers have arrived (or none at all) and nothing above the noise floor was heard.
    public var looksSilent: Bool {
        bufferCount == 0 || maxPeak < AudioMeter.silenceThreshold
    }

    /// 0...1 on a dB scale, 60 dB range. Good for drawing a meter.
    public static func meterLevel(peak: Float) -> Float {
        guard peak > 0 else { return 0 }
        let db = 20 * log10f(peak)
        return min(1, max(0, (db + 60) / 60))
    }

    public static func peak(of samples: UnsafeBufferPointer<Float>) -> Float {
        var p: Float = 0
        for v in samples {
            let a = abs(v)
            if a > p { p = a }
        }
        return p
    }

    static func peak(of sample: CMSampleBuffer) -> Float {
        var ablSize = 0
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sample, bufferListSizeNeededOut: &ablSize, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil
        ) == noErr else { return 0 }

        let ablPtr = UnsafeMutableRawPointer.allocate(byteCount: ablSize, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { ablPtr.deallocate() }
        let abl = ablPtr.bindMemory(to: AudioBufferList.self, capacity: 1)
        var block: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sample, bufferListSizeNeededOut: nil, bufferListOut: abl, bufferListSize: ablSize,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &block
        ) == noErr else { return 0 }

        guard let fmt = CMSampleBufferGetFormatDescription(sample),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              asbd.mBitsPerChannel == 32 else { return 0 }

        var p: Float = 0
        for buf in UnsafeMutableAudioBufferListPointer(abl) {
            guard let data = buf.mData else { continue }
            let count = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
            let ptr = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count)
            p = max(p, peak(of: ptr))
        }
        return p
    }
}
