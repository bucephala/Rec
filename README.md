# Rec

Always-on screen recorder for macOS. One hotkey starts, the same hotkey stops. Runs as a login service so it is there every boot, restarts itself if it dies, and tells you while recording whether audio is actually flowing.

Requires macOS 15+. Swift only, no dependencies. ffmpeg is optional (audio mixdown and Discord compression).

## Install

```bash
git clone <repo>
cd Rec
./Scripts/install.sh
```

That builds, copies `Rec.app` to `~/Applications`, registers a launchd agent and starts it. A record icon shows up in the menu bar. The first time you record, macOS asks for Screen Recording (and Microphone). Allow both, then it is hands off.

Optional, recommended: `./Scripts/setup-signing.sh` once. It makes a local signing certificate so macOS keeps the permissions across rebuilds. Without it, ad-hoc signing means a re-prompt after every rebuild.

## Use

| Action | How |
|---|---|
| Record the display the mouse is on | `⌃⌘R`, or left click the menu bar icon |
| Stop | same hotkey, click the icon, or click the red pill |
| Record a region / window | `⌃⌘E`, then drag, click a window, or ⌥click a display |
| Menu | right click the menu bar icon |

While recording a red pill sits at the top of the recorded display with the timer and two live level meters (SYS and MIC). If the mic produces nothing in the first 3 seconds the pill turns orange and says MIC SILENT, and you get a notification. If no video frames arrive the recording aborts and you get told to re-check the permission instead of silently saving a black file.

When you stop:

- file lands in `~/Movies/Recordings/rec_YYYY-MM-DD_HH-mm-ss.mp4`
- system audio and mic are mixed into one track (so Discord and friends play both)
- the file is copied to the clipboard, ⌘V into Discord, Slack, iMessage
- Finder reveals it

All of that is toggleable under Settings in the menu. Hotkeys have 4 presets each, including single key F9/F10.

**Compress Last for Discord** re-encodes the last recording to under 10 MB and copies that.

## Safeguards

- preflight before every recording: screen permission, mic permission and device, writable output folder, 500 MB free disk
- session starts on the first video frame, so audio never leads a black screen
- fragmented mp4 while recording, so a crash or force quit leaves a playable file
- on launch, leftovers from a crash are detected, cleaned up through ffmpeg and you get a notification
- launchd `KeepAlive`, a crash brings it back in 5 seconds
- SIGTERM (logout, `launchctl bootout`) finalizes the file before exit
- single instance guard
- health lines in the menu show permission and service state at a glance

## Self test

```bash
~/Applications/Rec.app/Contents/MacOS/Rec --selftest 5
```

Records 5 seconds headless, prints frame and audio counts every second, verifies the file, exits 0 on PASS. Add `--keep` to keep the clip, `--no-mic` to skip the microphone.

## Service control

```bash
launchctl print gui/$(id -u)/com.rec.app        # status
launchctl kickstart -k gui/$(id -u)/com.rec.app # restart
./Scripts/uninstall.sh                          # remove app + agent, keeps recordings
tail -f ~/Library/Logs/Rec/rec.err.log          # logs
```

Quit from the menu stops it until next login. Untick "Runs at login" to remove the agent entirely.

## Layout

```
Sources/RecLib/
  App.swift        menu bar, state machine, sanity ticks, notifications
  Recorder.swift   ScreenCaptureKit -> AVAssetWriter, metering, fragmented output
  AudioMeter.swift peak tracking and silence detection
  Preflight.swift  permission / disk / device checks, error types
  Indicator.swift  the red pill
  Picker.swift     region / window / display overlay
  Hotkeys.swift    Carbon global hotkeys + presets
  Service.swift    launchd agent install / status
  Exporter.swift   ffmpeg mixdown, Discord compress, clipboard
  Recovery.swift   crash leftover sweep on launch
  SelfTest.swift   headless --selftest
Sources/Rec/main.swift
Tests/RecTests/    unit tests + opt-in integration capture test
Scripts/           build.sh install.sh uninstall.sh setup-signing.sh
```

```bash
swift test                                         # unit tests
REC_INTEGRATION=1 swift test --filter Integration  # real 4s capture, needs screen permission in your terminal
```

MIT.
