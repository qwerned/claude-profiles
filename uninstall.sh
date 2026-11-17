#!/bin/sh
# Removes Claude Profiles and gives claude:// back to Claude Desktop.
# Profile data (Claude's own user-data folders) and profiles.json are left alone.
set -u
BUNDLE_ID="com.claudeprofiles.helper"
DEST="$HOME/Applications/Claude Profiles.app"

echo "==> Stopping helper"
launchctl bootout "gui/$(id -u)/$BUNDLE_ID" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"

echo "==> Restoring claude:// handler"
[ -x "$DEST/Contents/MacOS/ClaudeProfiles" ] && "$DEST/Contents/MacOS/ClaudeProfiles" --restore-handler

echo "==> Removing app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$DEST" 2>/dev/null || true
rm -rf "$DEST"
echo "Done. Config kept in ~/Library/Application Support/Claude Profiles"
