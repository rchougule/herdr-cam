# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [0.1.1] - 2026-10-09

### Fixed

- The camera window takes keyboard focus when it opens, so `Space` and `Enter` work
  without clicking it first. On macOS 14+ an app launched from herdr's background
  process could not activate itself; the window is now a non-activating panel, which
  becomes key while your terminal stays the active app.

## [0.1.0] - 2026-10-09

First public release.

### Added

- `prefix+i` opens a camera window with a live preview. `Space` adds a photo to a tray of
  thumbnails, `Enter` sends them all to the focused herdr pane as one paste (an empty
  tray takes one photo and sends it), `Delete` drops the last photo, `Esc` discards
  everything. Claude Code attaches them as `[Image #1] [Image #2] …`.
- `T` countdown capture, `C` camera switching (built-in, external, iPhone Continuity
  Camera, Desk View), `M` preview mirroring. The window takes the camera's frame shape.
- Photos are scaled to a 2048px long edge, re-encoded as JPEG, stripped of location and
  camera metadata, saved readable only by you, and deleted after `KEEP_DAYS`.
- The window closes by itself after 3 minutes without a key press.
- `config.env` settings `MAX_EDGE`, `QUALITY`, `TIMER`, `KEEP_DAYS`, validated, with
  problems reported instead of silently ignored.
- `doctor` action that checks the build, the herdr socket, the keybinding, and settings,
  and shows its verdict as a notification.
- Every failure (camera denied, no camera, a crash, a paste that could not land) is
  reported as a herdr notification.
- The app is signed with the hardened runtime; the test suite's automatic-capture hooks
  exist only in test builds.

[0.1.1]: https://github.com/rchougule/herdr-cam/releases/tag/v0.1.1
[0.1.0]: https://github.com/rchougule/herdr-cam/releases/tag/v0.1.0
