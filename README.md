# WavCave

A native macOS app that surfaces every bounced `.wav` / `.mp3` sitting inside a
`bounces` folder across your project folders — group versions, audition with a
waveform, A/B compare mixes, sort by artist, and more. Everything stays on your
machine (a tiny local Python server does the scanning; a WKWebView shows the UI).

## Layout
- `index.html` — the UI (single self-contained file).
- `server.py` — the local backend (scan, stream, peaks, durable settings).
- `native/` — the standalone macOS app wrapper.
  - `main.swift` — the WKWebView app (starts the backend, in-app updater).
  - `build.sh` — compiles + assembles + signs `WavCave.app`.
  - `release.sh` — bumps the version, builds, and publishes a GitHub release.
  - `Info.plist`, `appicon.icns`.

## Build
```sh
./native/build.sh
# then copy "WavCave.app" to /Applications
```
If a `Developer ID Application` certificate is in your keychain, `build.sh` signs
with it automatically (otherwise it falls back to ad-hoc).

## Cut a release (and ship an update)
```sh
./native/release.sh 1.1 "What changed in this version."
```
This bumps the version, builds + signs, zips the app, tags `v1.1`, pushes, and
creates the GitHub release with the zip attached. Running copies of the app check
this repo's latest release on launch and offer an in-app **Update**.

Updates download straight from the public GitHub release over HTTPS (no `gh`, no
sign-in needed on the user's machine). `release.sh` also notarizes and staples the
build (via the `bouncefinder-notary` keychain profile) so it opens with a plain
double-click on any Mac.
