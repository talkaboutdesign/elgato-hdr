#!/bin/bash
# Run after ./build.sh. Guard against accidentally shipping automation or storage overrides.
set -euo pipefail
binary="${1:-dist/Elgato HDR.app/Contents/MacOS/ElgatoHDR}"
text=$(mktemp /tmp/ehdr-release-flags.XXXXXX)
trap 'rm -f "$text"' EXIT
strings "$binary" > "$text"
if rg -- 'EHDR_|--scene-script|--scene-torture|--go-live-for|--stream-restart-after|--make-fixture|--design-gallery|--first-launch-sheet|^--record$|^--export$' "$text"; then
    echo 'FAIL: release contains debug controls'; exit 1
fi
echo 'PASS: release contains no debug automation or EHDR overrides'
