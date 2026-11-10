#!/bin/bash
# A positive debug control prevents a missing tool or stripped input from passing vacuously.
set -euo pipefail
pattern='StudioKit.AppDelegate.(startSceneDebug|runEventDemo|dumpTransitions|runSceneDemo|scheduleStreamUIChecks)'
if [[ "${1:-}" == --check ]]; then
    symbols=$(mktemp /tmp/ehdr-symbols.XXXXXX)
    trap 'rm -f "$symbols"' EXIT
    /usr/bin/nm "$2" | swift demangle > "$symbols"
    if /usr/bin/grep -E "$pattern" "$symbols"; then
        echo 'FAIL: debug-only function symbols present'; exit 1
    fi
    echo 'PASS: no debug-only function symbols'; exit 0
fi
if [[ $# == 0 ]]; then ./build.sh; fi
binary="${1:-dist/Elgato HDR.app/Contents/MacOS/ElgatoHDR}"
"$0" --check "$binary"
./build.sh debug
if "$0" --check 'dist/Elgato HDR.app/Contents/MacOS/ElgatoHDR'; then
    echo 'FAIL: debug negative control unexpectedly passed'; exit 1
fi
echo 'PASS: release clean and debug negative control rejected'
