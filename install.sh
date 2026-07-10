#!/usr/bin/env bash
# Installer for cc-usage-statusline.
#
# Copies statusline.sh (+ the platform.sh date compat layer) into ~/.claude/,
# merges the statusLine entry into ~/.claude/settings.json (preserving
# everything else), and adds a SessionStart hook that switches off Claude Code's
# built-in usage-limit warning bar (redundant with the bars we render).
#
# It also tidies up after older versions of this tool, which shipped an OAuth
# fetch pipeline and a background refresher (launchd / systemd / cron / Task
# Scheduler). Those are gone — the status line now reads everything from the
# JSON Claude Code passes on stdin — so re-running the installer removes any
# leftover refresher and cache files.
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

case "$(uname -s 2>/dev/null)" in
  Darwin)               OS=macos ;;
  Linux)                OS=linux ;;
  MINGW*|MSYS*|CYGWIN*) OS=windows ;;
  *)                    OS=linux ;;
esac

if ! command -v jq >/dev/null; then
  case "$OS" in
    macos)   hint="brew install jq" ;;
    linux)   hint="sudo apt install jq  (or: dnf/pacman/zypper install jq)" ;;
    windows) hint="winget install jqlang.jq  (or: choco install jq)" ;;
  esac
  echo "error: jq is required ($hint)"; exit 1
fi

mkdir -p "$CLAUDE_DIR"
install -m 0755 "$SRC_DIR/statusline.sh" "$TARGET"
install -m 0644 "$SRC_DIR/platform.sh"   "$CLAUDE_DIR/platform.sh"
echo "✓ installed $TARGET (+ platform.sh)"

# Remove leftovers from older (OAuth-fetch) versions so upgraders don't keep a
# zombie background job hitting a pipeline we no longer ship.
remove_old_refresher() {
  local label="com.cc-usage-statusline.refresh"
  case "$OS" in
    macos)
      local plist="$HOME/Library/LaunchAgents/$label.plist"
      if [ -e "$plist" ]; then
        launchctl bootout "gui/$(id -u)/$label" 2>/dev/null \
          || launchctl unload "$plist" 2>/dev/null || true
        rm -f "$plist"
        echo "✓ removed old launchd refresher"
      fi ;;
    linux)
      if command -v systemctl >/dev/null 2>&1 \
         && [ -e "$HOME/.config/systemd/user/cc-usage-refresh.timer" ]; then
        systemctl --user disable --now cc-usage-refresh.timer 2>/dev/null || true
        rm -f "$HOME/.config/systemd/user/cc-usage-refresh.timer" \
              "$HOME/.config/systemd/user/cc-usage-refresh.service"
        systemctl --user daemon-reload 2>/dev/null || true
        echo "✓ removed old systemd refresher"
      fi
      if command -v crontab >/dev/null 2>&1 && crontab -l 2>/dev/null | grep -qF "usage-refresh.sh"; then
        crontab -l 2>/dev/null | grep -vF "usage-refresh.sh" | crontab - 2>/dev/null || true
        echo "✓ removed old cron refresher"
      fi ;;
    windows)
      command -v schtasks >/dev/null 2>&1 && schtasks //Delete //F //TN "$label" >/dev/null 2>&1 || true ;;
  esac
  rm -f "$CLAUDE_DIR/usage-fetch.sh" "$CLAUDE_DIR/usage-refresh.sh" \
        "$CLAUDE_DIR/commands/usage-refresh.md" \
        "$CLAUDE_DIR/.usage-cache.json" "$CLAUDE_DIR/.usage-cache.lock" \
        "$CLAUDE_DIR/.usage-cache.attempt" "$CLAUDE_DIR/.usage-cache.backoff" 2>/dev/null || true
}
remove_old_refresher

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

cat <<EOF

Done. Restart Claude Code (close this terminal and open a new one, or run
\`claude\` fresh) and you should see the status line above your prompt.

To remove later:
  bash $SRC_DIR/uninstall.sh
EOF
