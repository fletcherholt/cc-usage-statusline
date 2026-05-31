---
description: Force-refresh the usage status-line cache (fixes a "stale" reading)
allowed-tools: Bash(bash ~/.claude/usage-refresh.sh --force)
---
Force a refresh of the Claude Code usage status line right now, ignoring the
rate-limit gates.

!`bash ~/.claude/usage-refresh.sh --force`

In one short line, report the refreshed numbers from the output above. If the
age is still high or a value is "?", the shared usage endpoint is rate-limiting
(HTTP 429) at the moment — tell the user to wait ~30s and run `/usage-refresh`
again.
