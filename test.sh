#!/usr/bin/env bash
# Hermetic tests for cc-usage-statusline. No network, no Keychain: we seed a
# mock cache and gate off the fetch, then assert on the rendered output. Run:
#   bash test.sh
set -u
SRC_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  \033[31m✗ %s\033[0m\n' "$1"; }
strip(){ sed $'s/\033\\[[0-9;]*m//g'; }

# --- syntax ---
echo "syntax:"
for f in platform.sh usage-fetch.sh usage-refresh.sh statusline.sh install.sh uninstall.sh test.sh; do
  if bash -n "$SRC_DIR/$f" 2>/dev/null; then ok "$f parses"; else bad "$f parse error"; fi
done

# --- cross-platform compat layer ---
echo "platform compat layer (native = $(uname -s)):"
# cc_now numeric; cc_iso_to_epoch exact on a fixed UTC instant; cc_epoch_fmt
# formats in local time (pinned to UTC here). These exercise the host's real
# date/stat branch, so they also validate the GNU path on the Linux/Windows CI.
if ( source "$SRC_DIR/platform.sh"
     n=$(cc_now);                          case "$n" in ''|*[!0-9]*) exit 1;; esac
     [ "$(cc_iso_to_epoch '1970-01-01T00:00:01+00:00')" = "1" ] || exit 2
     [ "$(TZ=UTC cc_epoch_fmt 1 '%Y')" = "1970" ]               || exit 3
   ); then ok "cc_now / cc_iso_to_epoch / cc_epoch_fmt correct"; else bad "compat date/epoch funcs wrong"; fi

# cc_mtime returns a numeric epoch for an existing file (native stat branch).
TF=$(mktemp)
m=$( source "$SRC_DIR/platform.sh"; cc_mtime "$TF" )
case "$m" in ''|*[!0-9]*) bad "cc_mtime non-numeric: '$m'";; *) ok "cc_mtime numeric";; esac
rm -f "$TF"

# cc_get_token reads ~/.claude/.credentials.json (forced linux branch so the
# test is deterministic on any host — this path is pure jq+file, no date/stat).
TD=$(mktemp -d); mkdir -p "$TD/.claude"
printf '%s' '{"claudeAiOauth":{"accessToken":"tok-abc123"}}' > "$TD/.claude/.credentials.json"
got=$(HOME="$TD" CC_FORCE_OS=linux bash -c "source '$SRC_DIR/platform.sh'; cc_get_token")
[ "$got" = "tok-abc123" ] && ok "cc_get_token reads .credentials.json" || bad "token read got: '$got'"
rm -rf "$TD"

# CC_FORCE_OS override is honoured.
forced=$(CC_FORCE_OS=windows bash -c "source '$SRC_DIR/platform.sh'; printf '%s' \"\$CC_OS\"")
[ "$forced" = "windows" ] && ok "CC_FORCE_OS overrides detection" || bad "CC_FORCE_OS ignored: '$forced'"

# --- jq filter in install.sh is valid + idempotent ---
echo "install.sh hook merge:"
# Mirror of the jq filter in install.sh (strip prior copies, add exactly one).
MERGE='.statusLine={type:"command",command:"X",refreshInterval:2}
 | .hooks.SessionStart=(((.hooks.SessionStart // []) | map(select((.hooks // []) | any(.command // "" | contains("tengu_c4w_usage_limit_notifications_enabled")) | not))) + [{hooks:[{type:"command",command:"x tengu_c4w_usage_limit_notifications_enabled x"}]}])'
ours='[.hooks.SessionStart[]?.hooks[]?.command | select(contains("tengu_c4w_usage_limit_notifications_enabled"))] | length'
once=$(echo '{}'   | jq "$MERGE" 2>/dev/null)
twice=$(echo "$once" | jq "$MERGE" 2>/dev/null)
[ "$(echo "$once"  | jq "$ours")" = "1" ] && ok "adds one hook"                       || bad "expected 1 hook"
[ "$(echo "$twice" | jq "$ours")" = "1" ] && ok "re-run stays at one hook (idempotent)" || bad "duplicate on re-run"
# Starting from 3 stale duplicates, it collapses to exactly 1.
dup='{"hooks":{"SessionStart":[{"hooks":[{"command":"a tengu_c4w_usage_limit_notifications_enabled"}]},{"hooks":[{"command":"b tengu_c4w_usage_limit_notifications_enabled"}]},{"hooks":[{"command":"c tengu_c4w_usage_limit_notifications_enabled"}]}]}}'
[ "$(echo "$dup" | jq "$MERGE" | jq "$ours")" = "1" ] && ok "collapses existing duplicates to one" || bad "did not dedupe"
# Unrelated hooks survive.
echo '{"hooks":{"SessionStart":[{"hooks":[{"command":"my own thing"}]}]}}' | jq "$MERGE" \
  | jq -e '.hooks.SessionStart | any(.hooks[]?.command=="my own thing")' >/dev/null 2>&1 \
  && ok "preserves a pre-existing unrelated hook" || bad "dropped an unrelated hook"

# --- render tests in a throwaway HOME ---
render() { # $1 = stdin json ; uses $HOME mock
  printf '%s' "${1:-{\}}" | bash "$SRC_DIR/statusline.sh" 2>/dev/null | strip
}
T=$(mktemp -d); export HOME="$T"; mkdir -p "$T/.claude"
# Gate the fetch off hard so tests never touch the network.
printf '%s' 99999 > "$T/.claude/.usage-cache.backoff"
touch "$T/.claude/.usage-cache.attempt"
cat > "$T/.claude.json" <<'JSON'
{"oauthAccount":{"organizationType":"claude_max_5x"}}
JSON
seed() { cat > "$T/.claude/.usage-cache.json"; touch "$T/.claude/.usage-cache.attempt"; printf '%s' 99999 > "$T/.claude/.usage-cache.backoff"; }

echo "render — fresh, all fields:"
seed <<'JSON'
{"five_hour":{"utilization":73.0,"resets_at":"2026-05-31T20:50:00+00:00"},
 "seven_day":{"utilization":13.0,"resets_at":"2026-06-01T00:00:00+00:00"},
 "extra_usage":{"is_enabled":true,"used_credits":1770,"monthly_limit":2500,"utilization":70.8,"currency":"GBP"}}
JSON
out=$(render '{"session_id":"t"}')
grep -q "Claude Max 5×"       <<<"$out" && ok "plan label"        || bad "plan label missing"
grep -q "73% used"            <<<"$out" && ok "session percent"   || bad "session percent"
grep -q "13% used"            <<<"$out" && ok "week percent"      || bad "week percent"
grep -q "Current week (all models)" <<<"$out" && ok "week header" || bad "week header"
grep -q "£17.70 / £25.00"     <<<"$out" && ok "credits money fmt" || bad "credits fmt: $(grep -i used <<<"$out"|tail -1)"
grep -qi "stale"              <<<"$out" && bad "false stale on fresh" || ok "no stale when fresh"
grep -q "●"                   <<<"$out" && ok "freshness glyph present" || bad "no freshness glyph"

echo "render — stale data:"
seed <<'JSON'
{"five_hour":{"utilization":5.0,"resets_at":"2026-05-31T20:50:00+00:00"},
 "seven_day":{"utilization":8.0,"resets_at":"2026-06-01T00:00:00+00:00"}}
JSON
touch -t 202001010000 "$T/.claude/.usage-cache.json"   # ancient
out=$(render '{"session_id":"t"}')
grep -qi "stale" <<<"$out" && ok "labels stale when old" || bad "missing stale label"

echo "render — Opus per-model line:"
seed <<'JSON'
{"five_hour":{"utilization":5.0,"resets_at":"2026-05-31T20:50:00+00:00"},
 "seven_day":{"utilization":8.0,"resets_at":"2026-06-01T00:00:00+00:00"},
 "seven_day_opus":{"utilization":42.0,"resets_at":"2026-06-01T00:00:00+00:00"}}
JSON
out=$(render '{"session_id":"t"}')
grep -q "Current week (Opus)" <<<"$out" && ok "renders Opus line when present" || bad "Opus line missing"
grep -q "42% used"            <<<"$out" && ok "Opus percent"                    || bad "Opus percent"
# And absent when the field is null
seed <<'JSON'
{"five_hour":{"utilization":5.0,"resets_at":"2026-05-31T20:50:00+00:00"},
 "seven_day":{"utilization":8.0,"resets_at":"2026-06-01T00:00:00+00:00"},
 "seven_day_opus":null}
JSON
out=$(render '{"session_id":"t"}')
grep -q "Current week (Opus)" <<<"$out" && bad "Opus line shown when null" || ok "no Opus line when null"

rm -rf "$T"
echo
printf 'tests: \033[32m%d passed\033[0m, ' "$pass"
if [ "$fail" -gt 0 ]; then printf '\033[31m%d failed\033[0m\n' "$fail"; exit 1; else printf '0 failed\n'; fi
