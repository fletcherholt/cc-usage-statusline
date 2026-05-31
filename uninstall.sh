#!/usr/bin/env bash
# Uninstaller for cc-usage-statusline. Removes the script + our statusLine
# entry + our SessionStart hook from settings.json. Leaves the rest of
# your settings alone.

set -euo pipefail

CLAUDE_DIR="$HOME/.claude"
TARGET="$CLAUDE_DIR/statusline.sh"
SETTINGS="$CLAUDE_DIR/settings.json"

# Stop + remove the launchd background refresher first.
LABEL="com.cc-usage-statusline.refresh"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || launchctl unload "$PLIST" 2>/dev/null || true
rm -f "$PLIST"
echo "✓ removed launchd refresher ($LABEL)"

rm -f "$TARGET" "$CLAUDE_DIR/usage-fetch.sh" "$CLAUDE_DIR/usage-refresh.sh" \
      "$CLAUDE_DIR/commands/usage-refresh.md" \
      "$CLAUDE_DIR/.usage-cache.json" "$CLAUDE_DIR/.usage-cache.lock" \
      "$CLAUDE_DIR/.usage-cache.attempt" "$CLAUDE_DIR/.usage-cache.backoff"
echo "✓ removed $TARGET, libs, command, and cache files"

if [ -s "$SETTINGS" ]; then
  tmp=$(mktemp)
  jq --arg cmd "$TARGET" '
    (.statusLine = (if .statusLine.command == $cmd then null else .statusLine end))
    | (.hooks.SessionStart = (
        (.hooks.SessionStart // [])
        | map(select((.hooks // []) | any(.command // "" | contains("tengu_c4w_usage_limit_notifications_enabled")) | not))
      ))
    | (if (.hooks.SessionStart // []) == [] then del(.hooks.SessionStart) else . end)
    | (if (.hooks // {}) == {} then del(.hooks) else . end)
    | (if .statusLine == null then del(.statusLine) else . end)
  ' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
  echo "✓ cleaned $SETTINGS"
fi

echo "done. Restart Claude Code to drop the status line."
