#!/bin/bash
# Build Claude Usage Tracker

set -e

echo "Building ClaudeUsage..."

# Extract version from Swift source (single source of truth)
VERSION=$(grep -E '^\s*(private\s+)?let\s+appVersion\s*=' ClaudeUsage.swift | sed 's/.*"\(.*\)".*/\1/')
if [ -z "$VERSION" ]; then
    echo "Error: could not extract appVersion from ClaudeUsage.swift" >&2
    exit 1
fi
echo "Version: $VERSION"

# Create app bundle structure
mkdir -p ClaudeUsage.app/Contents/MacOS

# Compile
swiftc -O -o ClaudeUsage.app/Contents/MacOS/ClaudeUsage ClaudeUsage.swift -framework Cocoa -framework UserNotifications

# Always regenerate Info.plist so version bumps take effect
cat > ClaudeUsage.app/Contents/Info.plist << EOF
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
    <string>$VERSION</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
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

# Ad-hoc code signing
codesign --sign - --force ClaudeUsage.app

echo "Done! Run with: open ClaudeUsage.app"
