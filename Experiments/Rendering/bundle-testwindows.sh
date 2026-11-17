#!/bin/sh
# Wraps the TestWindows binary in a minimal .app so it can be launched through
# LaunchServices (`open`), which grants it real activation. A process started
# from a shell while another app is frontmost cannot activate itself
# (cooperative activation, macOS 14+).
set -eu
CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/.build/TestWindows.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$ROOT/.build/$CONFIG/TestWindows" "$APP/Contents/MacOS/TestWindows"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.sonorus.spike.testwindows</string>
<key>CFBundleName</key><string>TestWindows</string>
<key>CFBundleExecutable</key><string>TestWindows</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "$APP"
