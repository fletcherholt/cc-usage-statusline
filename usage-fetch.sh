#!/bin/bash
# Shared usage-cache fetch logic for cc-usage-statusline.
#
# Sourced by both statusline.sh (pull-on-render) and usage-refresh.sh (the
# launchd background updater). Keeping the fetch + gating in one place means
# both callers share the SAME attempt/backoff markers — so the combined rate
# across the renderer, the background refresher, and Claude Code's own /usage
# polling still tops out at one real API call per MIN_FETCH_INTERVAL. Adding
# the background refresher therefore can't increase 429 pressure; it just
# fills the gaps when Claude isn't rendering the status line.

# Cross-platform compat layer (cc_* helpers for mtime/date/token). Sourced from
# this file's own directory so it resolves the same whether we're run directly
# or sourced by statusline.sh / usage-refresh.sh. If it's somehow missing (an
# old install that predates platform.sh), define a compact inline fallback so
# the script still works on the OS it's running on instead of hard-failing.
_CC_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
if [ -r "$_CC_LIB_DIR/platform.sh" ]; then
  source "$_CC_LIB_DIR/platform.sh"
fi
if ! type cc_now >/dev/null 2>&1; then
  case "$(uname -s 2>/dev/null)" in
    Darwin) CC_OS=macos ;; MINGW*|MSYS*|CYGWIN*) CC_OS=windows ;; *) CC_OS=linux ;;
  esac
  cc_now(){ date +%s; }
  cc_mtime(){ [ -e "$1" ] || return 1; if [ "$CC_OS" = macos ]; then stat -f %m "$1" 2>/dev/null; else stat -c %Y "$1" 2>/dev/null; fi; }
  cc_iso_to_epoch(){ local s="$1"; s="${s%%.*}"; s="${s%%+*}"; s="${s%%-00:00}"; if [ "$CC_OS" = macos ]; then date -j -u -f "%Y-%m-%dT%H:%M:%S" "$s" "+%s" 2>/dev/null; else date -u -d "${s}Z" "+%s" 2>/dev/null; fi; }
  cc_epoch_fmt(){ if [ "$CC_OS" = macos ]; then date -j -r "$1" "+$2" 2>/dev/null; else date -d "@$1" "+$2" 2>/dev/null; fi; }
  cc_get_token(){ local t=""; if [ "$CC_OS" = macos ]; then t=$(security find-generic-password -a "$USER" -s "Claude Code-credentials" -w 2>/dev/null | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null); fi; [ -z "$t" ] && [ -r "$HOME/.claude/.credentials.json" ] && t=$(jq -r '.claudeAiOauth.accessToken // empty' "$HOME/.claude/.credentials.json" 2>/dev/null); printf '%s' "$t"; }
  cc_versions_dir(){ local d; for d in "$HOME/.local/share/claude/versions" "${LOCALAPPDATA:-}/claude/versions" "${APPDATA:-}/claude/versions"; do [ -n "$d" ] && [ -d "$d" ] && { printf '%s' "$d"; return; }; done; }
fi

CACHE="$HOME/.claude/.usage-cache.json"
LOCK="$HOME/.claude/.usage-cache.lock"
ATTEMPT="$HOME/.claude/.usage-cache.attempt"  # marks last fetch *attempt*
BACKOFF="$HOME/.claude/.usage-cache.backoff"  # marks last 429 (rate-limit) hit
CACHE_TTL=45                  # how long a fresh fetch stays "fresh"
STALE_TTL=360                 # after this we visibly label the data stale
MIN_FETCH_INTERVAL=60         # floor between API calls (endpoint allows ~1/min/token)
BACKOFF_429=60               # after a 429, stay off the API this long. The token's
                             # ~8-burst/min budget refills within tens of seconds, so
                             # 60s usually lands in a fresh 200 window; longer just
                             # prolongs staleness when Claude's own polling contends
MAX_BACKOFF=120              # ceiling for a server Retry-After. The endpoint allows
                             # ~1/min, so any larger value is almost certainly a
                             # transient over-share; honouring a literal 3600 would
                             # freeze the cache (and even force/stale-retry) for an
                             # hour. Cap it so one rogue header can't wedge us.
LOCK_STALE=20                # a lock older than this means the holder died; reclaim it
STALE_RETRY=15               # once data is stale, retry this fast (overrides the
                             # attempt/backoff floors) so wake-from-sleep recovers
ENDPOINT="https://api.anthropic.com/api/oauth/usage"

# User-Agent must look like the real CLI. Detect the installed Claude Code
# version so the header doesn't drift out of date as Claude updates (a stale UA
# risks the endpoint treating us differently). Falls back to a known-good value.
USAGE_UA_VER=""
_cc_vdir=$(cc_versions_dir)
[ -n "$_cc_vdir" ] && USAGE_UA_VER=$(ls -t "$_cc_vdir" 2>/dev/null \
                 | grep -E '^[0-9]+\.[0-9]+' | head -n1)
[ -n "$USAGE_UA_VER" ] || USAGE_UA_VER="2.1.158"
USAGE_UA="claude-cli/$USAGE_UA_VER (external, cli)"

# Did this process actually perform a network fetch this run? Lets the status
# line show a ↻ "updating" glyph on the tick where it refreshed.
USAGE_DID_FETCH=0

# age_of FILE -> seconds since mtime (huge number if absent). Delegates the
# stat syscall to the compat layer (BSD vs GNU).
age_of() {
  local m; m=$(cc_mtime "$1") || { echo 999999; return; }
  [ -n "$m" ] || { echo 999999; return; }
  echo $(( $(cc_now) - m ))
}

# Refresh the cache if it's missing or older than CACHE_TTL — guarded by a
# file lock so concurrent callers can't fire overlapping API calls. Honours
# the attempt-gate (caps real calls at 1/MIN_FETCH_INTERVAL) and the 429
# backoff. Sets USAGE_DID_FETCH=1 if it actually hit the network.
usage_refresh_cache() {
  # Pass "force" (e.g. from the /usage-refresh slash command) to ignore every
  # gate and fetch right now — the manual escape hatch when it's stuck stale.
  local force="${1:-}" need_refresh=1 cache_age
  cache_age=$(age_of "$CACHE")
  [ -s "$CACHE" ] && [ "$cache_age" -lt "$CACHE_TTL" ] && need_refresh=0

  # Escalation: once the data is actually stale (≥ STALE_TTL, or no cache at
  # all) the normal gates work against us. The big offenders are wake-from-sleep
  # and reopening Claude after it was closed — launchd's StartInterval doesn't
  # fire while asleep, so the cache ages out, and the first refresh afterwards
  # can catch a transient 429 that then arms the backoff, leaving a big stale
  # number on screen for minutes. When stale we drop both gates to STALE_RETRY
  # so we retry quickly until a 200 lands and recover within seconds instead.
  # The endpoint serves 200s readily outside of contention, so this converges
  # fast; the lock still prevents concurrent calls.
  local stale=0 fetch_floor="$MIN_FETCH_INTERVAL" backoff_floor="$BACKOFF_429"
  if [ ! -s "$CACHE" ] || [ "$cache_age" -ge "$STALE_TTL" ]; then
    stale=1; fetch_floor="$STALE_RETRY"; backoff_floor="$STALE_RETRY"
  fi

  # Manual force: drop all gates and fetch now. Still takes the lock and still
  # only writes the cache on a real 200, so it can't corrupt anything.
  if [ "$force" = "force" ]; then
    need_refresh=1; fetch_floor=0; backoff_floor=0
  fi

  # Global attempt-gate. The cache mtime only advances on a *successful* fetch,
  # so on a failure (429, offline, killed mid-curl) cache_age stays high and
  # every tick would otherwise fire another curl. The ATTEMPT marker is touched
  # on every attempt regardless of outcome, capping real calls to one per
  # fetch_floor across all callers sharing the token.
  if [ "$need_refresh" -eq 1 ] && [ -e "$ATTEMPT" ]; then
    [ "$(age_of "$ATTEMPT")" -lt "$fetch_floor" ] && need_refresh=0
  fi

  # 429 backoff. The endpoint rate-limits per token and Claude Code's own
  # /usage polling spends from the same budget. We obey the server's own
  # Retry-After: the BACKOFF file stores how many seconds it asked us to wait
  # (written on the 429), and we hold off for the LARGER of that and our floor
  # — so we never retry sooner than the server wants, nor sit idle longer than
  # needed. The floor is shortened while stale so one unlucky 429 can't freeze
  # a recovery. (Observed Retry-After is usually 0, i.e. the floor governs.)
  # A manual force skips this entirely — it's the escape hatch, so it must not
  # be gated by a stored Retry-After (a literal 3600 once wedged it for an hour).
  if [ "$force" != "force" ] && [ "$need_refresh" -eq 1 ] && [ -e "$BACKOFF" ]; then
    local want; want=$(cat "$BACKOFF" 2>/dev/null)
    [[ "$want" =~ ^[0-9]+$ ]] || want=0
    [ "$want" -lt "$backoff_floor" ] && want="$backoff_floor"
    [ "$(age_of "$BACKOFF")" -lt "$want" ] && need_refresh=0
  fi

  # Reclaim a stale lock left by a killed holder.
  if [ -e "$LOCK" ] && [ "$(age_of "$LOCK")" -ge "$LOCK_STALE" ]; then
    rm -f "$LOCK"
  fi

  [ "$need_refresh" -eq 1 ] || return 0

  # Take the lock; if another caller is refreshing, skip.
  ( set -o noclobber; : > "$LOCK" ) 2>/dev/null || return 0
  trap 'rm -f "$LOCK"' RETURN
  touch "$ATTEMPT"   # record the attempt *before* the call, win or lose
  USAGE_DID_FETCH=1

  local tok http_code retry_after
  tok=$(cc_get_token)
  if [ -n "$tok" ]; then
    # -D dumps response headers so we can read Retry-After on a 429.
    curl -sS -m 5 -D "$CACHE.hdr" -w '\n%{http_code}\n' \
      -H "Authorization: Bearer $tok" \
      -H "anthropic-beta: oauth-2025-04-20" \
      -H "User-Agent: $USAGE_UA" \
      "$ENDPOINT" 2>/dev/null > "$CACHE.tmp"
    http_code=$(tail -n 1 "$CACHE.tmp" 2>/dev/null)
    sed -e '$d' "$CACHE.tmp" 2>/dev/null > "$CACHE.body"
    # Only replace the cache on 200 with real numbers, not the null-filled
    # response Anthropic returns under transient errors.
    if [ "$http_code" = "200" ] && jq -e '.five_hour.utilization != null' "$CACHE.body" >/dev/null 2>&1; then
      mv "$CACHE.body" "$CACHE"
      rm -f "$BACKOFF"                 # clean window — clear any backoff
    elif [ "$http_code" = "429" ]; then
      # Record how long the server told us to wait (default 0 → our floor wins).
      retry_after=$(grep -i '^retry-after:' "$CACHE.hdr" 2>/dev/null | tr -d '\r' | awk '{print $2}')
      [[ "$retry_after" =~ ^[0-9]+$ ]] || retry_after=0
      [ "$retry_after" -gt "$MAX_BACKOFF" ] && retry_after="$MAX_BACKOFF"
      printf '%s' "$retry_after" > "$BACKOFF"
    fi
    rm -f "$CACHE.tmp" "$CACHE.body" "$CACHE.hdr"
  fi
  rm -f "$LOCK"; trap - RETURN
}
