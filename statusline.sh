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
CACHE="$HOME/.claude/.usage-cache.json"
LOCK="$HOME/.claude/.usage-cache.lock"
CACHE_TTL=45                  # how long a fresh fetch stays "fresh"
STALE_TTL=180                 # after this we visibly label the data stale
BAR_WIDTH=30
ENDPOINT="https://api.anthropic.com/api/oauth/usage"

# Capture the stdin Claude Code passes (we use session_id for shell scan).
IN=$(cat)
SESSION_ID=$(printf '%s' "$IN" | jq -r '.session_id // empty' 2>/dev/null)

# Refresh the cache if it's missing or older than CACHE_TTL — guarded by
# a file lock so the 2-second status refresh can't fire concurrent API
# calls (each call would rate-limit the next). If we can't take the lock,
# another renderer is already refreshing; we just use whatever's on disk.
need_refresh=1
cache_age=999999
if [ -s "$CACHE" ]; then
  cache_age=$(( $(date +%s) - $(stat -f %m "$CACHE" 2>/dev/null || echo 0) ))
  [ "$cache_age" -lt "$CACHE_TTL" ] && need_refresh=0
fi
# Try to take the lock; if another script is refreshing, skip.
if [ "$need_refresh" -eq 1 ] && ( set -o noclobber; : > "$LOCK" ) 2>/dev/null; then
  trap 'rm -f "$LOCK"' EXIT
  tok=$(security find-generic-password -a "$USER" -s "Claude Code-credentials" -w 2>/dev/null \
         | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
  if [ -n "$tok" ]; then
    # Capture both the response and HTTP status so we can detect rate limits.
    curl -sS -m 5 -w '\n%{http_code}\n' \
      -H "Authorization: Bearer $tok" \
      -H "anthropic-beta: oauth-2025-04-20" \
      -H "User-Agent: claude-cli/2.1.150 (external, cli)" \
      "$ENDPOINT" 2>/dev/null > "$CACHE.tmp"
    # Pull the final line (status code) and the rest (body).
    http_code=$(tail -n 1 "$CACHE.tmp" 2>/dev/null)
    head -n -1 "$CACHE.tmp" 2>/dev/null > "$CACHE.body"
    # Only replace the cache if we got 200 AND the response has real numbers,
    # not the null-filled response Anthropic returns under transient errors.
    if [ "$http_code" = "200" ] && jq -e '.five_hour.utilization != null' "$CACHE.body" >/dev/null 2>&1; then
      mv "$CACHE.body" "$CACHE"
      cache_age=0
    fi
    rm -f "$CACHE.tmp" "$CACHE.body"
  fi
  rm -f "$LOCK"; trap - EXIT
fi

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
plan_raw=$(jq -r '.oauthAccount.organizationType // empty' "$HOME/.claude.json" 2>/dev/null)
case "$plan_raw" in
  claude_pro)        plan="Claude Pro" ;;
  claude_max_5x)     plan="Claude Max 5×" ;;
  claude_max_20x)    plan="Claude Max 20×" ;;
  claude_team)       plan="Claude Team" ;;
  claude_enterprise) plan="Claude Enterprise" ;;
  "")                plan="" ;;
  *)                 plan="$plan_raw" ;;
esac
if [ -n "$plan" ]; then
  printf "\033[2m%s\033[0m\n" "$plan"
fi

printf "\033[1mCurrent session\033[0m\n"
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
  xu_used_i=${xu_used%.*}
  xu_pct_i=${xu_pct%.*}
  # Tint by utilization when known; dim otherwise.
  if [ "$xu_pct" = "-" ]; then         tint='\033[2m'
  elif [ "$xu_pct_i" -ge 95 ]; then    tint='\033[38;5;196m'
  elif [ "$xu_pct_i" -ge 90 ]; then    tint='\033[38;5;220m'
  else                                 tint='\033[2m'
  fi
  if [ "$xu_lim" != "-" ]; then
    xu_lim_i=${xu_lim%.*}
    if [ "$xu_pct" != "-" ]; then
      printf "%b%s%s / %s%s credits · %d%%\033[0m\n" \
        "$tint" "$sym" "$xu_used_i" "$sym" "$xu_lim_i" "$xu_pct_i"
    else
      printf "%b%s%s / %s%s credits\033[0m\n" \
        "$tint" "$sym" "$xu_used_i" "$sym" "$xu_lim_i"
    fi
  else
    # Just the used amount when no limit is reported.
    printf "%b%s%s credits used\033[0m\n" "$tint" "$sym" "$xu_used_i"
  fi
fi

# (Built-in "N shells" indicator already lives at the top of the screen;
# we don't duplicate it here.)
