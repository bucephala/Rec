import Foundation

/// launchd user agent so Rec is running from login and comes back if it dies.
public enum Service {
    public static let label = "com.rec.app"

    public static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    public static var logDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Rec")
    }

    public static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    /// True when launchd started this process (set by launchd for its jobs).
    public static var runningUnderLaunchd: Bool {
        ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"]?.contains(label) == true
    }

    public static var isLoaded: Bool {
        run("/bin/launchctl", ["print", "gui/\(getuid())/\(label)"]).status == 0
    }

    public static func plist(executable: String, logDir: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(executable)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>ThrottleInterval</key>
            <integer>5</integer>
            <key>ProcessType</key>
            <string>Interactive</string>
            <key>StandardOutPath</key>
            <string>\(logDir)/rec.log</string>
            <key>StandardErrorPath</key>
            <string>\(logDir)/rec.err.log</string>
        </dict>
        </plist>

        """
    }

    @discardableResult
    public static func install(executable: String) -> String? {
        do {
            try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try plist(executable: executable, logDir: logDirectory.path).write(to: plistURL, atomically: true, encoding: .utf8)
        } catch {
            return error.localizedDescription
        }
        // bootstrap fails harmlessly if the running instance already is the agent
        run("/bin/launchctl", ["enable", "gui/\(getuid())/\(label)"])
        let r = run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", plistURL.path])
        if r.status != 0 && !isLoaded { return "launchctl bootstrap failed: \(r.output)" }
        return nil
    }

    /// Removes the agent. If we are the agent this kills us, so callers finalize first.
    public static func uninstall() {
        run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(at: plistURL)
    }

    /// Stop the agent for this login session only. launchd sends SIGTERM to the job.
    public static func stopForSession() {
        run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
    }

    @discardableResult
    static func run(_ path: String, _ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
