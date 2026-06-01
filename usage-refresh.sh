#!/bin/bash
# Background usage-cache refresher for cc-usage-statusline.
#
# Run by the platform's scheduler (launchd / systemd timer / Task Scheduler)
# every ~60s so the cache stays warm even when Claude Code isn't rendering the
# status line (idle, or closed entirely). Without
# this, the cache only ever refreshes on a render tick and goes stale the
# moment you stop typing. Shares the attempt/backoff gates with the renderer
# (see usage-fetch.sh), so it never adds API pressure beyond 1 call/min.

set -u
LIB="$(cd "$(dirname "$0")" && pwd)/usage-fetch.sh"
[ -r "$LIB" ] || { echo "usage-refresh: $LIB missing — re-run install.sh" >&2; exit 1; }
source "$LIB"

# `--force` ignores all rate-limit gates and fetches immediately (used by the
# /usage-refresh slash command). No arg = normal gated background refresh.
if [ "${1:-}" = "--force" ] || [ "${1:-}" = "force" ]; then
  usage_refresh_cache force
else
  usage_refresh_cache
fi

# Print the current numbers so a manual run shows its result.
if [ -s "$HOME/.claude/.usage-cache.json" ]; then
  age=$(( $(cc_now) - $(cc_mtime "$HOME/.claude/.usage-cache.json") ))
  printf 'usage cache: %ds old · session %s%% · week %s%%\n' "$age" \
    "$(jq -r '.five_hour.utilization // "?"' "$HOME/.claude/.usage-cache.json")" \
    "$(jq -r '.seven_day.utilization // "?"' "$HOME/.claude/.usage-cache.json")"
fi
exit 0
