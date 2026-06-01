# cc-usage-statusline

A live usage status line for [Claude Code](https://www.anthropic.com/claude-code).
Shows your current 5-hour session usage, weekly usage (plus a separate Opus bar
on plans that meter it), your plan name, and extra credits — always visible
above the prompt, no `/usage` slash command required.

```
Claude Max 5×
● Current session
▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌░░  95% used  !
Resets 9:50pm (Europe/London)

Current week (all models)
▌▌▌▌░░░░░░░░░░░░░░░░░░░░░░░░░░  15% used
Resets May 31 at 1am (Europe/London)

Current week (Opus)
▌▌▌▌▌▌▌▌▌▌▌░░░░░░░░░░░░░░░░░░░  42% used
Resets May 31 at 1am (Europe/London)
£17.70 / £25.00 used · 70%
```

## What it does

- Polls `https://api.anthropic.com/api/oauth/usage` (the same endpoint the
  built-in `/usage` command hits) using the OAuth token Claude Code already
  stored (macOS Keychain, or `~/.claude/.credentials.json` on Linux/Windows) —
  no extra setup.
- Bars turn **yellow at ≥ 90 %** and **red at ≥ 95 %** with a small `!` cue.
- A **freshness glyph** sits before the session header so you can trust the
  numbers at a glance: `●` fresh · dim `●` aging · `↻` refreshing right now ·
  `(stale Nm)` if a refresh hasn't landed in a while.
- A **background refresher** keeps the cache warm every 60 s even when Claude
  Code is idle or closed, so the line is warm the moment you look (launchd on
  macOS, a systemd user timer / cron on Linux, Task Scheduler on Windows).
- **Self-healing:** the usage endpoint only allows a small burst per minute on
  your token — and Claude Code's own `/usage` polling spends from the same
  budget — so individual fetches sometimes get rate-limited (HTTP 429). When
  that leaves the data stale, the script escalates and retries quickly (honoring
  the server's `Retry-After`) until a good response lands.
- **`/usage-refresh` slash command** forces an immediate refresh, bypassing all
  rate-limit gates, for when you want it updated *now*.
- Pulls your plan label (Pro / Max 5× / Max 20× / Team / Enterprise) from
  `~/.claude.json`, with an override knob (see Configuration).
- Renders extra-usage credits (Console / overage) in your billing currency.
- Disables Claude Code's redundant built-in yellow usage-warning bar via the
  `tengu_c4w_usage_limit_notifications_enabled` growthbook flag on session start.

## Requirements

- `bash` + `jq`. On Windows, run inside **Git Bash** or **WSL** (the same shell
  Claude Code uses to invoke the status line there).
  - jq: `brew install jq` (macOS) · `sudo apt install jq` (Linux) ·
    `winget install jqlang.jq` (Windows).
- A Claude.ai or Console subscription already signed into Claude Code.

### Platform support

| Platform | Token source | Date/stat | Background refresher |
|---|---|---|---|
| macOS | Keychain | BSD | launchd agent |
| Linux (incl. WSL) | `~/.claude/.credentials.json` | GNU | systemd user timer → cron → pull-only |
| Windows (Git Bash) | `~/.claude/.credentials.json` | GNU (Git Bash) | Task Scheduler → pull-only |

All OS-specific behavior lives in one file, `platform.sh` (the `cc_*` helpers);
the rest of the code is identical everywhere. If the background refresher can't
be installed (no systemd/cron/Task Scheduler), the line still self-refreshes on
every render — you just lose the warm-while-idle updates.

## Install

```bash
git clone https://github.com/fletcherholt/cc-usage-statusline.git
cd cc-usage-statusline
bash install.sh
```

The installer:

1. Copies `statusline.sh`, the `platform.sh` compat layer, the shared
   `usage-fetch.sh` lib, and the `usage-refresh.sh` background updater to
   `~/.claude/`.
2. Merges a `statusLine` entry into `~/.claude/settings.json` (refresh every 2 s).
3. Adds a `SessionStart` hook that disables Claude Code's built-in usage-warning
   bar. (Idempotent — re-running never piles up duplicates.)
4. Installs the `/usage-refresh` command to `~/.claude/commands/`.
5. Registers the background refresher for your OS (launchd / systemd timer /
   cron / Task Scheduler) to refresh the cache every 60 s.

Existing settings are preserved. Restart Claude Code and the line appears above
your prompt. (Slash commands are picked up without a restart.)

## Uninstall

```bash
bash uninstall.sh
```

Removes the scripts, the background refresher (launchd / systemd / cron / Task
Scheduler), the `/usage-refresh` command, our `statusLine` entry and
`SessionStart` hook, and the cache files.

## The status line says `(stale Nm)`

That means the shared usage endpoint has been rate-limiting refreshes. It will
recover on its own within a few minutes; to fix it instantly, run:

```
/usage-refresh
```

If even that reports a high age or `?`, the endpoint is actively returning 429
this second — wait ~30 s and run it again.

## Configuration

Constants live at the top of `usage-fetch.sh`:

| Constant | Default | What it does |
|---|---|---|
| `CACHE_TTL` | 45 | Seconds a fetched value stays "fresh" before a re-fetch |
| `STALE_TTL` | 360 | Seconds after which the line is labelled `(stale Nm)` and fast-retry escalation kicks in |
| `MIN_FETCH_INTERVAL` | 60 | Floor between real API calls across all callers |
| `BACKOFF_429` | 60 | Minimum wait after a 429 (raised if the server's `Retry-After` asks for more) |
| `STALE_RETRY` | 15 | Retry cadence once data is stale, to recover fast |

`BAR_WIDTH` (default 30) is in `statusline.sh`. Bar colors are 256-color ANSI —
change `38;5;147` / `38;5;220` / `38;5;196` in `bar()` to reskin normal / warn /
danger.

**Plan label override:** the label comes from `organizationType` in
`~/.claude.json`, which only updates when you re-login. If it's wrong after an
upgrade/downgrade, pin it with `echo "Claude Max 20×" > ~/.claude/.usage-plan`
(or set `CCUSAGE_PLAN`).

## How refreshes stay cheap

All callers — the 2-second status render, the 60-second background refresher,
and `/usage-refresh` — share one fetch path (`usage-fetch.sh`) gated by on-disk
markers (`.usage-cache.attempt`, `.usage-cache.backoff`) and a lock. So no
matter how many render ticks fire, real API calls are capped at roughly one per
minute and never overlap, which keeps you from rate-limiting yourself.

## Testing

```bash
bash test.sh
```

Hermetic — seeds a mock cache in a throwaway `HOME` and asserts on the rendered
output, the compat layer (`cc_*`), and the installer's settings merge. No
network, no Keychain. CI runs it on macOS, Linux, and Windows (Git Bash).

## Known limitations

- The background refresher needs a per-OS scheduler (launchd / systemd-user /
  cron / Task Scheduler). Where none is available — e.g. a container or a WSL
  distro without systemd — it falls back to pull-on-render only.
- The numbers are as live as the rate limit allows. Claude Code does not persist
  utilization to disk, so the data can only come from the (rate-limited) API —
  hence the caching, background agent, and `/usage-refresh` escape hatch.
- Partial API responses (missing `monthly_limit`/`utilization`) are rendered
  with whatever fields are present; missing lines are skipped rather than faked.

## License

MIT.
