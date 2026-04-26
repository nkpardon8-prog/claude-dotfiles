---
description: Execute a shell command on the Mac mini via the Tailscale side-channel. Buffered or streaming.
argument-hint: "<command> [--timeout=<sec>] [--cwd=<path>] [--stream] [--idem-key=<key>]"
---

# /macmini run

## What this does

Runs `<command>` on the Mac mini under `/bin/zsh -lc` (login shell — inherits PATH from `.zprofile`/`.zshrc`). Output comes back over Tailscale. By default it's buffered (server returns when the command exits). Pass `--stream` to tail output line-by-line as it's produced. This is **ssh-equivalent for the user account** — the bearer token is the only thing standing between the caller and full user-level execution. Treat token loss like ssh-key loss.

---

## Arguments

- `<command>` (required) — the rest of the line. Quote it if it contains spaces or shell metacharacters.
- `--timeout=<sec>` (optional) — defaults 30s server-side, max 300s. Timed-out processes get SIGTERM then SIGKILL on their whole process group.
- `--cwd=<path>` (optional) — working directory for the command. Default is the user's home.
- `--stream` (optional) — stream stdout/stderr chunks live instead of buffering.
- `--idem-key=<key>` (optional) — idempotency key. If a previous call with the same key is still running, the server returns 409. If it completed, the cached result is replayed.

---

## Usage

```bash
# Buffered (default)
macmini-client run "<command>" [--timeout=<sec>] [--cwd=<path>] [--idem-key=<key>]

# Streaming
macmini-client run-stream "<command>" [--timeout=<sec>] [--cwd=<path>] [--idem-key=<key>]
```

---

## Output formatting (buffered)

```
$ <command>
<stdout>
↳ stderr: <stderr>   (only if non-empty)
↳ exit: <code> · duration: <s>
```

Empty stdout: print `$ <command>` then the trailing meta line. Truncated output (the server caps at 1 MiB per stream): append `(truncated)` to the affected stream.

## Output formatting (streaming)

Print each chunk verbatim as it arrives. After the stream closes, print the final meta line:

```
↳ exit: <code> · duration: <s>
```

---

## Errors

On any error response from the server, **always** print the `request_id` so the user can grep the server log:

```
error: <message>
request_id: <id>
hint: tail -200 ~/Library/Logs/macmini-server.log | grep <request_id>
```

The hint command must be runnable on the Mac mini (e.g. via `/macmini run` itself, or directly if you're already on the Mac mini).

---

## Recipes

```bash
# Kick off the project test suite (longer timeout, idempotency-keyed)
macmini-client run "cd ~/code/myproj && npm test" --timeout=180 --idem-key=test-$(date +%s)

# Tail a log live
macmini-client run-stream "tail -f ~/Library/Logs/myapp.log" --timeout=300

# Check what's running
macmini-client run "ps -axo pid,pcpu,pmem,comm | head -20"

# Spotlight reindex hint (uses sudo — will prompt; better avoided over the side-channel)
# Don't run sudo via /macmini run — the server has no way to enter a password.

# Use Homebrew-installed tools (PATH is loaded from .zprofile)
macmini-client run "brew list --versions | head"

# Build a Go project
macmini-client run "cd ~/code/myproj && go build ./..." --timeout=120
```

---

## Notes

- **No sudo.** The server doesn't tunnel a password. Wrap in `osascript -e 'do shell script ... with administrator privileges'` only if you've staged the credentials securely on the Mac mini, otherwise it'll just hang.
- **PATH gotchas.** `/run` uses `/bin/zsh -lc` which sources `.zprofile` and `.zshrc`. If `npm`/`brew`/`gh` aren't found, ensure `eval "$(/opt/homebrew/bin/brew shellenv)"` is in `.zprofile` on the Mac mini.
- **Idempotency.** Re-running the same `--idem-key` while the prior call is in flight returns 409. After completion, replays the cached response.
