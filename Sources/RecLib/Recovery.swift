import AVFoundation
import Foundation

/// Finds recordings whose in-progress marker survived (we crashed or lost power),
/// turns the fragmented leftovers into clean files, and reports what was saved.
public enum Recovery {
    public struct Result {
        public let recovered: [URL]
        public let discarded: [URL]
    }

    public static func markers(in dir: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil,
                                                                  options: [])) ?? []
        return items.filter { $0.lastPathComponent.hasPrefix(".") && $0.pathExtension == "inprogress" }
    }

    public static func recordingURL(forMarker marker: URL) -> URL {
        var name = marker.lastPathComponent
        name.removeFirst()
        name = String(name.dropLast(".inprogress".count))
        return marker.deletingLastPathComponent().appendingPathComponent(name)
    }

    public static func sweep(dir: URL, mixdown: Bool) async -> Result {
        var recovered: [URL] = []
        var discarded: [URL] = []
        for marker in markers(in: dir) {
            let url = recordingURL(forMarker: marker)
            try? FileManager.default.removeItem(at: marker)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let seconds = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
            if seconds < 0.5 {
                try? FileManager.default.removeItem(at: url)
                discarded.append(url)
                continue
            }
            let final = mixdown ? await Exporter.mixdown(url, keepRaw: false) : url
            NSLog("Rec: recovered %@ (%.1fs)", final.lastPathComponent, seconds)
            recovered.append(final)
        }
        return Result(recovered: recovered, discarded: discarded)
    }
}
