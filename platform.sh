#!/bin/bash
# Cross-platform date compat layer for cc-usage-statusline.
#
# Sourced by statusline.sh. It hides BSD (macOS) vs GNU (Linux / WSL / Git Bash)
# date differences behind cc_* helpers so the rest of the script is identical
# everywhere. Only this file knows which userland it's on.
#
# Detection is cached in CC_OS. Set CC_FORCE_OS={macos,linux,windows} to force a
# branch (the test suite uses this).

if [ -n "${CC_FORCE_OS:-}" ]; then
  CC_OS="$CC_FORCE_OS"
else
  case "$(uname -s 2>/dev/null)" in
    Darwin)               CC_OS=macos ;;
    Linux)                CC_OS=linux ;;    # also covers WSL
    MINGW*|MSYS*|CYGWIN*) CC_OS=windows ;;  # Git Bash / MSYS2 / Cygwin
    *)                    CC_OS=linux ;;    # unknown → assume GNU userland
  esac
fi

# cc_epoch_fmt EPOCH "FMT" -> that epoch formatted in LOCAL time per strftime
# FMT (e.g. "%H:%M"). BSD `date -r` vs GNU `date -d @EPOCH`.
cc_epoch_fmt() {
  if [ "$CC_OS" = macos ]; then
    date -r "$1" "+$2" 2>/dev/null
  else
    date -d "@$1" "+$2" 2>/dev/null
  fi
}

# cc_iso_to_epoch "2026-05-29T20:50:00+00:00" -> epoch seconds. Only used as a
# fallback if a client ever sends resets_at as an ISO string rather than epoch.
# Strips fractional seconds and the zone suffix, then parses as UTC.
cc_iso_to_epoch() {
  local s="$1"
  s="${s%%.*}"; s="${s%%+*}"; s="${s%%-00:00}"
  if [ "$CC_OS" = macos ]; then
    date -j -u -f "%Y-%m-%dT%H:%M:%S" "$s" "+%s" 2>/dev/null
  else
    date -u -d "${s}Z" "+%s" 2>/dev/null
  fi
}
