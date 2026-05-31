#!/usr/bin/env bash
# Installer for cc-usage-statusline.
#
# Copies statusline.sh (+ the shared fetch lib and background refresher) into
# ~/.claude/, merges the statusLine entry into ~/.claude/settings.json
# (preserving everything else), adds a SessionStart hook that flips off Claude
# Code's built-in usage-limit warning bar (which is redundant with the one we
# render), and installs a launchd agent that refreshes the usage cache every
# 60s so it never goes stale while Claude is idle or closed.
#
# Usage:  bash install.sh            (interactive)
#         bash install.sh --quiet    (no prompts)

set -euo pipefail

quiet=0
[ "${1:-}" = "--quiet" ] && quiet=1

CLAUDE_DIR="$HOME/.claude"
TARGET="$CLAUDE_DIR/statusline.sh"
SETTINGS="$CLAUDE_DIR/settings.json"
SRC_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"

command -v jq >/dev/null || { echo "error: jq is required (brew install jq)"; exit 1; }

mkdir -p "$CLAUDE_DIR"
install -m 0755 "$SRC_DIR/statusline.sh"   "$TARGET"
install -m 0644 "$SRC_DIR/usage-fetch.sh"  "$CLAUDE_DIR/usage-fetch.sh"
install -m 0755 "$SRC_DIR/usage-refresh.sh" "$CLAUDE_DIR/usage-refresh.sh"
mkdir -p "$CLAUDE_DIR/commands"
install -m 0644 "$SRC_DIR/commands/usage-refresh.md" "$CLAUDE_DIR/commands/usage-refresh.md"
echo "✓ installed $TARGET (+ usage-fetch.sh, usage-refresh.sh, /usage-refresh)"

# Create a minimal settings.json if there isn't one yet.
if [ ! -s "$SETTINGS" ]; then
  echo "{}" > "$SETTINGS"
fi

# Merge our statusLine entry — preserves any existing settings. We strip any
# previous copies of our SessionStart hook and add exactly one, so re-running
# the installer is fully idempotent (and cleans up duplicates left by older
# versions of this installer).
tmp=$(mktemp)
jq --arg cmd "$TARGET" '
  .statusLine = {type:"command", command:$cmd, refreshInterval:2}
  | .hooks.SessionStart = (
      ((.hooks.SessionStart // [])
        | map(select((.hooks // []) | any(.command // "" | contains("tengu_c4w_usage_limit_notifications_enabled")) | not)))
      + [{hooks:[{type:"command",
                  command:"jq '"'"'.cachedGrowthBookFeatures.tengu_c4w_usage_limit_notifications_enabled = false'"'"' \"$HOME/.claude.json\" > \"$HOME/.claude.json.tmp\" && mv \"$HOME/.claude.json.tmp\" \"$HOME/.claude.json\" 2>/dev/null; exit 0"}]}]
    )
' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
echo "✓ merged statusLine + SessionStart hook into $SETTINGS"

# Pre-flip the growthbook flag so the next session won't show the warning bar.
if [ -s "$HOME/.claude.json" ]; then
  tmp=$(mktemp)
  jq '.cachedGrowthBookFeatures.tengu_c4w_usage_limit_notifications_enabled = false' \
     "$HOME/.claude.json" > "$tmp" && mv "$tmp" "$HOME/.claude.json"
  echo "✓ pre-flipped Claude Code's built-in usage-warning flag"
fi

# Install the launchd background refresher so the cache stays warm even when
# Claude Code isn't rendering the status line (idle or closed).
LABEL="com.cc-usage-statusline.refresh"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>            <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$CLAUDE_DIR/usage-refresh.sh</string>
    </array>
    <key>StartInterval</key>    <integer>60</integer>
    <key>RunAtLoad</key>        <true/>
    <key>StandardOutPath</key>  <string>/dev/null</string>
    <key>StandardErrorPath</key><string>/dev/null</string>
</dict>
</plist>
PLISTEOF
# Reload: bootout the old instance (ignore if absent), then bootstrap fresh.
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
if launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null; then
  echo "✓ installed + loaded launchd refresher ($LABEL, every 60s)"
else
  # Older macOS without bootstrap subcommand — fall back to legacy load.
  launchctl unload "$PLIST" 2>/dev/null || true
  launchctl load "$PLIST" 2>/dev/null \
    && echo "✓ installed + loaded launchd refresher ($LABEL, every 60s)" \
    || echo "! installed plist but couldn't load it — run: launchctl load $PLIST"
fi

cat <<EOF

Done. Restart Claude Code (close this terminal and open a new one, or run
\`claude\` fresh) and you should see the new status line above your prompt.

To remove later:
  bash $SRC_DIR/uninstall.sh
EOF
