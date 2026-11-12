#!/bin/bash
# Builds build/ScrollArrows.app.
# SIGN_ID=<identity> signs with your own certificate, so Accessibility access
# survives rebuilds. Without it the app is signed ad hoc.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/ScrollArrows.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -O main.swift -o "$APP/Contents/MacOS/ScrollArrows"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.scrollarrows.app</string>
    <key>CFBundleName</key>
    <string>ScrollArrows</string>
    <key>CFBundleExecutable</key>
    <string>ScrollArrows</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>2.0</string>
    <key>CFBundleVersion</key>
    <string>2</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST

codesign --force -s "${SIGN_ID:--}" "$APP"
echo "Built $APP"
