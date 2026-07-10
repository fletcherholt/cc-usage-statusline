#!/bin/bash
# cc-usage-statusline — a compact Claude Code status line.
#
#   ▌ myproject · main* · Opus · ctx 18%
#   sess ▌▌▌░░░  31%  · resets 21:50
#   week ▌▌░░░░  15%  · resets Sat 01:00
#
# Line 1: working dir, git branch, model (+ effort / fast mode), context used.
# Lines 2/3: 5-hour session + 7-day rate-limit bars (Pro/Max plans).
#
# Everything comes from the JSON Claude Code passes on stdin — no OAuth fetch,
# no cache, no background refresher, nothing to go stale. Colours use the 16
# standard ANSI slots (green/yellow/red + default foreground), so the line
# adopts whatever palette your terminal theme defines instead of hardcoding one.
set -u
input="$(cat)"

# Cross-platform date handling lives in the compat layer, installed alongside
# this script. Fall back to inline BSD/GNU probing if it isn't present.
DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
if [ -r "$DIR/platform.sh" ]; then
  . "$DIR/platform.sh"
else
  if date -r 0 +%s >/dev/null 2>&1; then
    cc_epoch_fmt()    { date -r "$1" "+$2" 2>/dev/null; }
    cc_iso_to_epoch() { local s=${1%%.*}; s=${s%%+*}; date -j -u -f "%Y-%m-%dT%H:%M:%S" "$s" "+%s" 2>/dev/null; }
  else
    cc_epoch_fmt()    { date -d "@$1" "+$2" 2>/dev/null; }
    cc_iso_to_epoch() { local s=${1%%.*}; s=${s%%+*}; date -u -d "${s}Z" "+%s" 2>/dev/null; }
  fi
fi

# 16-colour ANSI. These map to the user's own theme, so the line looks native
# on any terminal — Catppuccin, Solarized, or a plain black default.
BOLD=$'\033[1m'; DIM=$'\033[2m'
CYAN=$'\033[36m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'
R=$'\033[0m'

# Pull every field in one jq pass, unit-separator delimited so values with
# spaces (dir names, "%a %H:%M") survive the read.
row="$(printf '%s' "$input" | jq -r '
  def pct(v): if (v|type) == "number" and v >= 0 and v <= 100 then (v | round | tostring) else "" end;
  [
    (.workspace.current_dir // .cwd // ""),
    (.model.display_name // "?"),
    (.effort.level // ""),
    pct(.context_window.used_percentage),
    pct(.rate_limits.five_hour.used_percentage),
    (.rate_limits.five_hour.resets_at // ""),
    pct(.rate_limits.seven_day.used_percentage),
    (.rate_limits.seven_day.resets_at // ""),
    (if .fast_mode == true then "fast" else "" end)
  ] | map(tostring) | join("\u001f")' 2>/dev/null)"
IFS=$'\x1f' read -r dir model effort ctx s_pct s_reset w_pct w_reset fast <<< "$row"

# Green under 60%, amber from 60%, red from 80% — in the terminal's own colours.
pct_color() {
  local p=${1:-0}
  if   [ "$p" -ge 80 ]; then printf '%s' "$RED"
  elif [ "$p" -ge 60 ]; then printf '%s' "$YELLOW"
  else                       printf '%s' "$GREEN"; fi
}

bar() {
  local p=${1:-0} w=14 fill i
  fill=$(( p * w / 100 )); [ "$fill" -gt "$w" ] && fill=$w
  printf '%s' "$(pct_color "$p")"
  for (( i=0; i<fill; i++ )); do printf '▌'; done
  printf '%s' "$DIM"
  for (( i=fill; i<w; i++ )); do printf '░'; done
  printf '%s' "$R"
}

# resets_at is a unix epoch; show HH:MM if it lands today, else "Wed 01:00".
# Tolerates an ISO-8601 string too, in case a client sends that form.
fmt_reset() {
  local ts=${1:-}; [ -z "$ts" ] && return
  case "$ts" in ''|*[!0-9]*) ts="$(cc_iso_to_epoch "$ts")" ;; esac
  [ -z "$ts" ] && return
  if [ "$(cc_epoch_fmt "$ts" %Y%m%d)" = "$(date +%Y%m%d)" ]; then
    cc_epoch_fmt "$ts" %H:%M
  else
    cc_epoch_fmt "$ts" "%a %H:%M"
  fi
}

# Shorten $HOME to ~ and keep only the leaf directory.
if [ -n "$dir" ] && [ "${dir#"$HOME"}" != "$dir" ]; then
  dirshort="~${dir#"$HOME"}"
else
  dirshort="$dir"
fi
case "$dirshort" in
  "~"|"") dirbase="~" ;;
  *)      dirbase="${dirshort##*/}" ;;
esac

line1="${CYAN}▌${R} ${BOLD}${dirbase}${R}"
branch="$(git -C "$dir" branch --show-current 2>/dev/null)"
if [ -n "$branch" ]; then
  dirty=""
  [ -n "$(git -C "$dir" status --porcelain -uno --no-renames 2>/dev/null | head -1)" ] && dirty="*"
  line1="${line1} ${DIM}·${R} ${CYAN}${branch}${dirty}${R}"
fi
line1="${line1} ${DIM}·${R} ${model}"
[ -n "$effort" ] && line1="${line1} ${DIM}${effort}${R}"
[ -n "$fast" ] && line1="${line1} ${YELLOW}${fast}${R}"
[ -n "$ctx" ] && line1="${line1} ${DIM}· ctx${R} $(pct_color "$ctx")${ctx}%${R}"

printf '\n'
printf '%s\n' "$line1"
printf '\n'

if [ -n "$s_pct" ]; then
  printf '%ssess%s %s %s%3s%%%s' "$DIM" "$R" "$(bar "$s_pct")" "$BOLD" "$s_pct" "$R"
  rs="$(fmt_reset "$s_reset")"; [ -n "$rs" ] && printf ' %s· resets %s%s' "$DIM" "$rs" "$R"
  printf '\n'
fi
if [ -n "$w_pct" ]; then
  printf '%sweek%s %s %s%3s%%%s' "$DIM" "$R" "$(bar "$w_pct")" "$BOLD" "$w_pct" "$R"
  rs="$(fmt_reset "$w_reset")"; [ -n "$rs" ] && printf ' %s· resets %s%s' "$DIM" "$rs" "$R"
  printf '\n'
fi
exit 0
