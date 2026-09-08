#!/bin/zsh
# Builds Elgato HDR.app (viewer + bundled root helper + libusb) into ./dist
set -e
cd "$(dirname "$0")"
APP="dist/Elgato HDR.app"; rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
clang -O2 -Wall -I/opt/homebrew/include/libusb-1.0 -L/opt/homebrew/lib -lusb-1.0 -o "$APP/Contents/MacOS/uvc_capture" tools/uvc_capture.c
cp /opt/homebrew/opt/libusb/lib/libusb-1.0.0.dylib "$APP/Contents/Frameworks/"
install_name_tool -change /opt/homebrew/opt/libusb/lib/libusb-1.0.0.dylib @executable_path/../Frameworks/libusb-1.0.0.dylib "$APP/Contents/MacOS/uvc_capture"
swiftc -O -o "$APP/Contents/MacOS/ElgatoHDR" app/main.swift
cp app/Info.plist "$APP/Contents/"
codesign --force --deep --sign - "$APP"
du -sh "$APP"; echo "built $APP"
