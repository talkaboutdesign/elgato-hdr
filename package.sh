#!/bin/zsh
# Builds Elgato HDR.app and produces a distributable zip in dist/releases/.
set -e
cd "$(dirname "$0")"
VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' app/Info.plist 2>/dev/null || echo 0.1)}"
./build.sh
mkdir -p dist/releases
OUT="dist/releases/ElgatoHDR-${VERSION}.zip"
rm -f "$OUT"
# ditto preserves the bundle structure, symlinks, and code signature.
ditto -c -k --sequesterRsrc --keepParent "dist/Elgato HDR.app" "$OUT"
echo "packaged $OUT ($(du -h "$OUT" | cut -f1))"
