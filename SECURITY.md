# Security

herdr-cam is a camera tool, so here is exactly what it does with your camera and photos.

- **Local only.** There is no network code and no telemetry. The plugin talks only to
  your local herdr server over its Unix socket.
- **Camera on only while the window is open.** The capture session stops when the window
  closes, macOS shows its green camera indicator while it runs, and the window closes by
  itself after 3 minutes without a key press.
- **A photo needs a key press.** Release builds have no option that takes a photo on its
  own; the automatic-capture hooks used by the test suite are compiled only into test
  builds. The app is signed with the hardened runtime, so other processes cannot inject
  code into it to borrow its camera permission. Access is granted to the `HerdrCam` app
  (`dev.rchougule.herdr-cam`) and can be revoked with
  `tccutil reset Camera dev.rchougule.herdr-cam`.
- **Photos stay on disk, private.** Captures are saved under
  `~/.local/state/herdr/plugins/rchougule.cam/captures/` with permissions that only your
  user can read (folder 0700, files 0600). Location and camera metadata are stripped
  before saving. Discarded photos are deleted at once; sent ones are deleted after
  `KEEP_DAYS` (30 by default, checked on each capture).
- **Settings are data.** `config.env` is parsed for four known keys and never executed.
- **Nothing is sent for you.** The photos' paths are pasted into the prompt; you press
  Enter. Once you do, the images go to your agent's model provider under that provider's
  terms.

## Reporting a vulnerability

Please report security issues privately through
[GitHub security advisories](https://github.com/rchougule/herdr-cam/security/advisories/new)
rather than a public issue. You can expect a reply within a week.
