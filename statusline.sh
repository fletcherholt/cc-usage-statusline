#!/bin/bash
# Claude Code status line — renders the /usage view continuously.
#
# Pulls https://api.anthropic.com/api/oauth/usage using the OAuth token
# from Keychain (the same token Claude Code itself uses for /usage),
# caches the response for 60 s to keep the refresh cheap, then prints the
# Current-session + Current-week bars exactly like /usage.
#
# Output:
#   Current session
#   ▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌░░░░░░░░  73% used
#   Resets 9:50pm (Europe/London)
#
#   Current week (all models)
#   ▌▌▌▌░░░░░░░░░░░░░░░░░░░░░░░░░░  13% used
#   Resets May 31 at 1am (Europe/London)

set -u
BAR_WIDTH=30

# Cache paths, fetch constants, and the locked/gated fetch all live in the
# shared lib so the background refresher (usage-refresh.sh) uses identical
# logic and the same rate-limit gates.
LIB="$(cd "$(dirname "$0")" && pwd)/usage-fetch.sh"
if [ ! -r "$LIB" ]; then
  printf '\033[2musage: usage-fetch.sh missing — re-run install.sh\033[0m\n'
  exit 0
fi
source "$LIB"

# Capture the stdin Claude Code passes (we use session_id for shell scan).
IN=$(cat)
SESSION_ID=$(printf '%s' "$IN" | jq -r '.session_id // empty' 2>/dev/null)

# Pull-on-render refresh. A launchd agent also refreshes in the background, but
# we keep this so the line still self-updates if the agent isn't installed.
# Both share the attempt/backoff gates, so this never doubles the API rate.
usage_refresh_cache
cache_age=$(age_of "$CACHE")

if [ ! -s "$CACHE" ]; then
  printf '\033[2musage unavailable (no cache, no token, or offline)\033[0m\n'
  exit 0
fi

# Convert ISO-8601 UTC "2026-05-29T20:50:00.637102+00:00" to an epoch.
to_epoch() {
  local s="$1"
  # Strip fractional seconds and timezone suffix so BSD date matches the fmt.
  s="${s%%.*}"; s="${s%%+*}"; s="${s%%-00:00}"
  date -j -u -f "%Y-%m-%dT%H:%M:%S" "$s" "+%s" 2>/dev/null
}

# BSD date with British locale spells the meridiem as "9:50 p.m." — strip
# the periods and the space so we get "9:50pm" like the /usage screenshot.
clean_meridiem() {
  printf '%s' "$1" | tr -d '.' | tr -d ' ' | tr '[:upper:]' '[:lower:]'
}

# Format an epoch as "9:50pm".
fmt_time() {
  local out; out=$(date -j -r "$1" "+%-I:%M%p" 2>/dev/null) || return
  clean_meridiem "$out"
}

# Format an epoch as "May 31 at 1am".
fmt_full() {
  local d t
  d=$(date -j -r "$1" "+%b %-d" 2>/dev/null) || return
  t=$(date -j -r "$1" "+%-I%p" 2>/dev/null) || return
  printf '%s at %s' "$d" "$(clean_meridiem "$t")"
}

# Render a bar like the screenshot: ▌ for filled, ░ for empty.
# Filled colour shifts with percentage: blue → yellow at 90% → red at 95%.
bar() {
  local pct=$1 width=${2:-$BAR_WIDTH}
  local filled fcolor
  filled=$(awk -v p="$pct" -v w="$width" 'BEGIN{ x=int((p/100.0)*w); if(p>0 && x==0)x=1; if(x>w)x=w; print x }')
  if   [ "$pct" -ge 95 ]; then fcolor='\033[38;5;196m'   # red
  elif [ "$pct" -ge 90 ]; then fcolor='\033[38;5;220m'   # yellow
  else                         fcolor='\033[38;5;147m'   # default blue
  fi
  printf "%b" "$fcolor"
  local i
  for ((i=0; i<filled; i++)); do printf '▌'; done
  printf "\033[38;5;240m"
  for ((i=filled; i<width; i++)); do printf '░'; done
  printf "\033[0m"
}

# Subtle marker next to the percent when usage is in the red zone (≥95 %).
# Soft red `!` instead of a loud ⚠ — the bar already turned red, this is
# just a small extra cue.
warn_glyph() {
  if [ "$1" -ge 95 ]; then
    printf ' \033[2;38;5;167m!\033[0m'
  fi
}

# Append "(stale Nm)" in dim red when the cache hasn't refreshed in a while
# — happens when the API rate-limits us. Better to surface than to lie.
stale_glyph() {
  if [ "$cache_age" -ge "$STALE_TTL" ]; then
    local m=$(( cache_age / 60 ))
    printf ' \033[2;38;5;167m(stale %dm)\033[0m' "$m"
  fi
}

# Freshness cue printed just before the "Current session" header:
#   ↻  cyan   — a network refresh happened on this very tick
#   ●  green  — cache is fresh (< CACHE_TTL)
#   ●  dim    — aging but not yet stale (the "(stale Nm)" tag takes over later)
# Gives an at-a-glance signal that the numbers are live, not frozen.
fresh_glyph() {
  if [ "$USAGE_DID_FETCH" -eq 1 ]; then
    printf '\033[38;5;44m↻\033[0m '
  elif [ "$cache_age" -lt "$CACHE_TTL" ]; then
    printf '\033[38;5;78m●\033[0m '
  elif [ "$cache_age" -lt "$STALE_TTL" ]; then
    printf '\033[2;38;5;78m●\033[0m '
  fi
}

# IANA timezone label, e.g. "Europe/London". Falls back to the OS abbreviation.
tz_label() {
  local link
  link=$(readlink /etc/localtime 2>/dev/null) || true
  if [ -n "$link" ]; then
    printf '%s' "${link##*zoneinfo/}"
  else
    date "+%Z" 2>/dev/null
  fi
}

hour_pct=$(jq -r '.five_hour.utilization // 0'   "$CACHE")
hour_at=$(jq -r '.five_hour.resets_at // empty'  "$CACHE")
week_pct=$(jq -r '.seven_day.utilization // 0'   "$CACHE")
week_at=$(jq -r '.seven_day.resets_at // empty'  "$CACHE")

hour_int=${hour_pct%.*}
week_int=${week_pct%.*}
tz=$(tz_label)

hour_e=$(to_epoch "$hour_at")
week_e=$(to_epoch "$week_at")

# Plan label — pulled from ~/.claude.json so we don't burn an extra API
# round-trip. Pretty-printed and offset slightly so it doesn't crash into
# the "Current session" header below.
# Override: ~/.claude/.usage-plan (or $CCUSAGE_PLAN) wins over the local
# auth state. Claude Code only refreshes organizationType from the server on
# (re)login, so a freshly upgraded/downgraded plan reads stale here until you
# log in again — this knob lets you pin the right label in the meantime.
plan_override=$(cat "$HOME/.claude/.usage-plan" 2>/dev/null | head -n1)
plan_override=${CCUSAGE_PLAN:-$plan_override}
plan_raw=$(jq -r '.oauthAccount.organizationType // empty' "$HOME/.claude.json" 2>/dev/null)
if [ -n "$plan_override" ]; then
  plan="$plan_override"
else
case "$plan_raw" in
  claude_pro)        plan="Claude Pro" ;;
  claude_max_5x)     plan="Claude Max 5×" ;;
  claude_max_20x)    plan="Claude Max 20×" ;;
  claude_team)       plan="Claude Team" ;;
  claude_enterprise) plan="Claude Enterprise" ;;
  "")                plan="" ;;
  *)                 plan="$plan_raw" ;;
esac
fi
if [ -n "$plan" ]; then
  printf "\033[2m%s\033[0m\n" "$plan"
fi

printf "%b\033[1mCurrent session\033[0m\n" "$(fresh_glyph)"
printf "%s  %d%% used%b%b\n" "$(bar "$hour_int")" "$hour_int" "$(warn_glyph "$hour_int")" "$(stale_glyph)"
if [ -n "${hour_e:-}" ]; then
  printf "\033[2mResets %s (%s)\033[0m\n" "$(fmt_time "$hour_e")" "$tz"
fi
printf "\n"
printf "\033[1mCurrent week (all models)\033[0m\n"
printf "%s  %d%% used%b\n" "$(bar "$week_int")" "$week_int" "$(warn_glyph "$week_int")"
if [ -n "${week_e:-}" ]; then
  printf "\033[2mResets %s (%s)\033[0m\n" "$(fmt_full "$week_e")" "$tz"
fi

# Per-model weekly cap. Anthropic meters Opus separately on Max plans and the
# real /usage screen shows it as its own bar — mirror that, but only when the
# API actually returns a number for it (it's null on plans without the split).
opus_pct=$(jq -r '.seven_day_opus.utilization // empty' "$CACHE" 2>/dev/null)
if [ -n "$opus_pct" ]; then
  opus_int=${opus_pct%.*}
  opus_at=$(jq -r '.seven_day_opus.resets_at // empty' "$CACHE" 2>/dev/null)
  opus_e=$(to_epoch "$opus_at")
  printf "\n\033[1mCurrent week (Opus)\033[0m\n"
  printf "%s  %d%% used%b\n" "$(bar "$opus_int")" "$opus_int" "$(warn_glyph "$opus_int")"
  [ -n "${opus_e:-}" ] && printf "\033[2mResets %s (%s)\033[0m\n" "$(fmt_full "$opus_e")" "$tz"
fi

# Compact extra-credits tracker. Renders whatever fields we have — the
# Anthropic API sometimes returns just used_credits without monthly_limit
# now, so we shouldn't require both.
xu_on=$( jq -r '.extra_usage.is_enabled // false'   "$CACHE" 2>/dev/null)
xu_used=$(jq -r '.extra_usage.used_credits // "-"' "$CACHE" 2>/dev/null)
xu_lim=$( jq -r '.extra_usage.monthly_limit // "-"' "$CACHE" 2>/dev/null)
xu_cur=$( jq -r '.extra_usage.currency // ""'       "$CACHE" 2>/dev/null)
xu_pct=$( jq -r '.extra_usage.utilization // "-"'   "$CACHE" 2>/dev/null)
if [ "$xu_on" = "true" ] && [ "$xu_used" != "-" ]; then
  case "$xu_cur" in
    USD) sym="$" ;;
    GBP) sym="£" ;;
    EUR) sym="€" ;;
    *)   sym="" ;;
  esac
  # API returns amounts in minor units (pence / cents). 2898 = £28.98.
  fmt_money() {
    awk -v n="$1" 'BEGIN{ printf "%.2f", n/100 }'
  }
  xu_used_m=$(fmt_money "$xu_used")
  xu_pct_i=${xu_pct%.*}
  if [ "$xu_pct" = "-" ]; then         tint='\033[2m'
  elif [ "$xu_pct_i" -ge 95 ]; then    tint='\033[38;5;196m'
  elif [ "$xu_pct_i" -ge 90 ]; then    tint='\033[38;5;220m'
  else                                 tint='\033[2m'
  fi
  if [ "$xu_lim" != "-" ]; then
    xu_lim_m=$(fmt_money "$xu_lim")
    if [ "$xu_pct" != "-" ]; then
      printf "%b%s%s / %s%s used · %d%%\033[0m\n" \
        "$tint" "$sym" "$xu_used_m" "$sym" "$xu_lim_m" "$xu_pct_i"
    else
      printf "%b%s%s / %s%s used\033[0m\n" \
        "$tint" "$sym" "$xu_used_m" "$sym" "$xu_lim_m"
    fi
  else
    printf "%b%s%s used\033[0m\n" "$tint" "$sym" "$xu_used_m"
  fi
fi

# (Built-in "N shells" indicator already lives at the top of the screen;
# we don't duplicate it here.)
