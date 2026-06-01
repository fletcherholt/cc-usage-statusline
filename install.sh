#!/usr/bin/env bash
# Installer for cc-usage-statusline.
#
# Copies statusline.sh (+ the compat layer, shared fetch lib, and background
# refresher) into ~/.claude/, merges the statusLine entry into
# ~/.claude/settings.json (preserving everything else), adds a SessionStart
# hook that flips off Claude Code's built-in usage-limit warning bar (which is
# redundant with the one we render), and installs a background refresher that
# keeps the usage cache warm every 60s so it never goes stale while Claude is
# idle or closed. The refresher uses launchd on macOS, a systemd user timer
# (or cron) on Linux, and Task Scheduler on Windows (Git Bash).
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

# Detect OS for the per-platform jq hint and the background refresher below.
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
install -m 0755 "$SRC_DIR/statusline.sh"   "$TARGET"
install -m 0644 "$SRC_DIR/platform.sh"     "$CLAUDE_DIR/platform.sh"
install -m 0644 "$SRC_DIR/usage-fetch.sh"  "$CLAUDE_DIR/usage-fetch.sh"
install -m 0755 "$SRC_DIR/usage-refresh.sh" "$CLAUDE_DIR/usage-refresh.sh"
mkdir -p "$CLAUDE_DIR/commands"
install -m 0644 "$SRC_DIR/commands/usage-refresh.md" "$CLAUDE_DIR/commands/usage-refresh.md"
echo "✓ installed $TARGET (+ platform.sh, usage-fetch.sh, usage-refresh.sh, /usage-refresh)"

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

# Install the background refresher so the cache stays warm even when Claude
# Code isn't rendering the status line (idle or closed). The mechanism is
# per-OS; each branch degrades to "pull-on-render only" with a clear message if
# its scheduler isn't available (the status line still self-refreshes whenever
# it renders — the background job just covers the idle gaps).
LABEL="com.cc-usage-statusline.refresh"
REFRESH="$CLAUDE_DIR/usage-refresh.sh"

install_refresher_macos() {
  local plist="$HOME/Library/LaunchAgents/$LABEL.plist"
  mkdir -p "$HOME/Library/LaunchAgents"
  cat > "$plist" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>            <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$REFRESH</string>
    </array>
    <key>StartInterval</key>    <integer>60</integer>
    <key>RunAtLoad</key>        <true/>
    <key>StandardOutPath</key>  <string>/dev/null</string>
    <key>StandardErrorPath</key><string>/dev/null</string>
</dict>
</plist>
PLISTEOF
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  if launchctl bootstrap "gui/$(id -u)" "$plist" 2>/dev/null; then
    echo "✓ installed + loaded launchd refresher ($LABEL, every 60s)"
  else
    launchctl unload "$plist" 2>/dev/null || true
    launchctl load "$plist" 2>/dev/null \
      && echo "✓ installed + loaded launchd refresher ($LABEL, every 60s)" \
      || echo "! installed plist but couldn't load it — run: launchctl load $plist"
  fi
}

install_refresher_linux() {
  # Prefer a systemd user timer. Needs a working user manager (absent in many
  # containers and in WSL distros without systemd) — fall back to cron, then to
  # pull-on-render only.
  if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
    local ud="$HOME/.config/systemd/user"
    mkdir -p "$ud"
    cat > "$ud/cc-usage-refresh.service" <<UNIT
[Unit]
Description=cc-usage-statusline cache refresher
[Service]
Type=oneshot
ExecStart=/usr/bin/env bash $REFRESH
UNIT
    cat > "$ud/cc-usage-refresh.timer" <<UNIT
[Unit]
Description=Refresh cc-usage cache every minute
[Timer]
OnBootSec=30
OnUnitActiveSec=60
AccuracySec=15
[Install]
WantedBy=timers.target
UNIT
    systemctl --user daemon-reload 2>/dev/null
    if systemctl --user enable --now cc-usage-refresh.timer 2>/dev/null; then
      echo "✓ installed + started systemd user timer (cc-usage-refresh.timer, every 60s)"
      return
    fi
  fi
  if command -v crontab >/dev/null 2>&1; then
    local line="* * * * * /usr/bin/env bash $REFRESH >/dev/null 2>&1"
    if ( crontab -l 2>/dev/null | grep -vF "usage-refresh.sh"; echo "$line" ) | crontab - 2>/dev/null; then
      echo "✓ installed cron refresher (every 60s)"
      return
    fi
  fi
  echo "! no systemd-user or cron available — using pull-on-render only"
  echo "  (the status line still refreshes whenever it renders; run"
  echo "   '$REFRESH' yourself or via /usage-refresh to force one)"
}

install_refresher_windows() {
  # Task Scheduler via schtasks. In Git Bash, the leading-slash flags must be
  # doubled (//Create) so MSYS doesn't mangle them into paths.
  local bash_exe; bash_exe="$(command -v bash)"
  if command -v schtasks >/dev/null 2>&1; then
    if schtasks //Create //F //SC MINUTE //MO 1 //TN "$LABEL" \
         //TR "\"$bash_exe\" -lc \"bash '$REFRESH'\"" >/dev/null 2>&1; then
      echo "✓ installed Task Scheduler refresher ($LABEL, every 60s)"
      return
    fi
  fi
  echo "! couldn't register a scheduled task — using pull-on-render only"
  echo "  (the status line still refreshes whenever it renders; run"
  echo "   '$REFRESH' yourself or via /usage-refresh to force one)"
}

case "$OS" in
  macos)   install_refresher_macos ;;
  linux)   install_refresher_linux ;;
  windows) install_refresher_windows ;;
esac

cat <<EOF

Done. Restart Claude Code (close this terminal and open a new one, or run
\`claude\` fresh) and you should see the new status line above your prompt.

To remove later:
  bash $SRC_DIR/uninstall.sh
EOF
