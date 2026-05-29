#!/usr/bin/env bash
# Installer for cc-usage-statusline.
#
# Copies statusline.sh into ~/.claude/, merges the statusLine entry into
# ~/.claude/settings.json (preserving everything else), and adds a
# SessionStart hook that flips off Claude Code's built-in usage-limit
# warning bar (which is redundant with the one we render).
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
install -m 0755 "$SRC_DIR/statusline.sh" "$TARGET"
echo "✓ installed $TARGET"

# Create a minimal settings.json if there isn't one yet.
if [ ! -s "$SETTINGS" ]; then
  echo "{}" > "$SETTINGS"
fi

# Merge our statusLine entry — preserves any existing settings.
tmp=$(mktemp)
jq --arg cmd "$TARGET" '
  .statusLine = {type:"command", command:$cmd, refreshInterval:2}
  | .hooks.SessionStart = (
      (.hooks.SessionStart // [])
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
\`claude\` fresh) and you should see the new status line above your prompt.

To remove later:
  bash $SRC_DIR/uninstall.sh
EOF
