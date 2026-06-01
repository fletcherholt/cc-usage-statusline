#!/bin/bash
# Cross-platform compat layer for cc-usage-statusline.
#
# Sourced first by usage-fetch.sh (and therefore by statusline.sh and
# usage-refresh.sh, which source the fetch lib). It hides every per-OS command
# — file mtime, date math, OAuth token retrieval — behind cc_* functions so the
# rest of the codebase is byte-identical on macOS, Linux, and Windows
# (Git Bash / WSL). Only THIS file knows about BSD vs GNU vs Keychain.
#
# Detection is cached in CC_OS. Set CC_FORCE_OS={macos,linux,windows} to force a
# branch (the test suite uses this to exercise paths that don't depend on the
# host's actual date/stat implementation, e.g. the token file reader).

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

# cc_now -> current time in epoch seconds. Universal across all three OSes.
cc_now() { date +%s; }

# cc_mtime FILE -> file modification time in epoch seconds. Non-zero exit (and
# no output) if the file is absent. BSD `stat -f %m` vs GNU `stat -c %Y`.
cc_mtime() {
  [ -e "$1" ] || return 1
  if [ "$CC_OS" = macos ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

# cc_iso_to_epoch "2026-05-29T20:50:00.637102+00:00" -> epoch seconds.
# The API always returns UTC (+00:00); we strip the fractional seconds and the
# zone suffix, then parse as UTC. BSD needs an explicit input format; GNU reads
# the ISO string directly once we re-mark it UTC with a trailing Z.
cc_iso_to_epoch() {
  local s="$1"
  s="${s%%.*}"; s="${s%%+*}"; s="${s%%-00:00}"
  if [ "$CC_OS" = macos ]; then
    date -j -u -f "%Y-%m-%dT%H:%M:%S" "$s" "+%s" 2>/dev/null
  else
    date -u -d "${s}Z" "+%s" 2>/dev/null
  fi
}

# cc_epoch_fmt EPOCH "FMT" -> that epoch formatted in LOCAL time per strftime
# FMT (e.g. "%-I:%M%p"). BSD `date -j -r` vs GNU `date -d @EPOCH`. The `%-I`
# (no zero-pad) format is a GNU extension that BSD date also accepts.
cc_epoch_fmt() {
  if [ "$CC_OS" = macos ]; then
    date -j -r "$1" "+$2" 2>/dev/null
  else
    date -d "@$1" "+$2" 2>/dev/null
  fi
}

# cc_get_token -> the Claude Code OAuth access token, or empty on failure.
# macOS keeps it in the login Keychain; Linux and Windows write it to
# ~/.claude/.credentials.json in plaintext. We try Keychain first on macOS, then
# fall back to the file on every OS (covers macOS installs that opted out of
# Keychain, and is the only path on Linux/Windows).
cc_get_token() {
  local tok=""
  if [ "$CC_OS" = macos ]; then
    tok=$(security find-generic-password -a "$USER" -s "Claude Code-credentials" -w 2>/dev/null \
            | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
  fi
  if [ -z "$tok" ] && [ -r "$HOME/.claude/.credentials.json" ]; then
    tok=$(jq -r '.claudeAiOauth.accessToken // empty' "$HOME/.claude/.credentials.json" 2>/dev/null)
  fi
  printf '%s' "$tok"
}

# cc_versions_dir -> directory holding installed Claude Code versions, or empty.
# Used only to derive a realistic User-Agent. Linux/macOS use the XDG-ish
# ~/.local/share path; native Windows may instead use %LOCALAPPDATA%/%APPDATA%.
cc_versions_dir() {
  local d
  for d in "$HOME/.local/share/claude/versions" \
           "${LOCALAPPDATA:-}/claude/versions" \
           "${APPDATA:-}/claude/versions"; do
    [ -n "$d" ] && [ -d "$d" ] && { printf '%s' "$d"; return; }
  done
}
