# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [0.1.0] - 2026-10-09

### Added

- `prefix+i` opens a camera window with a live preview; `Space` captures and pastes the
  photo into the focused herdr pane. Claude Code attaches it as `[Image #N]`.
- `T` countdown capture for hands-free shots, `C` to switch cameras (built-in, external,
  iPhone Continuity Camera, Desk View), `M` to mirror the preview.
- The window takes the camera's frame shape, so the preview shows exactly what the photo
  will contain.
- Photos are scaled to a 2048px long edge, re-encoded as JPEG, and stripped of location
  and camera metadata.
- `config.env` settings: `MAX_EDGE`, `QUALITY`, `TIMER`, `KEEP_DAYS`.
- `doctor` action that checks the build, the herdr socket, and the keybinding.

[0.1.0]: https://github.com/rchougule/herdr-cam/releases/tag/v0.1.0
