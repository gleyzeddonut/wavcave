# WavCave

A native macOS app that surfaces every bounced `.wav` / `.mp3` sitting inside a
`bounces` folder (or any folder keywords you configure) across your project
folders — group versions, audition with a waveform, sort by artist, and more.
Everything stays on your machine: the backend is compiled into the app itself
(no Python, no dependencies) and a WKWebView shows the UI.

## Layout
- `index.html` — the UI (single self-contained file).
- `native/` — the standalone macOS app.
  - `main.swift` — the WKWebView app shell (window, folder drops, in-app updater).
  - `Server.swift` — the local backend (scan, stream, peaks, durable settings),
    served on `127.0.0.1:8765` with a per-launch auth token.
  - `server-cli.swift` — runs the same backend headless for development and tests.
  - `build.sh` — compiles + assembles + signs `WavCave.app`.
  - `release.sh` — bumps the version, builds, and publishes a GitHub release.
  - `Info.plist`, `appicon.icns`.
- `tests/` — pytest suite that boots the real backend and exercises every endpoint.

## Build
```sh
./native/build.sh
# then copy "WavCave.app" to /Applications
```
If a `Developer ID Application` certificate is in your keychain, `build.sh` signs
with it automatically (otherwise it falls back to ad-hoc).

## Develop in a browser
```sh
cd native && xcrun swiftc -parse-as-library Server.swift server-cli.swift -o wavcave-server
BF_ROOT="$(pwd)/.." ./wavcave-server   # then open http://127.0.0.1:8765
```
(Without `BF_TOKEN` the dev server skips token auth; the app always generates one.)

## Test
```sh
python3 -m venv .venv && .venv/bin/pip install pytest   # once
.venv/bin/python -m pytest tests/ -v
```

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
