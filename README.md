# cc-usage-statusline

[![Support me on Ko-fi](https://img.shields.io/badge/Support%20me-Ko--fi-FF5E5B?logo=ko-fi&logoColor=white&style=for-the-badge)](https://ko-fi.com/fletcherholt)

A compact status line for [Claude Code](https://www.anthropic.com/claude-code).
It shows your working directory, git branch, model, how full the context window
is, and your 5-hour session plus 7-day usage bars, always visible above the
prompt with no `/usage` slash command required.

```
▌ myproject · main* · Opus · ctx 18%
sess ▌▌▌░░░░░░░░░░  31%  · resets 21:50
week ▌▌░░░░░░░░░░░░  15%  · resets Sat 01:00
```

Everything is read from the JSON Claude Code already passes to a status line on
stdin. There is no OAuth fetch, no cache, no background job, and nothing that
can go stale.

## What it shows

Line 1:
- Working directory (leaf folder, with `~` for home).
- Git branch, with a `*` when the working tree is dirty.
- Model display name, plus the reasoning effort level and a `fast` marker when
  those are set.
- `ctx NN%`, the share of the context window currently in use.

Lines 2 and 3 (Pro and Max plans, once the session has made its first request):
- `sess`, the rolling 5-hour usage bar and reset time.
- `week`, the 7-day usage bar and reset time.

Bars and the context figure go green under 60%, amber from 60%, and red from
80%.

## Colours adapt to your terminal

The line paints with the 16 standard ANSI colours (green, amber, red, and your
default foreground), so it takes on whatever palette your terminal theme
defines rather than baking in one designer's colours. It looks native on a plain
black terminal, on Catppuccin, on Solarized, or on anything else. To reskin it,
change the colour variables near the top of `statusline.sh`.

## Requirements

- `bash` and `jq`. On Windows, run inside Git Bash or WSL (the same shell Claude
  Code uses to invoke the status line there).
  - jq: `brew install jq` (macOS), `sudo apt install jq` (Linux),
    `winget install jqlang.jq` (Windows).
- A recent Claude Code. The context figure needs the `context_window` field
  (Claude Code 2.1.132 and later); the usage bars need a Pro or Max
  subscription and appear after the first request of the session.

Only date formatting differs per platform, and it lives in one file,
`platform.sh`. The rest of the code is identical on macOS, Linux, and Windows.

## Install

```bash
git clone https://github.com/fletcherholt/cc-usage-statusline.git
cd cc-usage-statusline
bash install.sh
```

The installer:

1. Copies `statusline.sh` and the `platform.sh` date helper to `~/.claude/`.
2. Merges a `statusLine` entry into `~/.claude/settings.json`, preserving your
   other settings.
3. Adds a `SessionStart` hook that switches off Claude Code's built-in
   usage-limit warning bar, which is redundant with the bars shown here. The
   merge is idempotent, so re-running never piles up duplicates.

Restart Claude Code and the line appears above your prompt.

## Uninstall

```bash
bash uninstall.sh
```

Removes the scripts, our `statusLine` entry, and our `SessionStart` hook. Your
other settings are left alone.

## Configuration

Everything tweakable lives at the top of `statusline.sh`:

- Colour variables (`GREEN`, `YELLOW`, `RED`, `CYAN`, and so on) if you want a
  fixed palette instead of the terminal's own.
- The 60% and 80% thresholds in `pct_color`.
- The bar width (`w=14`) in `bar`.

## Testing

```bash
bash test.sh
```

Hermetic: it feeds the status line sample stdin payloads and asserts on the
rendered output, checks the date compat layer, and validates the installer's
settings merge. No network, no Keychain. CI runs it on macOS, Linux, and Windows
(Git Bash).

## Notes

- The usage bars come straight from Claude Code, so they are exactly as live as
  the values it holds. They are absent on the free tier and until the session's
  first request lands.
- Percent fields outside 0 to 100 are dropped rather than drawn, so a bad value
  never renders a misleading bar.

## Support

If this saved you a trip to `/usage`, you can buy me a coffee:

[![Support me on Ko-fi](https://img.shields.io/badge/Support%20me-Ko--fi-FF5E5B?logo=ko-fi&logoColor=white&style=for-the-badge)](https://ko-fi.com/fletcherholt)

## License

MIT.
