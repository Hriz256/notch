# Notch

Personal Dynamic-Island-style surface for the MacBook notch. macOS 26+, Apple Silicon.

## Build
    brew install xcodegen
    xcodegen generate
    xcodebuild -project Notch.xcodeproj -scheme Notch -configuration Debug -derivedDataPath build build
    open build/Build/Products/Debug/Notch.app

## Test
    cd NotchKit && swift test

Regenerate `Notch.xcodeproj` after editing `project.yml`.
