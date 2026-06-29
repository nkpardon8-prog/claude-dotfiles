# Claude Code Status Line

A 7-field status line that shows authoritative usage info pulled directly from Anthropic's API rate-limit response headers (same source `/usage` uses), plus a second line that shows a **per-window label you set manually with the `/line` command** (or the folder/repo name by default) — and is **always present**.

## What it shows

**Line 1** — usage info (always on):
```
ctx 42%   2h 58m left   31% sess   53% wk   Opus 4.8 [hi]   wk→6th 4pm   my-repo
```

**Line 2** — a per-window label, **never blank**:
```
auth bug in window A
```
Whatever you set with `/line <sentence>` in that window — it's per-window (keyed by session id), so
every instance shows its own. With no label set (or after `/line` with no argument), it falls back to
the worktree/repo name (the same value as the `repo` field on line 1). It's deterministic: the same
text renders whether or not a prompt is active — no progress bars, timers, or auto-written labels.
Set it with `/line` (see `commands/line.md`); rendered by `scripts/statusline.sh` section 7.

| Field | Source | Notes |
|---|---|---|
| `ctx N%` | Token count from current transcript ÷ context window size | Green ≤60%, yellow ≤80%, red >80% |
| `Xh Ym left` | `anthropic-ratelimit-unified-5h-reset` header | Cyan; red <30 min; green if `rate_limited` status |
| `N% sess` | `1 - anthropic-ratelimit-unified-5h-utilization` | Green / yellow >75% / red >90% |
| `N% wk` | `1 - anthropic-ratelimit-unified-7d-utilization` | Same thresholds |
| `Model [effort]` | `model.display_name` + `effort.level` from statusLine JSON | Any `(… context)` parenthetical is stripped — the 1M window is assumed |
| `wk→<day> <time>` | `anthropic-ratelimit-unified-7d-reset` epoch via `date -r` | When the weekly limit resets, e.g. `wk→6th 4pm`. Dim `wk→—` if no cache |
| `repo` | `git rev-parse --show-toplevel` basename, or cwd basename | Bold |

The rate-limit cache (`~/.claude/ratelimit.json`) is refreshed in the background every 5 minutes by a tiny 1-token Haiku request. Cost: negligible.

## Install

> **The `settings.json.template` already wires this up** (the `statusLine` key). On a fresh machine, copying the template to `~/.claude/settings.json` gets the toolbar with no manual step. The manual steps below remain valid for retrofitting an existing `~/.claude/settings.json` that predates the template change. Line 2 (the `/line` label) needs no hooks — it's rendered directly by `statusline.sh`. Tip: symlinking `~/.claude/statusline.sh` and `~/.claude/refresh-ratelimit.sh` to the `scripts/` copies (instead of `cp`) keeps them auto-synced via the dotfiles pull.

Two scripts and one settings change. The OAuth token comes from the macOS keychain (`Claude Code-credentials`), which Claude Code already populates — no extra auth setup.

```bash
# 1. Copy scripts from dotfiles into ~/.claude/
cp ~/.claude-dotfiles/scripts/statusline.sh ~/.claude/statusline.sh
cp ~/.claude-dotfiles/scripts/refresh-ratelimit.sh ~/.claude/refresh-ratelimit.sh
chmod +x ~/.claude/statusline.sh ~/.claude/refresh-ratelimit.sh

# 2. Wire it up in ~/.claude/settings.json — add this top-level key:
#    "statusLine": { "type": "command", "command": "~/.claude/statusline.sh" }

# 3. Prime the cache (optional — statusline kicks the refresh on first render anyway)
~/.claude/refresh-ratelimit.sh

# 4. Reload Claude Code (Ctrl+R or restart)
```

To verify:

```bash
~/.claude/refresh-ratelimit.sh && cat ~/.claude/ratelimit.json
bash ~/.claude/statusline.sh < <(echo '{"model":{"display_name":"Opus 4.7"},"workspace":{"current_dir":"'"$PWD"'"}}')
```

## Install via Claude Code (one-shot prompt)

Paste this into a fresh Claude Code session on a machine where Claude Code is already authenticated:

> Install the Claude Code status line from `~/.claude-dotfiles/scripts/statusline.sh` and `~/.claude-dotfiles/scripts/refresh-ratelimit.sh`. Specifically:
>
> 1. Copy both scripts to `~/.claude/` and `chmod +x` them.
> 2. Add `"statusLine": { "type": "command", "command": "~/.claude/statusline.sh" }` to the top-level object in `~/.claude/settings.json`. Don't clobber existing keys — merge it in. If the file doesn't exist, create it with just that key.
> 3. Run `~/.claude/refresh-ratelimit.sh` to prime the rate-limit cache. If it fails because the keychain entry `Claude Code-credentials` isn't there yet, skip this step and tell me to run `claude` once first to populate the keychain, then re-run.
> 4. Test by piping a sample blob into the script and showing me the output: `bash ~/.claude/statusline.sh < <(echo '{"model":{"display_name":"Opus 4.7"},"workspace":{"current_dir":"'"$PWD"'"}}')`.
> 5. Tell me to reload Claude Code (Ctrl+R or restart) to see it live.
>
> The status line shows: context %, 5h-window time left, 5h usage left, weekly usage left, model + effort, weekly-reset time (`wk→6th 4pm`), repo name. Rate-limit data comes from Anthropic API response headers via a 1-token Haiku call refreshed every 5 minutes in the background.

## Files

- [`scripts/statusline.sh`](../scripts/statusline.sh) — the statusLine command
- [`scripts/refresh-ratelimit.sh`](../scripts/refresh-ratelimit.sh) — background refresher
- Cache lives at `~/.claude/ratelimit.json` (not in dotfiles — local only)

## Troubleshooting

**Status line doesn't appear**
- Check the script is executable: `ls -l ~/.claude/statusline.sh` — needs `x` bits.
- Check `~/.claude/settings.json` has the `statusLine` key at the top level.
- Reload Claude Code (Ctrl+R or restart the app).

**`/line` set a label but line 2 didn't change**
- Line 2 refreshes on the next statusline render (next prompt/tick), not instantly.
- `/line` echoes the resolved session id. It resolves the window from `$CLAUDE_SESSION_ID` /
  `$CLAUDE_CODE_SESSION_ID` (this process's own session id — the same id the renderer reads), so it
  always targets the window you ran it in, regardless of how many other tabs are open or busy. (It no
  longer uses a newest-transcript guess, which used to occasionally bind to a sibling window.) If the
  env id is ever unset it writes nothing and asks you to re-run, so a label can never hit the wrong tab.
- The label lives at `~/.claude/session-status/<session_id>.txt`; `/line` with no argument deletes it
  and line 2 reverts to the folder/repo name.

**Time-left and percentages show `—`**
- Run `~/.claude/refresh-ratelimit.sh` manually and read the stderr — usually a keychain or curl problem.
- Confirm keychain has the entry: `security find-generic-password -s "Claude Code-credentials" -w | head -c 50`. If empty, run `claude` interactively once to authenticate.
- Confirm the cache wrote: `cat ~/.claude/ratelimit.json`.

**Time-left disagrees with `/usage`**
- They should match to the minute. If not, the cache is stale — `rm ~/.claude/ratelimit.json && ~/.claude/refresh-ratelimit.sh`.

**Debug mode**
```bash
CLAUDE_STATUSLINE_DEBUG=1 bash ~/.claude/statusline.sh < <(echo '{}')
```
Prints cache age, parsed reset epochs, and computed time-left to stderr.

## Cost

The refresher posts a 1-token Haiku request every 5 minutes during active use. ~12 calls/hour × ~$0.0001 each = fractions of a cent per day. Cheaper than thinking about it.
