# Rec

Always-on macOS menu bar screen recorder. Successor to ../ClippingMacOS, which was feature rich but not a service and had no audio sanity checks. Engine shape (SCStream + AVAssetWriter, NSLock hot path, writerQueue lifecycle, Carbon hotkeys, overlay picker) was carried over from Clipping and trimmed.

## Goals that drove the design

- one button: toggle hotkey records the display under the mouse, no picker step. Left click on the status item does the same, right click opens the menu. Clicking the red pill stops.
- always running: launchd agent `com.rec.app` with RunAtLoad + KeepAlive, exec's the binary inside ~/Applications/Rec.app. Quit from the menu = `launchctl bootout` for this session.
- prove audio is flowing: Recorder tracks peak per track (AudioMeter), App.tick runs 4x/s, mic silent after 3s -> orange pill + notification. Zero video frames after 3s -> abort with permission hint.
- never lose a recording: movieFragmentInterval 2s, `.name.inprogress` marker while recording, Recovery.sweep on launch remuxes leftovers, SIGTERM handler finalizes, single instance guard.
- easy sharing: ffmpeg mixdown to one audio track (Discord plays only the first track), copy file to clipboard, reveal in Finder, "Compress for Discord" under 10 MB.

## Build / test / install

```bash
swift build && swift test
REC_INTEGRATION=1 swift test --filter Integration   # real capture, terminal needs Screen Recording permission
Scripts/install.sh                                  # release build, ~/Applications, launchd bootstrap
~/Applications/Rec.app/Contents/MacOS/Rec --selftest 5 --keep
```

Package is swift-tools 6.0 with swiftLanguageModes [.v5] (needed for .macOS(.v15)). Don't rename `finishFile` back to `finalize`, it collides with NSObject.

## Status (2026-11-01)

- built, 36 unit tests + opt-in integration capture test pass, installed and running under launchd on this machine
- verified: 4s real capture, kill -9 mid recording leaves a playable fragmented file, Recovery sweep on launch cleans it, SIGTERM finalizes
- fixed a session start race (audio queue appending before startSession). startSession now runs under the lock
- signing cert (Scripts/setup-signing.sh) not yet run, app is ad-hoc signed so TCC re-prompts after rebuilds
- pushed to https://github.com/bucephala/Rec (public). User decided to consolidate on bucephala going forward
