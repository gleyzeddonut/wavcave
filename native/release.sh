#!/bin/bash
# Cut a release: bump version, build + sign, zip, tag, push, publish to GitHub.
# Usage: native/release.sh <version> ["release notes"]
set -e

VER="$1"; NOTES="${2:-Bug fixes and improvements.}"
if [ -z "$VER" ]; then echo "usage: release.sh <version> [\"notes\"]"; exit 1; fi

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
REPO="gleyzeddonut/bounce-finder"

echo "Bumping version to $VER…"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VER" "$HERE/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VER" "$HERE/Info.plist"

# Build + sign (build.sh auto-detects the Developer ID cert)
"$HERE/build.sh"

ZIP="/tmp/BounceFinder-$VER.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$ROOT/Bounce Finder.app" "$ZIP"
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
