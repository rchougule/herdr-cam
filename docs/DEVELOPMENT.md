# Development

herdr-cam is three small pieces: a herdr plugin manifest, a POSIX shell launcher, and a
native Swift camera app. The plugin itself has no package dependencies; you need macOS
14+, the Xcode Command Line Tools 15+, and herdr 0.9.1+. Rendering the README media also
needs Node and Google Chrome.

## Layout

| Path | What lives there |
| --- | --- |
| `herdr-plugin.toml` | Manifest: the build step and the `capture` / `doctor` actions |
| `bin/herdr-cam` | Launcher: finds the focused pane, opens the app, reads its result, pastes over the herdr socket |
| `app/Core.swift` | Pure logic: options, key map, tray, result file, image pipeline. No AppKit, so tests compile it headless |
| `app/CamApp.swift` | The camera window: AVFoundation session, preview, tray thumbnails, countdown, idle close |
| `app/Info.plist`, `app/HerdrCam.entitlements` | Bundle metadata and the camera entitlement the hardened runtime needs |
| `scripts/build.sh` | Builds `build/HerdrCam.app` (the plugin's install-time build step) |
| `scripts/test.sh` | Every test that needs no herdr server or camera |
| `scripts/render-media.sh`, `assets/render.mjs` | Render the banner, social preview, and demo GIF from `assets/src/` |
| `tests/` | Swift core tests, launcher tests with fakes, the live e2e test, fixtures |

## How a capture flows

```
prefix+i ─▶ herdr runs `bin/herdr-cam capture` with HERDR_PANE_ID set
              │  takes the one-window lock, detaches a worker, returns at once
              ▼
            open -W build/HerdrCam.app --args --out <captures>/note-<time>-<pid> …
              │  the app owns its camera permission (own bundle, own Info.plist)
              │  Space → photo → Core.processImage → <out>-1.jpg, <out>-2.jpg …
              │  the run always ends by writing <out>.result:
              │    ok + paths  |  cancel  |  error + message
              ▼
            worker reads the result
              │  ok: one pane.send_input with the paths, space separated
              │  error, or no result at all (crash): a herdr notification
              ▼
            Claude Code sees pasted image paths and attaches them as [Image #N]
```

The app is launched through `open` rather than executed directly so macOS treats
HerdrCam as the app asking for the camera. A plain child of the herdr server would
inherit whatever process macOS considers responsible, and has no usage string of its own.
Because `open` drops the app's stderr and exit code, everything the launcher needs to
know travels through the result file.

## Build and link

```sh
sh scripts/build.sh                 # build/HerdrCam.app; skipped when sources are unchanged
herdr plugin link "$PWD"            # register the working tree (link does not run the build)
herdr plugin action invoke rchougule.cam.doctor
```

The bundle is ad-hoc signed with the hardened runtime, and macOS ties the camera grant to
that exact signature, so each rebuild asks for camera access again. `build.sh` skips the
rebuild when nothing changed, and the test suite builds into `build/test/` and
`build/test-release/` so test runs never touch the app the plugin uses.

## Test hooks

`scripts/build.sh DIR --testing` compiles in options that let the suite run without a
person: `--fake-image PATH` (repeatable; skips the camera) and `--auto-capture N` with
`--auto-shots K` (counts down, takes K photos, sends). Release builds reject them. The
launcher forwards them only from the environment, never from `config.env`:

| Variable | Effect |
| --- | --- |
| `HERDR_CAM_APP` | App bundle to launch (the e2e test points it at the test build) |
| `HERDR_CAM_FAKE_IMAGES` | Colon-separated fixture paths, passed as `--fake-image` |
| `HERDR_CAM_AUTO_CAPTURE`, `HERDR_CAM_AUTO_SHOTS` | Passed as `--auto-capture`, `--auto-shots` |
| `HERDR_CAM_OPEN` | Replaces `/usr/bin/open` (the launcher tests use a fake) |
| `HERDR_CAM_NO_DETACH`, `HERDR_CAM_NO_REFOCUS` | Run the worker inline; skip handing focus back |

## Tests

```sh
sh scripts/test.sh                  # everything below except the live suite, about 90s
sh tests/e2e_live.sh                # live: real herdr + Claude Code pane, two fixture photos
sh tests/e2e_live.sh camera         # live: real camera window takes two photos on a countdown
```

| Suite | Covers | Runs in |
| --- | --- | --- |
| `tests/core/main.swift` | Options and their ranges, key map, tray, result file, scaling, orientation, quality, metadata stripping, file permissions. Built twice: with and without the test hooks | CI and local |
| `tests/cli_test.sh` | Launcher against a fake herdr socket, CLI, and `open`: paste shape and escaping, multi-photo paste, pane lookup on a real reply, cancel / error / crash / open failure / paste failure, the lock, config parsing and validation, hooks ignored in config, detached worker, pruning, doctor | CI and local |
| `scripts/test.sh` app steps | Headless run of the real test bundle; the release bundle refuses the hooks, has the hardened runtime and camera usage string | CI and local |
| `tests/e2e_live.sh` | Real herdr socket and a scratch Claude Code pane; waits for `[Image #1] [Image #2]`; runs `doctor` through herdr's plugin runner | local only |

XCTest is not part of the Command Line Tools, so the Swift tests are a small assertion
runner compiled with `swiftc`. The e2e test never touches your `config.env` or captures:
it uses a temporary state directory and pastes into the scratch pane by id.

## Media

`assets/banner.png`, `assets/social-preview.png`, and `assets/demo.gif` are rendered from
`assets/src/`. The hand-drawn sheets are generated in `scene.js`: seeded pen strokes with
overshoot and a second pass, letters placed one by one with measured widths and small
random angles, and an ink filter. `assets/render.mjs` drives the installed Google Chrome
with Playwright and calls the demo's `apply(t)` for each frame.

```sh
sh scripts/render-media.sh          # installs playwright-core into assets/ on first run
```

Open `assets/src/demo.html` in a browser to watch the animation live while editing it.

## Debugging

- Worker log: `~/.local/state/herdr/plugins/rchougule.cam/herdr-cam.log`, one line per run.
- Action runs: `herdr plugin log list --plugin rchougule.cam`.
- Camera permission: System Settings > Privacy & Security > Camera, or
  `tccutil reset Camera dev.rchougule.herdr-cam` to start over.
