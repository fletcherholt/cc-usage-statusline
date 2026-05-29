# cc-usage-statusline

A live usage status line for [Claude Code](https://www.anthropic.com/claude-code).
Shows your current 5-hour session usage, weekly usage, plan name, and extra
credits (if you're on Console / overage) — always visible above the prompt,
no `/usage` slash command required.

![preview]: see screenshot at the top of the repo

```
Claude Pro
Current session
████████████████████████████░░  95% used  !
Resets 9:50pm (Europe/London)

Current week (all models)
████░░░░░░░░░░░░░░░░░░░░░░░░░░  15% used
Resets May 31 at 1am (Europe/London)
£1770 / £2500 credits · 70%
```

## What it does

- Polls `https://api.anthropic.com/api/oauth/usage` (the same endpoint the
  built-in `/usage` slash command hits) using the OAuth token already in
  your macOS Keychain — no extra setup.
- Renders bars that turn **yellow at ≥ 90 %** and **red at ≥ 95 %** with a
  small `!` cue.
- Pulls your plan label (Claude Pro / Max 5× / Max 20× / Team / Enterprise)
  straight from `~/.claude.json`.
- Caches the API response for 45 s with a file lock so the 2-second status
  refresh can't fire concurrent calls and rate-limit itself.
- Marks the line `(stale Nm)` if a refresh hasn't succeeded for 3+ min,
  instead of silently showing old numbers.
- Disables Claude Code's built-in yellow usage-warning bar (which is
  redundant with this one) by flipping the `tengu_c4w_usage_limit_notifications_enabled`
  growthbook flag in `~/.claude.json` on every session start.

## Requirements

- macOS (uses the Keychain to read the OAuth token + BSD `date` for
  formatting).
- `jq` installed (`brew install jq`).
- A Claude.ai or Console subscription that's already signed into Claude Code.

## Install

```bash
git clone https://github.com/fletcherholt/cc-usage-statusline.git
cd cc-usage-statusline
bash install.sh
```

The installer:

1. Copies `statusline.sh` to `~/.claude/statusline.sh`.
2. Merges a `statusLine` entry into `~/.claude/settings.json` pointing at it
   (refresh every 2 s).
3. Adds a `SessionStart` hook that re-disables Claude Code's built-in
   usage-warning bar on every fresh session.

Existing settings are preserved. Restart Claude Code (open a new terminal
or relaunch) and the status line appears above your prompt.

## Uninstall

```bash
bash uninstall.sh
```

Removes the script, our `statusLine` entry, and our `SessionStart` hook.

## Configuration

Tweak the top of `statusline.sh`:

| Constant | Default | What it does |
|---|---|---|
| `CACHE_TTL` | 45 | Seconds before a fresh API fetch is attempted again |
| `STALE_TTL` | 180 | Seconds after which the line is labelled `(stale Nm)` |
| `BAR_WIDTH` | 30 | Width of the bar in cells |

Colors are 256-color ANSI; change `38;5;147` / `38;5;220` / `38;5;196` in
the `bar()` function to swap the normal / warn / danger palette.

## Why

Claude Code's built-in usage bar shows a single yellow line at the top of
the screen warning when you're approaching the cap, but only above a
threshold. This script renders both quotas as proper progress bars at all
times, so you can pace yourself instead of finding out at 95 %.

## Known limitations

- macOS only. Linux/Windows port would need a different credential store
  read + GNU `date` syntax.
- Anthropic's `/api/oauth/usage` rate-limits to roughly one call/min/token,
  so the 45 s cache is intentional. Going lower will fail more often.
- Sometimes the API returns a partial response (no `monthly_limit`, no
  `utilization`) — we render whatever we get and skip the line if there's
  no useful data.

## License

MIT.
