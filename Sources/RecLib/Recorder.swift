import AVFoundation
import Cocoa
import CoreMedia
import ScreenCaptureKit

public struct RecorderStats {
    public var videoFrames = 0          // every frame the stream delivered, including idle ones
    public var completeFrames = 0       // frames actually written
    public var lastFrameAt: Date?
    public var system = AudioMeter()
    public var mic = AudioMeter()
    public var micRequested = false
    public var startedAt: Date?
}

// NSLock guards everything the sample callbacks touch. writerQueue serializes
// setup and teardown. Same shape as Clipping's engine, plus metering, fragmented
// output so a crash leaves a playable file, and a blocking stop for app exit.
public final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var systemInput: AVAssetWriterInput?
    private var micInput: AVAssetWriterInput?

    private let lock = NSLock()
    private var _recording = false
    private var _sessionStarted = false
    private var _finalized = false
    private var _stats = RecorderStats()

    private let videoQueue = DispatchQueue(label: "rec.video", qos: .userInitiated)
    private let systemQueue = DispatchQueue(label: "rec.audio.system", qos: .userInitiated)
    private let micQueue = DispatchQueue(label: "rec.audio.mic", qos: .userInitiated)
    private let writerQueue = DispatchQueue(label: "rec.writer", qos: .userInitiated)
    private let finished = DispatchGroup()

    public var quality: Quality = .high
    public var captureSystemAudio = true
    public var captureMic = true
    public var outputDirectory: URL

    public var onStop: ((URL) -> Void)?
    public var onError: ((Error) -> Void)?

    public private(set) var outputURL: URL?

    public init(outputDirectory: URL) {
        self.outputDirectory = outputDirectory
        super.init()
    }

    public var isRecording: Bool { lock.withLock { _recording } }
    public var stats: RecorderStats { lock.withLock { _stats } }

    // MARK: start

    public func start(target: CaptureTarget, content: SCShareableContent) async throws {
        guard !isRecording else { throw RecError.alreadyRecording }

        let filter: SCContentFilter
        switch target {
        case .display(let d), .region(let d, _):
            let me = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
            filter = SCContentFilter(display: d, excludingApplications: me, exceptingWindows: [])
        case .window(let w, _):
            filter = SCContentFilter(desktopIndependentWindow: w)
        }

        let scale = NSScreen.screens.first { $0.displayID == target.displayID }?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor ?? 2

        var w: Int
        var h: Int
        let config = SCStreamConfiguration()
        switch target {
        case .display(let d):
            w = Int(CGFloat(d.width) * scale)
            h = Int(CGFloat(d.height) * scale)
        case .region(_, let rect):
            config.sourceRect = CGRect(x: rect.origin.x / scale, y: rect.origin.y / scale,
                                       width: rect.width / scale, height: rect.height / scale)
            w = Int(rect.width)
            h = Int(rect.height)
        case .window(let win, _):
            w = Int(win.frame.width * scale)
            h = Int(win.frame.height * scale)
        }
        (w, h) = Recorder.fit(width: w, height: h, maxDimension: quality.maxDimension)

        config.width = w
        config.height = h
        config.showsCursor = true
        config.capturesAudio = captureSystemAudio
        config.captureMicrophone = captureMic
        config.sampleRate = 48000
        config.channelCount = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(quality.fps))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 6

        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let url = Recorder.makeOutputURL(in: outputDirectory)
        let writer = try AVAssetWriter(url: url, fileType: .mp4)
        // fragmented mp4: if we die mid recording the file is still playable up to the last fragment
        writer.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)

        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: quality.videoBitRate,
                AVVideoExpectedSourceFrameRateKey: quality.fps,
                AVVideoMaxKeyFrameIntervalKey: quality.fps * 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ])
        vIn.expectsMediaDataInRealTime = true
        writer.add(vIn)

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192_000,
        ]
        var sysIn: AVAssetWriterInput?
        var micIn: AVAssetWriterInput?
        if captureSystemAudio {
            sysIn = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            sysIn?.expectsMediaDataInRealTime = true
            writer.add(sysIn!)
        }
        if captureMic {
            micIn = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            micIn?.expectsMediaDataInRealTime = true
            writer.add(micIn!)
        }

        guard writer.startWriting() else {
            throw RecError.writerFailed(writer.error?.localizedDescription ?? "unknown")
        }

        self.writer = writer
        self.videoInput = vIn
        self.systemInput = sysIn
        self.micInput = micIn
        self.outputURL = url
        try? Data().write(to: Recorder.markerURL(for: url))

        let scStream = SCStream(filter: filter, configuration: config, delegate: self)
        try scStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        if captureSystemAudio {
            try scStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: systemQueue)
        }
        if captureMic {
            try scStream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: micQueue)
        }

        lock.withLock {
            _stats = RecorderStats()
            _stats.micRequested = captureMic
            _sessionStarted = false
            _finalized = false
        }

        do {
            try await scStream.startCapture()
        } catch {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: Recorder.markerURL(for: url))
            self.writer = nil
            throw error
        }

        stream = scStream
        finished.enter()
        lock.withLock {
            _recording = true
            _stats.startedAt = Date()
        }
    }

    // MARK: stop

    public func stop() {
        let was = lock.withLock { () -> Bool in
            guard _recording else { return false }
            _recording = false
            return true
        }
        guard was else { return }
        let s = stream
        stream = nil
        s?.stopCapture { [weak self] _ in
            self?.writerQueue.async { self?.finishFile() }
        }
    }

    /// Stop and block until the file is finalized. For app termination.
    public func stopAndWait(timeout: TimeInterval = 8) {
        guard isRecording else { return }
        stop()
        _ = finished.wait(timeout: .now() + timeout)
    }

    private func finishFile() {
        let already = lock.withLock { () -> Bool in
            if _finalized { return true }
            _finalized = true
            return false
        }
        guard !already else { return }

        defer { finished.leave() }
        guard let writer = writer else { return }
        let url = writer.outputURL

        videoInput?.markAsFinished()
        systemInput?.markAsFinished()
        micInput?.markAsFinished()

        if writer.status == .writing {
            let sem = DispatchSemaphore(value: 0)
            writer.finishWriting { sem.signal() }
            _ = sem.wait(timeout: .now() + 10)
        }

        let ok = writer.status == .completed
        let err = writer.error
        let frames = lock.withLock { _stats.completeFrames }
        try? FileManager.default.removeItem(at: Recorder.markerURL(for: url))

        self.writer = nil
        videoInput = nil
        systemInput = nil
        micInput = nil

        DispatchQueue.main.async { [weak self] in
            if ok && frames > 0 {
                self?.onStop?(url)
            } else {
                try? FileManager.default.removeItem(at: url)
                if frames == 0 {
                    self?.onError?(RecError.noVideoFrames)
                } else {
                    self?.onError?(RecError.writerFailed(err?.localizedDescription ?? "status \(writer.status.rawValue)"))
                }
            }
        }
    }

    // MARK: SCStreamOutput

    public func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sample.isValid else { return }

        var complete = true
        if type == .screen {
            lock.withLock {
                _stats.videoFrames += 1
                _stats.lastFrameAt = Date()
            }
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]]
            let status = attachments?.first?[.status] as? Int
            complete = status == SCFrameStatus.complete.rawValue
            if !complete { return }
        } else {
            let peak = AudioMeter.peak(of: sample)
            lock.withLock {
                if type == .audio { _stats.system.ingest(peak: peak) } else { _stats.mic.ingest(peak: peak) }
            }
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        // startSession happens under the lock. Audio runs on other queues and must not
        // observe _sessionStarted before the session really exists.
        let input: AVAssetWriterInput? = lock.withLock {
            guard _recording, let w = writer, w.status == .writing else { return nil }
            if !_sessionStarted {
                // first video frame opens the session so audio never leads a black screen
                guard type == .screen else { return nil }
                w.startSession(atSourceTime: pts)
                _sessionStarted = true
            }
            if type == .screen { _stats.completeFrames += 1 }
            switch type {
            case .screen: return videoInput
            case .audio: return systemInput
            default: return micInput
            }
        }
        if let input = input, input.isReadyForMoreMediaData {
            input.append(sample)
        }
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("Rec: stream stopped with error: %@", error.localizedDescription)
        let was = lock.withLock { () -> Bool in
            let r = _recording
            _recording = false
            return r
        }
        guard was else { return }
        self.stream = nil
        writerQueue.async { [weak self] in self?.finishFile() }
    }

    // MARK: helpers

    /// Sidecar that exists only while a recording is in flight. A leftover one means we died.
    public static func markerURL(for recording: URL) -> URL {
        recording.deletingLastPathComponent().appendingPathComponent(".\(recording.lastPathComponent).inprogress")
    }

    public static func makeOutputURL(in dir: URL, date: Date = Date()) -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return dir.appendingPathComponent("rec_\(f.string(from: date)).mp4")
    }

    /// Cap to maxDimension, force even dimensions, minimum 128.
    public static func fit(width: Int, height: Int, maxDimension: Int?) -> (Int, Int) {
        var w = width
        var h = height
        if let m = maxDimension, w > m || h > m {
            let aspect = Double(w) / Double(max(h, 1))
            if w >= h {
                w = m
                h = Int(Double(m) / aspect)
            } else {
                h = m
                w = Int(Double(m) * aspect)
            }
        }
        w = max(w / 2 * 2, 128)
        h = max(h / 2 * 2, 128)
        return (w, h)
    }
}
