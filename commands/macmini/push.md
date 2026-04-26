---
description: Upload a local file to the Mac mini via the Tailscale side-channel.
argument-hint: "<local-path> [remote-path]"
---

# /macmini push

## What this does

Uploads a file from the dev machine to the Mac mini over Tailscale. Returns the SHA-256 of what landed, so you can verify integrity. Default remote path is `~/Documents/macmini-skill/<basename>` on the Mac mini.

---

## Arguments

- `<local-path>` (required) — file to send. Use absolute paths to avoid surprises.
- `[remote-path]` (optional) — destination on the Mac mini. Default: `~/Documents/macmini-skill/<basename of local-path>`.

---

## Usage

```bash
# Default destination
macmini-client push "<local-path>"

# Explicit destination
macmini-client push "<local-path>" "<remote-path>"

# Allow overwriting an existing remote file
macmini-client push --overwrite "<local-path>" "<remote-path>"
```

Without `--overwrite`, the client refuses if the remote path already exists. This is on purpose — silent overwrites lose data.

---

## Output

The client prints the SHA-256 of the file as written on the Mac mini. Surface it so the user can spot-check:

```
pushed: ~/Documents/macmini-skill/example.txt
sha256: 3b1c8f...e92a
size:   4123 bytes
```

If the local file's SHA-256 doesn't match what the server reports, abort and tell the user — the wire is misbehaving.

---

## Errors

- `remote exists, refusing to overwrite` → re-run with `--overwrite` if intentional.
- `connection refused` / `timeout` → run `/macmini status`.
- `401 unauthorized` → re-run `/load-creds CRD_SERVER_TOKEN`.
- `permission denied` writing remote path → the server runs as the Mac mini user; pick a remote path under `$HOME`.
