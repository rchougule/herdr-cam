# herdr-cam

A herdr plugin for macOS: `prefix+i` opens a native camera window, `Space` adds photos to a
tray, `Enter` pastes their paths into the focused herdr pane as one bracketed paste, where
Claude Code turns them into `[Image #N]` attachments. Read `README.md` for the product and
`docs/DEVELOPMENT.md` for the full design; this file is the short version for agents.

## Commands

```sh
sh scripts/test.sh                 # all offline tests (~90s): core x2, launcher, app smoke
sh scripts/build.sh                # build/HerdrCam.app (what the plugin runs)
sh scripts/build.sh build/test --testing   # test build with the automation hooks
sh tests/e2e_live.sh               # live: needs a running herdr and the claude CLI
sh tests/e2e_live.sh camera        # live with the real webcam; ask the user first
sh scripts/render-media.sh         # re-render banner, social preview, demo GIF
shellcheck -s sh bin/herdr-cam scripts/*.sh tests/*.sh tests/support/fake-open tests/support/fake-herdr
```

## Layout

- `bin/herdr-cam`: POSIX sh launcher. Plugin action entry (`capture`), detached worker
  (`__run`), `paste`, `prune`, `doctor`.
- `app/Core.swift`: pure logic (options, key map, `Tray`, `RunResult`, `processImage`).
  No AppKit, so `tests/core/main.swift` compiles it with plain `swiftc`.
- `app/CamApp.swift`: the AppKit/AVFoundation window. `Camera` owns the session on a
  serial queue; everything else is main-thread.
- `assets/src/`: HTML/JS sources for the README media; `assets/render.mjs` renders them
  with Playwright driving the installed Chrome.

## How the pieces talk

- Launcher runs `open -W HerdrCam.app --args --out <base> …`. `open` drops the app's
  stderr and exit code, so the app always ends by writing `<base>.result`
  (`ok` + paths, `cancel`, or `error` + message). No result file means a crash; the
  launcher reports it. Keep this contract when changing either side.
- Paste goes over the herdr socket as `pane.send_input` (raw JSON through `nc -U`), which
  herdr wraps in bracketed-paste markers. Multiple paths go in one paste, space separated.
- The pane id comes from `HERDR_PANE_ID`, else `herdr pane current` parsed with `plutil`.

## Rules that are easy to break

- **Camera permission and rebuilds.** The app is ad-hoc signed; macOS ties the camera grant
  to the exact signature. Every rebuild of `build/HerdrCam.app` makes the user click
  Allow again. Do not rebuild it casually; tests build into `build/test/` and
  `build/test-release/`. Batch app changes and rebuild the release app once at the end.
- **Test hooks are test-build only.** `--fake-image`, `--auto-capture`, `--auto-shots` are
  behind `#if HERDR_CAM_TESTING`. The launcher forwards them only from environment
  variables (`HERDR_CAM_*`), never from `config.env`. Do not move them into release
  builds or config; a release build must never take a photo without a key press.
- **`config.env` is data.** It is parsed key by key and validated; never `source` it.
- **Privacy.** `umask 077` in the launcher, 0700/0600 from Swift. Metadata stripping is
  tested; keep `processImage` re-encoding from pixels, not copying properties.
- **Keyboard focus.** The window is a non-activating `NSPanel`. Do not switch back to an
  `NSWindow` with `NSApp.activate()`: on macOS 14+ an app launched from herdr's
  background process cannot activate itself that way, the window opens without focus,
  and Space goes to the terminal (the v0.1.0 bug). `e2e_live.sh` checks this with
  `--focus-check`.
- **Hardened runtime** needs `app/HerdrCam.entitlements` (camera). Keep both in `build.sh`.
- **Never point the live e2e at the user's own pane or config.** It uses a scratch pane,
  pastes by pane id, and keeps state in a temp dir.
- **Ask before anything that opens the real camera** (`e2e_live.sh camera`, launching the
  app without `--fake-image`): it lights the camera and may show a permission prompt.

## Shell gotchas we have hit

- In POSIX sh, `VAR=x some_function` leaks `VAR` into the rest of the script. The launcher
  tests call captures through `env` for this reason.
- `plutil -extract … raw` prints its errors on stdout; check its exit status.
- A paste into a Claude Code session that started seconds ago can stay plain text; the
  e2e waits for herdr to report the agent idle first.
- A same-page `#hash` navigation does not re-run a page's script; `render.mjs` goes via
  `about:blank`.

## Testing expectations

Write the test first for any behaviour change. Swift logic goes in `Core.swift` with a
check in `tests/core/main.swift`; launcher behaviour gets a case in `tests/cli_test.sh`
(assert the exit code too). UI changes in `CamApp.swift` need a live run: fixture mode at
least, camera mode with the user's go-ahead. Keep `README.md`, `SECURITY.md`,
`docs/DEVELOPMENT.md`, and `CHANGELOG.md` in step with behaviour; the README's claims are
checked by reviewers against the code.
