#!/bin/sh
# Builds Claude Profiles from source and installs it for the current user.
# Needs the Xcode Command Line Tools (swiftc). Nothing outside $HOME is touched.
set -eu

APP_NAME="Claude Profiles"
BUNDLE_ID="com.claudeprofiles.helper"
VERSION="0.1.0"
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD="$SRC_DIR/build"
APP="$BUILD/$APP_NAME.app"
DEST_DIR="$HOME/Applications"
DEST="$DEST_DIR/$APP_NAME.app"
CONF_DIR="$HOME/Library/Application Support/Claude Profiles"
AGENT="$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"
CLAUDE_APP="${CLAUDE_APP:-/Applications/Claude.app}"

echo "==> Building"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun swiftc -O -target "$(uname -m)-apple-macos13" \
  -o "$APP/Contents/MacOS/ClaudeProfiles" "$SRC_DIR/Sources/main.swift"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>ClaudeProfiles</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key>
  <string>Claude Profiles passes claude:// links to the Claude window you choose.</string>
  <key>CFBundleURLTypes</key><array><dict>
    <key>CFBundleURLName</key><string>Claude link</string>
    <key>CFBundleURLSchemes</key><array><string>claude</string></array>
  </dict></array>
</dict></plist>
EOF
if [ -f "$CLAUDE_APP/Contents/Resources/electron.icns" ]; then
  cp "$CLAUDE_APP/Contents/Resources/electron.icns" "$APP/Contents/Resources/AppIcon.icns"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist"
fi
codesign --force --sign - "$APP"

echo "==> Installing to $DEST"
launchctl bootout "gui/$(id -u)/$BUNDLE_ID" 2>/dev/null || true
pkill -f "$APP_NAME.app/Contents/MacOS/ClaudeProfiles" 2>/dev/null || true
mkdir -p "$DEST_DIR" "$CONF_DIR"
rm -rf "$DEST"
cp -R "$APP" "$DEST"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"

if [ ! -f "$CONF_DIR/profiles.json" ]; then
  echo "==> Writing starter config $CONF_DIR/profiles.json"
  cat > "$CONF_DIR/profiles.json" <<EOF
{
  "appPath": "$CLAUDE_APP",
  "alwaysAsk": false,
  "profiles": [
    { "id": "default", "name": "Personal" },
    { "id": "work", "name": "Work", "userDataDir": "~/Library/Application Support/Claude-Work" }
  ]
}
EOF
else
  echo "==> Keeping existing $CONF_DIR/profiles.json"
fi

echo "==> Starting at login (LaunchAgent)"
mkdir -p "$(dirname "$AGENT")"
cat > "$AGENT" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$BUNDLE_ID</string>
  <key>ProgramArguments</key><array><string>$DEST/Contents/MacOS/ClaudeProfiles</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key><string>Interactive</string>
</dict></plist>
EOF
launchctl bootstrap "gui/$(id -u)" "$AGENT"

sleep 2
echo "==> Status"
"$DEST/Contents/MacOS/ClaudeProfiles" --status || true
echo "Done. Edit profiles from the menu bar icon, or: open \"$CONF_DIR/profiles.json\""
