import Cocoa
import ScreenCaptureKit
import UserNotifications

public final class AppDelegate: NSObject, NSApplicationDelegate, PickerDelegate, UNUserNotificationCenterDelegate {
    private enum State { case idle, picking, starting, recording, stopping }

    private var statusItem: NSStatusItem!
    private var state: State = .idle { didSet { refreshStatusItem() } }
    private var settings = Settings()
    private let hotkeys = Hotkeys()
    private let picker = Picker()
    private let indicator = Indicator()
    private var recorder: Recorder?
    private var lastTarget: CaptureTarget?
    private var lastRecording: URL?
    private var tickTimer: Timer?
    private var warning: String?
    private var warnedMicSilent = false
    private var fetchTask: Task<Void, Never>?
    private var signalSources: [DispatchSourceSignal] = []

    public override init() { super.init() }

    // MARK: lifecycle

    public func applicationDidFinishLaunching(_ notification: Notification) {
        let bundleID = Bundle.main.bundleIdentifier ?? Service.label
        if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).count > 1 {
            NSLog("Rec: another instance is running, exiting")
            exit(0)
        }
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        refreshStatusItem()

        picker.delegate = self
        indicator.onClick = { [weak self] in self?.toggle() }

        hotkeys.register { [weak self] action in
            switch action {
            case .toggle: self?.toggle()
            case .pick: self?.pickAndRecord()
            }
        }
        if let err = hotkeys.registrationError {
            notify("Hotkey conflict", err)
        }

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }

        installSignalHandlers()
        try? FileManager.default.createDirectory(at: settings.outputDirectory, withIntermediateDirectories: true)

        if !Preflight.hasScreenPermission() {
            Preflight.requestScreenPermission()
        }
        recoverLeftovers()
        NSLog("Rec: ready. toggle %@, pick %@, launchd=%d", hotkeys.toggle.display, hotkeys.pick.display, Service.runningUnderLaunchd ? 1 : 0)
    }

    public func applicationWillTerminate(_ notification: Notification) {
        hotkeys.unregister()
        indicator.hide()
        recorder?.stopAndWait()
    }

    private func recoverLeftovers() {
        let dir = settings.outputDirectory
        let mix = settings.mixdownAfterStop
        Task { [weak self] in
            guard let self = self else { return }
            let result = await Recovery.sweep(dir: dir, mixdown: mix)
            guard let last = result.recovered.last else { return }
            await MainActor.run {
                self.lastRecording = last
                let n = result.recovered.count
                self.notify("Recovered \(n) recording\(n == 1 ? "" : "s") from a crash",
                             last.lastPathComponent, fileURL: last)
            }
        }
    }

    // launchd sends SIGTERM on bootout and at logout. Finish the file before dying.
    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in
                NSLog("Rec: signal %d, finalizing", sig)
                self?.recorder?.stopAndWait()
                exit(0)
            }
            src.resume()
            signalSources.append(src)
        }
    }

    // MARK: status item

    @objc private func statusClicked() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showMenu()
        } else {
            toggle()
        }
    }

    private func showMenu() {
        statusItem.menu = buildMenu()
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func refreshStatusItem() {
        guard let b = statusItem?.button else { return }
        switch state {
        case .idle:
            b.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Rec idle")
            b.contentTintColor = Preflight.hasScreenPermission() ? nil : .systemOrange
            b.title = ""
        case .picking:
            b.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "Rec picking")
            b.contentTintColor = .systemBlue
            b.title = ""
        case .starting, .stopping:
            b.image = NSImage(systemSymbolName: "hourglass", accessibilityDescription: "Rec busy")
            b.contentTintColor = .systemGray
        case .recording:
            b.image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Rec recording")
            b.contentTintColor = .systemRed
        }
        b.toolTip = "Click to \(state == .recording ? "stop" : "record") · right click for menu"
    }

    private func buildMenu() -> NSMenu {
        let m = NSMenu()
        @discardableResult
        func add(_ title: String, _ sel: Selector?, on: Bool? = nil, enabled: Bool = true, key: String = "") -> NSMenuItem {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            i.target = self
            i.isEnabled = enabled
            if let on = on { i.state = on ? .on : .off }
            m.addItem(i)
            return i
        }

        if state == .recording {
            add("Stop Recording  \(hotkeys.toggle.display)", #selector(toggle))
        } else {
            add("Record This Display  \(hotkeys.toggle.display)", #selector(toggle), enabled: state == .idle)
            add("Record Region / Window…  \(hotkeys.pick.display)", #selector(pickAndRecord), enabled: state == .idle)
            add("Record Last Target Again", #selector(repeatLast), enabled: state == .idle && lastTarget != nil)
        }
        m.addItem(.separator())

        add("Reveal Last Recording", #selector(revealLast), enabled: lastRecording != nil)
        add("Copy Last Recording", #selector(copyLast), enabled: lastRecording != nil)
        add("Compress Last for Discord (<10 MB)", #selector(compressLast), enabled: lastRecording != nil && Exporter.ffmpegPath != nil)
        add("Open Recordings Folder", #selector(openFolder))
        m.addItem(.separator())

        // health
        let screenOK = Preflight.hasScreenPermission()
        let micStatus = Preflight.micAuthorized()
        let micName = Preflight.micDeviceName()
        add(screenOK ? "✓ Screen Recording allowed" : "✗ Screen Recording missing (click to fix)",
            screenOK ? nil : #selector(openScreenSettings))
        let micLine: String
        switch (micStatus, micName) {
        case (.authorized, .some(let n)): micLine = "✓ Mic: \(n)"
        case (.authorized, .none): micLine = "✗ No microphone connected"
        case (.notDetermined, _): micLine = "• Mic permission not asked yet"
        default: micLine = "✗ Mic permission denied (click to fix)"
        }
        add(micLine, micStatus == .denied ? #selector(openMicSettings) : nil)
        add(Service.isInstalled ? "✓ Runs at login (always on)" : "✗ Not installed as login service",
            #selector(toggleService), on: Service.isInstalled)
        if Exporter.ffmpegPath == nil {
            add("• ffmpeg not found, mixdown/compress disabled", nil)
        }
        m.addItem(.separator())

        let settingsMenu = NSMenu()
        func opt(_ title: String, _ sel: Selector, _ on: Bool) {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            i.target = self
            i.state = on ? .on : .off
            settingsMenu.addItem(i)
        }
        opt("Record Microphone", #selector(toggleMic), settings.micEnabled)
        opt("Record System Audio", #selector(toggleSystemAudio), settings.systemAudioEnabled)
        settingsMenu.addItem(.separator())
        for q in Quality.allCases {
            let i = NSMenuItem(title: q.rawValue, action: #selector(setQuality(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = q.rawValue
            i.state = settings.quality == q ? .on : .off
            settingsMenu.addItem(i)
        }
        settingsMenu.addItem(.separator())
        opt("Reveal in Finder when done", #selector(toggleReveal), settings.revealAfterStop)
        opt("Copy file to clipboard when done", #selector(toggleCopy), settings.copyAfterStop)
        opt("Mix audio to one track when done (needs ffmpeg)", #selector(toggleMixdown), settings.mixdownAfterStop)
        opt("Keep raw multitrack file", #selector(toggleKeepRaw), settings.keepRawFile)
        settingsMenu.addItem(.separator())

        let toggleMenu = NSMenu()
        for p in ShortcutPreset.toggle {
            let i = NSMenuItem(title: "\(p.shortcut.display)  \(p.label)", action: #selector(setToggleHotkey(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = p.label
            i.state = p.label == hotkeys.togglePresetLabel ? .on : .off
            toggleMenu.addItem(i)
        }
        let toggleItem = NSMenuItem(title: "Record Hotkey", action: nil, keyEquivalent: "")
        toggleItem.submenu = toggleMenu
        settingsMenu.addItem(toggleItem)

        let pickMenu = NSMenu()
        for p in ShortcutPreset.pick {
            let i = NSMenuItem(title: "\(p.shortcut.display)  \(p.label)", action: #selector(setPickHotkey(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = p.label
            i.state = p.label == hotkeys.pickPresetLabel ? .on : .off
            pickMenu.addItem(i)
        }
        let pickItem = NSMenuItem(title: "Region Hotkey", action: nil, keyEquivalent: "")
        pickItem.submenu = pickMenu
        settingsMenu.addItem(pickItem)

        let settingsItem = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        settingsItem.submenu = settingsMenu
        m.addItem(settingsItem)

        add("Open Log", #selector(openLog))
        m.addItem(.separator())
        add(Service.runningUnderLaunchd ? "Quit Until Next Login" : "Quit Rec", #selector(quit), key: "q")
        return m
    }

    // MARK: actions

    @objc private func toggle() {
        switch state {
        case .idle:
            startWithContent { content in
                guard let d = CaptureTarget.displayUnderMouse(in: content) else { throw RecError.noDisplay }
                return .display(d)
            }
        case .picking:
            cancelPicking()
        case .recording:
            stop()
        case .starting, .stopping:
            break
        }
    }

    @objc private func pickAndRecord() {
        switch state {
        case .idle:
            state = .picking
            fetchTask = Task { [weak self] in
                guard let self = self else { return }
                do {
                    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                    await MainActor.run {
                        guard !Task.isCancelled, self.state == .picking else { return }
                        self.picker.show(content: content)
                    }
                } catch {
                    await MainActor.run {
                        self.state = .idle
                        self.fail(RecError.screenPermission)
                    }
                }
            }
        case .picking:
            cancelPicking()
        default:
            break
        }
    }

    @objc private func repeatLast() {
        guard state == .idle, let target = lastTarget else { return }
        startWithContent { content in
            guard let t = target.resolved(with: content) else { throw RecError.noDisplay }
            return t
        }
    }

    private func cancelPicking() {
        fetchTask?.cancel()
        fetchTask = nil
        picker.close()
        state = .idle
    }

    func picker(_ picker: Picker, didPick target: CaptureTarget, content: SCShareableContent) {
        state = .idle
        lastTarget = target
        start(target: target, content: content)
    }

    func pickerDidCancel(_ picker: Picker) {
        state = .idle
    }

    private func startWithContent(_ choose: @escaping (SCShareableContent) throws -> CaptureTarget) {
        guard state == .idle else { return }
        state = .starting
        Task { [weak self] in
            guard let self = self else { return }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                let target = try choose(content)
                await MainActor.run {
                    self.lastTarget = target
                    self.state = .idle
                    self.start(target: target, content: content)
                }
            } catch {
                await MainActor.run {
                    self.state = .idle
                    self.fail(Preflight.hasScreenPermission() ? error : RecError.screenPermission)
                }
            }
        }
    }

    // MARK: recording

    private func start(target: CaptureTarget, content: SCShareableContent) {
        guard state == .idle else { return }
        state = .starting
        warning = nil
        warnedMicSilent = false

        Task { [weak self] in
            guard let self = self else { return }
            do {
                let report = try await Preflight.run(outputDir: settings.outputDirectory, wantMic: settings.micEnabled)
                let rec = Recorder(outputDirectory: settings.outputDirectory)
                rec.quality = settings.quality
                rec.captureSystemAudio = settings.systemAudioEnabled
                rec.captureMic = report.micUsable
                rec.onStop = { [weak self] url in self?.finished(url) }
                rec.onError = { [weak self] err in self?.recordingDied(err) }
                try await rec.start(target: target, content: content)
                await MainActor.run {
                    self.recorder = rec
                    self.state = .recording
                    self.warning = report.warnings.isEmpty ? nil : report.warnings[0]
                    for w in report.warnings { self.notify("Heads up", w) }
                    let screen = NSScreen.screens.first { $0.displayID == target.displayID } ?? NSScreen.main
                    if let s = screen { self.indicator.show(on: s) }
                    NSSound(named: "Morse")?.play()
                    self.tickTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
                    NSLog("Rec: recording %@ -> %@", target.label, rec.outputURL?.lastPathComponent ?? "?")
                }
            } catch {
                await MainActor.run {
                    self.state = .idle
                    self.fail(error)
                }
            }
        }
    }

    @objc private func stop() {
        guard state == .recording, let rec = recorder else { return }
        state = .stopping
        tickTimer?.invalidate()
        tickTimer = nil
        indicator.hide()
        statusItem.button?.title = ""
        rec.stop()
    }

    /// Runs 4x a second while recording. Drives the indicator and the sanity checks.
    private func tick() {
        guard state == .recording, let rec = recorder, let started = rec.stats.startedAt else { return }
        let s = rec.stats
        let elapsed = Date().timeIntervalSince(started)

        // 1. video must flow. A static screen still yields idle frames, so zero means a dead stream.
        if elapsed > 3, s.videoFrames == 0 {
            NSLog("Rec: no frames after 3s, aborting")
            stop()
            return
        }
        if let last = s.lastFrameAt, Date().timeIntervalSince(last) > 10 {
            warning = "No video frames"
        }

        // 2. mic must not be dead if we asked for it
        if s.micRequested {
            if elapsed > 3, s.mic.looksSilent {
                warning = "Mic silent"
                if !warnedMicSilent {
                    warnedMicSilent = true
                    notify("Mic is silent", "No microphone signal in the first seconds. Check the input device or mute.")
                }
            } else if warning == "Mic silent", !s.mic.looksSilent {
                warning = nil
            }
        }

        indicator.update(elapsed: elapsed, system: s.system.currentPeak,
                         mic: s.micRequested ? s.mic.currentPeak : nil, warning: warning)
        let secs = Int(elapsed)
        statusItem.button?.title = String(format: " %d:%02d", secs / 60, secs % 60)
    }

    private func finished(_ url: URL) {
        tickTimer?.invalidate()
        tickTimer = nil
        indicator.hide()
        statusItem.button?.title = ""
        recorder = nil
        state = .idle
        NSSound(named: "Glass")?.play()

        Task { [weak self] in
            guard let self = self else { return }
            let final = settings.mixdownAfterStop
                ? await Exporter.mixdown(url, keepRaw: settings.keepRawFile)
                : url
            await MainActor.run {
                self.lastRecording = final
                if self.settings.copyAfterStop { Exporter.copyToClipboard(final) }
                let size = (try? final.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Double($0) / 1_000_000 } ?? 0
                self.notify("Saved \(final.lastPathComponent)",
                            String(format: "%.1f MB%@", size, self.settings.copyAfterStop ? " · copied, paste anywhere" : ""),
                            fileURL: final)
                if self.settings.revealAfterStop {
                    NSWorkspace.shared.activateFileViewerSelecting([final])
                }
                NSLog("Rec: saved %@ (%.1f MB)", final.path, size)
            }
        }
    }

    private func recordingDied(_ error: Error) {
        tickTimer?.invalidate()
        tickTimer = nil
        indicator.hide()
        statusItem.button?.title = ""
        recorder = nil
        state = .idle
        fail(error)
    }

    private func fail(_ error: Error) {
        NSSound(named: "Basso")?.play()
        NSLog("Rec ERROR: %@", error.localizedDescription)
        if let e = error as? RecError, case .screenPermission = e {
            showPermissionAlert()
        } else if let e = error as? RecError, case .noVideoFrames = e {
            showPermissionAlert(message: e.localizedDescription)
        } else {
            notify("Recording failed", error.localizedDescription)
        }
    }

    // MARK: menu actions

    @objc private func revealLast() {
        if let u = lastRecording { NSWorkspace.shared.activateFileViewerSelecting([u]) }
    }

    @objc private func copyLast() {
        guard let u = lastRecording else { return }
        Exporter.copyToClipboard(u)
        notify("Copied", u.lastPathComponent)
    }

    @objc private func compressLast() {
        guard let u = lastRecording else { return }
        notify("Compressing…", u.lastPathComponent)
        Task { [weak self] in
            guard let self = self else { return }
            do {
                let out = try await Exporter.compressForDiscord(u)
                let size = (try? out.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Double($0) / 1_000_000 } ?? 0
                await MainActor.run {
                    Exporter.copyToClipboard(out)
                    self.notify("Discord version ready", String(format: "%.1f MB · copied to clipboard", size), fileURL: out)
                    NSWorkspace.shared.activateFileViewerSelecting([out])
                }
            } catch {
                await MainActor.run { self.notify("Compress failed", error.localizedDescription) }
            }
        }
    }

    @objc private func openFolder() {
        try? FileManager.default.createDirectory(at: settings.outputDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(settings.outputDirectory)
    }

    @objc private func openLog() {
        let log = Service.logDirectory.appendingPathComponent("rec.err.log")
        if FileManager.default.fileExists(atPath: log.path) {
            NSWorkspace.shared.open(log)
        } else {
            notify("No log yet", "Logs appear once Rec runs as a login service.")
        }
    }

    @objc private func openScreenSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    @objc private func openMicSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }

    @objc private func toggleService() {
        if Service.isInstalled {
            // uninstall kills the agent if we are it, so detach and let a fresh copy run plain
            Service.uninstall()
            notify("Login service removed", "Rec will not start at login anymore.")
        } else {
            guard let exe = Bundle.main.executablePath else { return }
            if let err = Service.install(executable: exe) {
                notify("Could not install service", err)
            } else {
                notify("Installed", "Rec now starts at login and restarts if it crashes.")
            }
        }
    }

    @objc private func toggleMic() { settings.micEnabled.toggle() }
    @objc private func toggleSystemAudio() { settings.systemAudioEnabled.toggle() }
    @objc private func toggleReveal() { settings.revealAfterStop.toggle() }
    @objc private func toggleCopy() { settings.copyAfterStop.toggle() }
    @objc private func toggleMixdown() { settings.mixdownAfterStop.toggle() }
    @objc private func toggleKeepRaw() { settings.keepRawFile.toggle() }

    @objc private func setQuality(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let q = Quality(rawValue: raw) { settings.quality = q }
    }

    @objc private func setToggleHotkey(_ sender: NSMenuItem) {
        guard let p = ShortcutPreset.toggle.first(where: { $0.label == sender.representedObject as? String }) else { return }
        if let err = hotkeys.setToggle(p) { notify("Hotkey conflict", err) }
    }

    @objc private func setPickHotkey(_ sender: NSMenuItem) {
        guard let p = ShortcutPreset.pick.first(where: { $0.label == sender.representedObject as? String }) else { return }
        if let err = hotkeys.setPick(p) { notify("Hotkey conflict", err) }
    }

    @objc private func quit() {
        recorder?.stopAndWait()
        if Service.runningUnderLaunchd {
            Service.stopForSession()
        }
        NSApp.terminate(nil)
    }

    // MARK: UI helpers

    private func showPermissionAlert(message: String? = nil) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Screen Recording permission needed"
        a.informativeText = message ?? "Turn on Rec in System Settings → Privacy & Security → Screen Recording. macOS then asks you to quit and reopen Rec. As a login service it comes back on its own."
        a.alertStyle = .warning
        a.addButton(withTitle: "Open System Settings")
        a.addButton(withTitle: "Later")
        if a.runModal() == .alertFirstButtonReturn { openScreenSettings() }
    }

    private func notify(_ title: String, _ body: String, fileURL: URL? = nil) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = nil
        if let u = fileURL { c.userInfo = ["path": u.path] }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    public func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        if let path = response.notification.request.content.userInfo["path"] as? String {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
    }

    public func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner]
    }
}
