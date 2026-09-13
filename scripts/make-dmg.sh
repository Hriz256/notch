#!/bin/sh
# Builds a Release Notch.app (signed with the "Notch Dev" identity, universal) and packs it into ~/Desktop/Notch.dmg
# with an Applications shortcut and the install note. Run from the repo root.
set -eu
xcodegen generate >/dev/null
xcodebuild -project Notch.xcodeproj -scheme Notch -configuration Release -derivedDataPath build/release build 2>&1 | grep -E "error|BUILD" | tail -1
STG="$(mktemp -d)/Notch"; mkdir -p "$STG"
cp -R build/release/Build/Products/Release/Notch.app "$STG/"
ln -s /Applications "$STG/Applications"
cp "scripts/dmg-readme.txt" "$STG/Как установить.txt"
rm -f ~/Desktop/Notch.dmg
hdiutil create -volname "Notch" -srcfolder "$STG" -ov -format UDZO ~/Desktop/Notch.dmg | tail -1
