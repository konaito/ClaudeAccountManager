#!/bin/bash
# CamBar をビルドして ~/Applications/CamBar.app に置き、ログイン時に起動する LaunchAgent を入れて起動し直す。
set -euo pipefail

cd "$(dirname "$0")"
APP="$HOME/Applications/CamBar.app"
LABEL="jp.fybe.cam.menubar"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/CamBar "$APP/Contents/MacOS/CamBar"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"

cat >"$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$APP/Contents/MacOS/CamBar</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>LimitLoadToSessionType</key>
  <string>Aqua</string>
  <key>StandardErrorPath</key>
  <string>$HOME/Library/Logs/cam-menubar.err.log</string>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "入れた: $APP（ログイン時に起動）"
