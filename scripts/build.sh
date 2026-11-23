#!/bin/bash
# Builds AgentOffice.app into the given directory (default: ./build).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/build}"
APP="$OUT/AgentOffice.app"
mkdir -p "$APP/Contents/MacOS"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>AgentOffice</string>
<key>CFBundleIdentifier</key><string>local.agent-office</string>
<key>CFBundleName</key><string>Agent Office</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
PLIST
swiftc -O -swift-version 5 "$ROOT/src/AgentOffice.swift" -o "$APP/Contents/MacOS/AgentOffice"
echo "Built $APP"
