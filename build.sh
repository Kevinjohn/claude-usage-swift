#!/bin/bash
# Build Claude Usage Tracker

set -e

echo "Building ClaudeUsage..."

# Create app bundle structure
mkdir -p ClaudeUsage.app/Contents/MacOS

# Compile
swiftc -O -o ClaudeUsage.app/Contents/MacOS/ClaudeUsage ClaudeUsage.swift -framework Cocoa -framework UserNotifications

# Create Info.plist if not exists
if [ ! -f ClaudeUsage.app/Contents/Info.plist ]; then
cat > ClaudeUsage.app/Contents/Info.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>ClaudeUsage</string>
    <key>CFBundleIdentifier</key>
    <string>com.claude.usage-tracker</string>
    <key>CFBundleName</key>
    <string>Claude Usage</string>
    <key>CFBundleVersion</key>
    <string>2.2.1</string>
    <key>CFBundleShortVersionString</key>
    <string>2.2.1</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF
fi

# Ad-hoc code signing
codesign --sign - --force ClaudeUsage.app

echo "Done! Run with: open ClaudeUsage.app"
