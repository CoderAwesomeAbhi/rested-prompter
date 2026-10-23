#!/bin/bash
# Builds "Rested Prompter.app" (Apple Silicon and Intel) from RestedPrompter.swift.
# Needs Xcode or its Command Line Tools: xcode-select --install
set -euo pipefail
cd "$(dirname "$0")"
APP="Rested Prompter.app"
rm -rf build "$APP"
mkdir -p build "$APP/Contents/MacOS"
for arch in arm64 x86_64; do
  swiftc -O -target "$arch-apple-macos11.0" -o "build/RestedPrompter-$arch" RestedPrompter.swift
done
lipo -create -output "$APP/Contents/MacOS/RestedPrompter" build/RestedPrompter-arm64 build/RestedPrompter-x86_64
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "Built $APP"
