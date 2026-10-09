# Security

herdr-cam is a camera tool, so here is exactly what it does with your camera and photos.

- **Local only.** There is no network code and no telemetry. The plugin talks only to
  your local herdr server over its Unix socket.
- **Camera on only while the window is open.** The capture session stops when the window
  closes, and macOS shows its green camera indicator while it runs. Access is granted to
  the `HerdrCam` app alone and can be revoked with
  `tccutil reset Camera dev.rchougule.herdr-cam`.
- **Photos stay on disk, briefly.** Captures are saved under
  `~/.local/state/herdr/plugins/rchougule.cam/captures/` and deleted after `KEEP_DAYS`
  (30 by default). Location and camera metadata are stripped before saving.
- **Nothing is sent for you.** The photo's path is pasted into the prompt; you press
  Enter. Once you do, the image goes to your agent's model provider under that
  provider's terms.

## Reporting a vulnerability

Please report security issues privately through
[GitHub security advisories](https://github.com/rchougule/herdr-cam/security/advisories/new)
rather than a public issue. You can expect a reply within a week.
