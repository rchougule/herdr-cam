<p align="center">
  <img src="assets/banner.png" alt="herdr-cam: show your agent what's on your desk" width="900">
</p>

<p align="center">
  <a href="https://github.com/rchougule/herdr-cam/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/rchougule/herdr-cam/actions/workflows/ci.yml/badge.svg"></a>
  <img alt="herdr 0.9.1+" src="https://img.shields.io/badge/herdr-0.9.1%2B-blue">
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-lightgrey">
  <img alt="Swift" src="https://img.shields.io/badge/built%20with-Swift-orange">
  <a href="LICENSE"><img alt="MIT" src="https://img.shields.io/badge/license-MIT-green"></a>
</p>

# herdr-cam

Some things are easier to show than to type. herdr-cam is a [herdr](https://herdr.dev)
plugin that puts your webcam one keystroke away from your coding agent: press `prefix+i`,
point the camera, press `Space`, and the photo is in the agent's prompt as an image.

<p align="center">
  <img src="assets/demo.gif" alt="Pressing ctrl+b i opens a camera window over a Claude Code pane; Space captures a handwritten table, which appears in the prompt as [Image #1]" width="800">
</p>

```
  before                                      after
  ──────                                      ─────
  open Photo Booth, take the photo            prefix+i   camera window opens
  ⌘C                                          Space      photo is in the prompt
  switch back, find the right pane                       as [Image #1]
  ctrl+V
```

## What people show their agent

- **Handwritten work.** A dry run of an algorithm, a derivation, a formula worked by hand.
  "Is my table right?"
- **Whiteboards and paper sketches.** An architecture diagram after a meeting, a paper
  wireframe: "build this layout".
- **Physical screens.** An error on a device display, a blinking status LED, a boot
  message on a machine with no network.
- **Hardware.** A breadboard, a pinout label, a serial number on the back of a router.
- **Printed pages.** A textbook exercise, a printed spec, a code listing in a book.

An iPhone works as the camera too, through Continuity Camera. Its Desk View mode turns it
into a document camera pointed at the desk.

## Install

Needs macOS 14+, herdr 0.9.1+, and the Xcode Command Line Tools
(`xcode-select --install`), because the install step compiles the camera app.

```sh
herdr plugin install rchougule/herdr-cam
```

Bind it in `~/.config/herdr/config.toml`. `prefix+i` is free in herdr's default keymap.

```toml
[[keys.command]]
key = "prefix+i"                      # ctrl+b, then i
type = "plugin_action"
command = "rchougule.cam.capture"
description = "Photo into this pane"
```

```sh
herdr server reload-config
herdr plugin action invoke rchougule.cam.doctor
```

The first capture asks for camera access for **HerdrCam**. Allow it once.

## Usage

Focus the pane running your agent and press `prefix+i`. A window opens with a live
preview of exactly what the photo will contain.

| Key | In the camera window |
| --- | --- |
| `Space` / `Return` | Capture and paste |
| `T` | Capture after a 3 second countdown, for when both hands hold the page |
| `C` | Next camera: built-in, external, iPhone, Desk View |
| `M` | Mirror the preview (the photo itself is never mirrored) |
| `Esc` / `Q` | Close without pasting anything |

The photo is pasted, not sent. Add your question and press Enter yourself. Your camera
and mirror choices are remembered.

## Agent support

| Agent | What arrives |
| --- | --- |
| Claude Code | An image attachment, `[Image #N]` |
| Codex | The file path as text; Codex opens it with its image tool when asked |
| Anything else | The file path, pasted at the cursor |

## Settings

Optional. Put `KEY=VALUE` lines in `$(herdr plugin config-dir rchougule.cam)/config.env`.

| Key | Default | Meaning |
| --- | --- | --- |
| `MAX_EDGE` | `2048` | Long edge of the saved photo in pixels. Claude downscales past ~1568 anyway |
| `QUALITY` | `0.85` | JPEG quality, 0 to 1 |
| `TIMER` | `3` | Countdown seconds for `T`, 1 to 30 |
| `KEEP_DAYS` | `30` | Delete captures older than this. `0` keeps everything |

## Privacy

- No network code and no telemetry. The plugin talks only to your local herdr server.
- The camera runs only while the window is open, with macOS's green indicator on.
- Photos are saved under `~/.local/state/herdr/plugins/rchougule.cam/captures/`, stripped
  of location and camera metadata, and deleted after `KEEP_DAYS`.
- Your clipboard is never touched, and nothing is sent until you press Enter. Once you
  do, the image goes to your agent's model provider like anything else you send.

More in [SECURITY.md](SECURITY.md).

## How it works

```
 prefix+i ─▶ herdr plugin action ─▶ bin/herdr-cam
                                       │  remembers the focused pane
                                       ▼
                              HerdrCam.app (Swift, AVFoundation)
                              live preview, Space captures
                                       │  JPEG, metadata stripped
                                       ▼
              herdr socket: pane.send_input (a bracketed paste of the file path)
                                       │
                                       ▼
                    Claude Code turns the pasted path into [Image #1]
```

The camera window is a small native app with its own camera permission, opened for each
capture and closed after. Details in [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

## Limits

- macOS only; the camera app is AppKit and AVFoundation.
- The app is ad-hoc signed, so macOS asks for camera access again after a reinstall.
- One camera window at a time. A second `prefix+i` brings the open one forward.

## FAQ

**Why a native window and not a preview inside the terminal?** A live camera preview
needs a steady frame rate to aim a page at; terminal image protocols are too slow for
that.

**Does it work over SSH or with a remote herdr?** No. The camera and the agent pane need
to be on the same Mac.

**Can it paste into the clipboard instead?** Not today. Pasting the path keeps your
clipboard intact and works with any agent that reads image paths.

## Contributing

Issues and pull requests are welcome. [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) covers the
layout, the capture flow, and the test suites; `sh scripts/test.sh` runs everything that
needs no camera. For bugs, include the `doctor` output (the issue template asks for it).

## License

[MIT](LICENSE) © 2026 Rohan Chougule
