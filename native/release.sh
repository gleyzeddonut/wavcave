#!/bin/bash
# Cut a release: bump version, build + sign, zip, tag, push, publish to GitHub.
# Usage: native/release.sh <version> ["release notes"]
set -e

VER="$1"; NOTES="${2:-Bug fixes and improvements.}"
if [ -z "$VER" ]; then echo "usage: release.sh <version> [\"notes\"]"; exit 1; fi

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
REPO="gleyzeddonut/wavcave"

echo "Bumping version to $VER…"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VER" "$HERE/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VER" "$HERE/Info.plist"

# Build + sign (build.sh auto-detects the Developer ID cert)
"$HERE/build.sh"

# Notarize + staple so the app opens with a plain double-click on any Mac.
# Requires a one-time: xcrun notarytool store-credentials "bouncefinder-notary" --apple-id <id> --team-id K7VM2MP885
NOTARY_PROFILE="${BF_NOTARY_PROFILE:-bouncefinder-notary}"
if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  NOTZIP="/tmp/WavCave-$VER-notarize.zip"; rm -f "$NOTZIP"
  ditto -c -k --keepParent "$ROOT/WavCave.app" "$NOTZIP"
  echo "Submitting to Apple notary service (profile: $NOTARY_PROFILE)…"
  xcrun notarytool submit "$NOTZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$ROOT/WavCave.app"
  xcrun stapler validate "$ROOT/WavCave.app"
  rm -f "$NOTZIP"
  echo "Notarized + stapled ✓"
else
  echo "WARNING: notary profile '$NOTARY_PROFILE' not found — shipping un-notarized (users get the right-click-Open prompt)."
fi

ZIP="/tmp/WavCave-$VER.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$ROOT/WavCave.app" "$ZIP"
echo "Zipped: $ZIP"

# Commit the version bump, tag, push
cd "$ROOT"
git add -A
git commit -m "Release v$VER" || true
git tag -f "v$VER"
git push origin HEAD
git push -f origin "v$VER"

# Create (or update) the GitHub release with the zip asset
if gh release view "v$VER" --repo "$REPO" >/dev/null 2>&1; then
  gh release upload "v$VER" "$ZIP" --repo "$REPO" --clobber
  gh release edit "v$VER" --repo "$REPO" --notes "$NOTES"
else
  gh release create "v$VER" "$ZIP" --repo "$REPO" --title "v$VER" --notes "$NOTES"
fi

echo "Released v$VER ✓  — running apps will offer the update on next launch."
