import Foundation

public enum Quality: String, CaseIterable {
    case medium = "1080p 30fps"
    case high = "Native 60fps"

    public var videoBitRate: Int {
        switch self {
        case .medium: return 6_000_000
        case .high: return 12_000_000
        }
    }

    public var fps: Int {
        switch self {
        case .medium: return 30
        case .high: return 60
        }
    }

    public var maxDimension: Int? {
        switch self {
        case .medium: return 1920
        case .high: return nil
        }
    }
}

public struct Settings {
    let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var quality: Quality {
        get { defaults.string(forKey: "quality").flatMap(Quality.init) ?? .high }
        set { defaults.set(newValue.rawValue, forKey: "quality") }
    }

    public var micEnabled: Bool {
        get { bool("micEnabled", default: true) }
        set { defaults.set(newValue, forKey: "micEnabled") }
    }

    public var systemAudioEnabled: Bool {
        get { bool("systemAudioEnabled", default: true) }
        set { defaults.set(newValue, forKey: "systemAudioEnabled") }
    }

    public var revealAfterStop: Bool {
        get { bool("revealAfterStop", default: true) }
        set { defaults.set(newValue, forKey: "revealAfterStop") }
    }

    public var copyAfterStop: Bool {
        get { bool("copyAfterStop", default: true) }
        set { defaults.set(newValue, forKey: "copyAfterStop") }
    }

    // mixes system + mic into one track so Discord and friends play both
    public var mixdownAfterStop: Bool {
        get { bool("mixdownAfterStop", default: true) }
        set { defaults.set(newValue, forKey: "mixdownAfterStop") }
    }

    public var keepRawFile: Bool {
        get { bool("keepRawFile", default: false) }
        set { defaults.set(newValue, forKey: "keepRawFile") }
    }

    public var outputDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/Recordings")
    }

    private func bool(_ key: String, default value: Bool) -> Bool {
        defaults.object(forKey: key) as? Bool ?? value
    }
}
