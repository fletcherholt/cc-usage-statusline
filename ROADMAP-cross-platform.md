# Cross-platform roadmap: Linux + Windows support

Goal: run the same status line on macOS, Linux, and Windows (Git Bash / WSL)
with no behavior change on macOS. Everything is bash, so the strategy is a thin
**compat layer** that hides the per-OS commands, plus per-OS install/refresher
plumbing. The status-line *logic* (bars, colours, freshness glyph, gating)
stays identical everywhere.

## Where the macOS assumptions live

| Concern | macOS today | Linux | Windows (Git Bash) |
|---|---|---|---|
| File mtime | `stat -f %m` | `stat -c %Y` | `stat -c %Y` |
| ISO → epoch | `date -j -u -f FMT s +%s` | `date -u -d s +%s` | `date -u -d s +%s` |
| epoch → string | `date -j -r EPOCH +FMT` | `date -d @EPOCH +FMT` | `date -d @EPOCH +FMT` |
| OAuth token | Keychain (`security find-generic-password`) | `~/.claude/.credentials.json` | `~/.claude/.credentials.json` |
| Claude version dir | `~/.local/share/claude/versions/` | same | same, fallback `%LOCALAPPDATA%` |
| Background refresher | launchd plist | systemd user timer / cron | Task Scheduler (`schtasks`) |
| Refresher dir | `~/Library/LaunchAgents` | `~/.config/systemd/user` | n/a |

Touch points in code: `usage-fetch.sh` (mtime, token, version dir),
`statusline.sh` (`to_epoch`, `fmt_time`, `fmt_full`, mtime), `usage-refresh.sh`
(mtime), `install.sh` / `uninstall.sh` (refresher).

## Design: a sourced compat layer (`platform.sh`)

New file `platform.sh`, sourced first by `usage-fetch.sh`, `statusline.sh`,
`usage-refresh.sh`. Detect OS once via `uname -s`:
- `Darwin` → macos
- `Linux` → linux (covers WSL; detect WSL via `/proc/version` containing
  `microsoft` only where it matters for the refresher)
- `MINGW*` / `MSYS*` / `CYGWIN*` → windows

Functions the rest of the code calls instead of raw commands:
- `cc_mtime FILE`            → epoch mtime (branches stat -f / -c)
- `cc_now`                   → `date +%s` (universal, no branch)
- `cc_iso_to_epoch ISO`      → branches BSD `-j -u -f` vs GNU `-u -d`
- `cc_epoch_fmt EPOCH FMT`   → branches BSD `-j -r` vs GNU `-d @`
- `cc_get_token`             → Keychain on macOS; else parse
  `~/.claude/.credentials.json` with jq (`.claudeAiOauth.accessToken`)
- `cc_versions_dir`          → resolves the versions dir with Windows fallback

Acceptance: macOS output byte-identical to today; the only macOS change is
"call `cc_*` instead of inline `stat`/`date`/`security`".

## Phases

### Phase 0 — Extract compat layer (no new platforms yet)
- Add `platform.sh` with all `cc_*` funcs, macOS branch only at first.
- Replace inline `stat`/`date`/`security`/version-dir calls in the 3 scripts
  with `cc_*`.
- `test.sh` still green on macOS (21 assertions unchanged).
- Risk: none functional; pure refactor. This is the safety net for the rest.

### Phase 1 — Linux
- Fill in the Linux branch of every `cc_*` func (GNU stat/date).
- Token: read `~/.claude/.credentials.json`. Handle the Keychain-absent case
  and a missing/locked file → return empty, status line shows "no token".
- Refresher: prefer a **systemd user timer**
  (`~/.config/systemd/user/cc-usage.{service,timer}`, `OnUnitActiveSec=60`,
  `systemctl --user enable --now`). Fallback to a cron line
  (`* * * * * usage-refresh.sh`) when systemd-user isn't available (e.g. WSL
  without systemd, minimal containers). Last-resort: document pull-on-render
  only (cache still refreshes whenever the line renders).
- `install.sh` / `uninstall.sh`: branch on OS for the refresher install.
- Verify on a real Ubuntu + on WSL2.

### Phase 2 — Windows (Git Bash / WSL)
- WSL is just Linux — should fall out of Phase 1; verify token path
  (`/home/<user>/.claude` vs Windows-side `.claude`) and that Claude Code on
  Windows actually invokes the status line via Git Bash.
- Git Bash native: confirm `uname` reports `MINGW64`; GNU `date`/`stat` ship
  with Git Bash. Token from `.credentials.json` (no Keychain).
- Version dir fallback: check `~/.local/share/claude/versions`, then
  `$LOCALAPPDATA/claude/versions` style paths; keep the hardcoded UA fallback.
- Refresher: `schtasks /create /sc minute /mo 1 /tn cc-usage-refresh /tr
  "<gitbash> -lc usage-refresh.sh"`. If that's brittle, ship Windows as
  pull-on-render-only and say so in the README.
- CRLF guard: `.gitattributes` forcing `*.sh text eol=lf` so Windows checkouts
  don't break the shebang.

### Phase 3 — Installer + docs
- Single `install.sh` that detects OS and does the right merge + refresher.
- `uninstall.sh` symmetric (remove launchd / systemd unit / scheduled task).
- README: per-OS install section, the platform support matrix, and the
  refresher caveats (systemd-user / Task Scheduler / pull-only fallbacks).

### Phase 4 — CI + tests
- GitHub Actions matrix: `macos-latest`, `ubuntu-latest`, `windows-latest`
  (bash via Git Bash) running `test.sh`.
- Extend `test.sh`: force each OS branch of the compat layer via an env
  override (`CC_FORCE_OS=linux`) and assert `cc_mtime`/`cc_*_epoch` parse the
  same fixtures identically across branches. Keep it hermetic (no network,
  no Keychain) — mock the token via a fixture `.credentials.json`.

### Phase 5 — Release
- Tag a release, note "now supports macOS, Linux, Windows".
- Update the memory note + README support matrix.

## Open questions / risks
- **Windows shell**: confirm how Claude Code on native Windows runs the
  `statusLine` command — if it isn't a bash context, Windows support may be
  WSL/Git-Bash-only. Decide before investing in `schtasks`.
- **Linux token at rest**: `.credentials.json` is plaintext; we only read it,
  but note it in the README (no new exposure — Claude Code wrote it).
- **systemd absence**: common in containers/WSL → cron fallback must be solid.
- **Locale meridiem**: `clean_meridiem` already normalizes; verify GNU date's
  `%p` output matches across locales (may be empty in C locale → handle).
