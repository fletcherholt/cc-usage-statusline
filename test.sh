#!/usr/bin/env bash
# Hermetic tests for cc-usage-statusline. No network, no Keychain: we feed the
# status line the same JSON Claude Code passes on stdin and assert on the
# rendered output. Run:  bash test.sh
set -u
SRC_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  \033[31m✗ %s\033[0m\n' "$1"; }
strip(){ sed $'s/\033\\[[0-9;]*m//g'; }

# --- syntax ---
echo "syntax:"
for f in platform.sh statusline.sh install.sh uninstall.sh test.sh; do
  if bash -n "$SRC_DIR/$f" 2>/dev/null; then ok "$f parses"; else bad "$f parse error"; fi
done

# --- cross-platform date compat layer ---
echo "platform compat layer (native = $(uname -s)):"
if ( source "$SRC_DIR/platform.sh"
     [ "$(TZ=UTC cc_epoch_fmt 0 '%Y-%m-%d %H:%M')" = "1970-01-01 00:00" ] || exit 1
     [ "$(cc_iso_to_epoch '1970-01-01T00:00:01+00:00')" = "1" ]           || exit 2
   ); then ok "cc_epoch_fmt / cc_iso_to_epoch correct"; else bad "compat date funcs wrong"; fi

forced=$(CC_FORCE_OS=windows bash -c "source '$SRC_DIR/platform.sh'; printf '%s' \"\$CC_OS\"")
[ "$forced" = "windows" ] && ok "CC_FORCE_OS overrides detection" || bad "CC_FORCE_OS ignored: '$forced'"

# --- render tests (feed stdin JSON, strip colour, assert) ---
render() { printf '%s' "$1" | bash "$SRC_DIR/statusline.sh" 2>/dev/null | strip; }
# A non-git temp dir keeps the git branch out of the output deterministically.
WD=$(mktemp -d); base="${WD##*/}"
# An epoch far in the future never equals "today", so it renders as "Day HH:MM".
FUT=4102444800   # 2100-01-01

echo "render — full (ctx + session + week):"
full='{"workspace":{"current_dir":"'"$WD"'"},"model":{"display_name":"Opus"},"effort":{"level":"high"},
 "context_window":{"used_percentage":18},
 "rate_limits":{"five_hour":{"used_percentage":31,"resets_at":'"$FUT"'},
                "seven_day":{"used_percentage":15,"resets_at":'"$FUT"'}}}'
out=$(render "$full")
grep -q "$base"    <<<"$out" && ok "shows working dir"     || bad "dir missing"
grep -q "Opus"     <<<"$out" && ok "shows model"           || bad "model missing"
grep -q "high"     <<<"$out" && ok "shows effort"          || bad "effort missing"
grep -q "ctx 18%"  <<<"$out" && ok "shows context percent" || bad "ctx missing: $(grep -i ctx <<<"$out")"
grep -q "sess"     <<<"$out" && ok "shows session label"   || bad "session label missing"
grep -q "31%"      <<<"$out" && ok "shows session percent" || bad "session percent missing"
grep -q "week"     <<<"$out" && ok "shows week label"      || bad "week label missing"
grep -q "15%"      <<<"$out" && ok "shows week percent"    || bad "week percent missing"
grep -q "resets"   <<<"$out" && ok "shows reset time"      || bad "reset time missing"

echo "render — no rate_limits (free tier / before first API response):"
out=$(render '{"workspace":{"current_dir":"'"$WD"'"},"model":{"display_name":"Sonnet"},"context_window":{"used_percentage":5}}')
grep -q "ctx 5%" <<<"$out" && ok "still shows ctx"          || bad "ctx missing"
grep -q "sess"   <<<"$out" && bad "session shown with no rate_limits" || ok "no session line without rate_limits"
grep -q "week"   <<<"$out" && bad "week shown with no rate_limits"    || ok "no week line without rate_limits"

echo "render — no context_window (older client):"
out=$(render '{"workspace":{"current_dir":"'"$WD"'"},"model":{"display_name":"Opus"}}')
grep -q "ctx" <<<"$out" && bad "ctx shown when absent" || ok "no ctx line when absent"
grep -q "Opus" <<<"$out" && ok "still shows model" || bad "model missing"

echo "render — out-of-range percent is dropped, not faked:"
out=$(render '{"workspace":{"current_dir":"'"$WD"'"},"context_window":{"used_percentage":150}}')
grep -q "ctx" <<<"$out" && bad "rendered impossible 150%" || ok "drops out-of-range ctx"

rm -rf "$WD"

# --- install.sh settings merge is valid + idempotent ---
echo "install.sh hook merge:"
MERGE='.statusLine={type:"command",command:"X",refreshInterval:2}
 | .hooks.SessionStart=(((.hooks.SessionStart // []) | map(select((.hooks // []) | any(.command // "" | contains("tengu_c4w_usage_limit_notifications_enabled")) | not))) + [{hooks:[{type:"command",command:"x tengu_c4w_usage_limit_notifications_enabled x"}]}])'
ours='[.hooks.SessionStart[]?.hooks[]?.command | select(contains("tengu_c4w_usage_limit_notifications_enabled"))] | length'
once=$(echo '{}'   | jq "$MERGE" 2>/dev/null)
twice=$(echo "$once" | jq "$MERGE" 2>/dev/null)
[ "$(echo "$once"  | jq "$ours")" = "1" ] && ok "adds one hook"                       || bad "expected 1 hook"
[ "$(echo "$twice" | jq "$ours")" = "1" ] && ok "re-run stays at one hook (idempotent)" || bad "duplicate on re-run"
dup='{"hooks":{"SessionStart":[{"hooks":[{"command":"a tengu_c4w_usage_limit_notifications_enabled"}]},{"hooks":[{"command":"b tengu_c4w_usage_limit_notifications_enabled"}]}]}}'
[ "$(echo "$dup" | jq "$MERGE" | jq "$ours")" = "1" ] && ok "collapses existing duplicates to one" || bad "did not dedupe"
echo '{"hooks":{"SessionStart":[{"hooks":[{"command":"my own thing"}]}]}}' | jq "$MERGE" \
  | jq -e '.hooks.SessionStart | any(.hooks[]?.command=="my own thing")' >/dev/null 2>&1 \
  && ok "preserves a pre-existing unrelated hook" || bad "dropped an unrelated hook"

echo
printf 'tests: \033[32m%d passed\033[0m, ' "$pass"
if [ "$fail" -gt 0 ]; then printf '\033[31m%d failed\033[0m\n' "$fail"; exit 1; else printf '0 failed\n'; fi
