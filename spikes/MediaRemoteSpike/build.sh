#!/bin/sh
# Builds the MediaRemote probe. MediaRemote answers only callers whose bundle id starts with
# `com.apple.controlcenter.` (macOS 15.4+), so the Info.plist is embedded and the ad-hoc
# signature carries the same identifier. No debugger or extra permission is involved.
set -e
cd "$(dirname "$0")"
swiftc -O main.swift -o spike -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Info.plist
codesign -s - -i com.apple.controlcenter.NotchSpike -f spike
echo "built ./spike — run: ./spike [watch <seconds>] [pause-chrome] [seek-chrome]"
