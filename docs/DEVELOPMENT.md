# Development

herdr-cam is three small pieces: a herdr plugin manifest, a POSIX shell launcher, and a
native Swift camera app. There are no package dependencies; you need macOS 14+, the Xcode
Command Line Tools, and herdr 0.9.1+.

## Layout

| Path | What lives there |
| --- | --- |
| `herdr-plugin.toml` | Manifest: the build step and the `capture` / `doctor` actions |
| `bin/herdr-cam` | Launcher: finds the focused pane, opens the app, pastes the result over the herdr socket |
| `app/Core.swift` | Pure logic: argument parsing, key map, image pipeline. No AppKit, so tests compile it headless |
| `app/CamApp.swift` | The camera window: AVFoundation session, preview, capture, countdown |
| `app/Info.plist` | Bundle metadata, including the camera usage string |
| `scripts/build.sh` | Builds `build/HerdrCam.app` (the plugin's install-time build step) |
| `scripts/test.sh` | Every test that needs no herdr server or camera |
| `scripts/render-media.sh` | Renders the README banner, social preview, and demo GIF from `assets/src/` |
| `tests/` | Swift core tests, launcher tests with fakes, the live e2e test, fixtures |

## How a capture flows

```
prefix+i ─▶ herdr runs `bin/herdr-cam capture` with HERDR_PANE_ID set
              │  detaches a worker so the keybinding returns at once
              ▼
            open -W build/HerdrCam.app --args --out <state>/captures/note-….jpg
              │  the app owns its camera permission (own bundle, own Info.plist)
              │  Space → AVCapturePhotoOutput → Core.processImage → atomic write
              │  failures go to <out>.err, cancel writes nothing
              ▼
            pane.send_input {pane_id, text: <path>} over $HERDR_SOCKET_PATH
              │  herdr wraps text in bracketed-paste markers when the app asked for them
              ▼
            Claude Code sees a pasted image path and attaches it as [Image #N]
```

The app is launched through `open` rather than executed directly so macOS treats
HerdrCam as the app asking for the camera. A plain child of the herdr server would
inherit whatever process macOS considers responsible, and has no usage string of its own.

## Build and link

```sh
sh scripts/build.sh                 # build/HerdrCam.app; skips when sources are unchanged
herdr plugin link "$PWD"            # register the working tree (link does not run the build)
herdr plugin action invoke rchougule.cam.doctor
```

The bundle is ad-hoc signed, and macOS ties the camera grant to that exact signature. Each
rebuild therefore asks for camera access again. `build.sh` skips the rebuild when nothing
changed, and `scripts/test.sh` builds into `build/test/` so test runs never touch the app
the plugin uses.

## Tests

```sh
sh scripts/test.sh                  # core + launcher tests, test build, headless app run
sh tests/e2e_live.sh                # live: real herdr + Claude Code pane, fixture photo
sh tests/e2e_live.sh camera         # live: real camera window, auto-captures after 6s
```

| Suite | Covers | Runs in |
| --- | --- | --- |
| `tests/core/main.swift` | Argument parsing, key map, image scaling and orientation, metadata stripping | CI and local |
| `tests/cli_test.sh` | Launcher against a fake herdr socket, CLI, and camera: paste request shape and escaping, pane fallback, cancel, error notification, config, pruning, manifest | CI and local |
| `scripts/test.sh` smoke step | Builds the real bundle and runs it headless on a fixture | CI and local |
| `tests/e2e_live.sh` | Fires the real plugin action through herdr into a scratch Claude Code pane and waits for `[Image #1]` | local only |

XCTest is not part of the Command Line Tools, so the Swift tests are a small assertion
runner compiled with `swiftc`.

The e2e test drives the plugin through two test-only `config.env` keys and restores the
file afterwards: `HERDR_CAM_FAKE_IMAGE=/path/to.png` swaps the camera for a file, and
`HERDR_CAM_AUTO_CAPTURE=N` starts the countdown as soon as the camera is live.

## Media

`assets/banner.png`, `assets/social-preview.png`, and `assets/demo.gif` are rendered from
the HTML in `assets/src/` with headless Chrome. The demo page draws the frame for the time
in its URL hash (`demo.html#t=3.2`), and open without a hash it plays live in a browser.

```sh
sh scripts/render-media.sh          # needs Google Chrome; gifski if present, else ffmpeg
```

## Debugging

- Worker log: `~/.local/state/herdr/plugins/rchougule.cam/herdr-cam.log`, one line per capture.
- Action runs: `herdr plugin log list --plugin rchougule.cam`.
- Camera permission: System Settings > Privacy & Security > Camera, or
  `tccutil reset Camera dev.rchougule.herdr-cam` to start over.
