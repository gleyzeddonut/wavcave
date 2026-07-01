#!/bin/bash
# Builds "WavCave.app" — the native standalone macOS app.
# Run from anywhere; paths are resolved relative to this script.
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"          # project root (holds index.html, …)
OUT="$ROOT/WavCave.app"

echo "Compiling…"
xcrun swiftc -O "$HERE/main.swift" "$HERE/Server.swift" -o "$HERE/WavCave" -framework Cocoa -framework WebKit

echo "Assembling bundle…"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
mv "$HERE/WavCave" "$OUT/Contents/MacOS/WavCave"
chmod +x "$OUT/Contents/MacOS/WavCave"

# Icon: prefer an existing .icns, else fall back to the 512 PNG via iconutil.
if [ -f "$HERE/appicon.icns" ]; then
  cp "$HERE/appicon.icns" "$OUT/Contents/Resources/appicon.icns"
fi

# Web UI (the backend is compiled into the binary — see Server.swift)
cp "$ROOT/index.html" "$OUT/Contents/Resources/"

cp "$HERE/Info.plist" "$OUT/Contents/Info.plist"

# Sign with a Developer ID if you have one (removes the "unverified developer"
# prompt and is required for notarization); otherwise fall back to ad-hoc.
# Override the identity explicitly with:  BF_SIGN_ID="Developer ID Application: Your Name (TEAMID)" ./build.sh
SIGN_ID="${BF_SIGN_ID:-}"
if [ -z "$SIGN_ID" ]; then
  SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null | grep -o 'Developer ID Application: [^"]*' | head -1)"
fi
if [ -n "$SIGN_ID" ]; then
  echo "Signing with: $SIGN_ID"
  codesign --force --deep --options runtime --timestamp --sign "$SIGN_ID" "$OUT" || \
    { echo "Developer ID signing failed; falling back to ad-hoc."; codesign --force --deep --sign - "$OUT"; }
  echo "To remove the Gatekeeper prompt for distribution, notarize it:"
  echo "  ditto -c -k --keepParent \"$OUT\" /tmp/WavCave.zip"
  echo "  xcrun notarytool submit /tmp/WavCave.zip --apple-id <you@apple.id> --team-id <TEAMID> --password <app-specific-pw> --wait"
  echo "  xcrun stapler staple \"$OUT\""
else
  echo "Signing (ad-hoc — no Developer ID found; first launch needs right-click → Open once)…"
  codesign --force --deep --sign - "$OUT"
fi

echo "Done: $OUT"
