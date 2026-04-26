---
description: Download a file from the Mac mini to the dev machine via the Tailscale side-channel.
argument-hint: "<remote-path> [local-path]"
---

# /macmini pull

## What this does

Downloads a file from the Mac mini to the dev machine over Tailscale. Returns the SHA-256 of what arrived. Default local destination is `./<basename>` in the current working directory.

---

## Arguments

- `<remote-path>` (required) — file on the Mac mini. Tilde expansion happens server-side.
- `[local-path]` (optional) — destination on the dev machine. Default: `./<basename of remote-path>` in the current cwd.

---

## Usage

```bash
# Default — drops into cwd as ./<basename>
macmini-client pull "<remote-path>"

# Explicit destination
macmini-client pull "<remote-path>" "<local-path>"
```

---

## Output

The client prints the SHA-256 of the file as received and the byte size. Surface it:

```
pulled: ./example.txt
sha256: 3b1c8f...e92a
size:   4123 bytes
```

If the server's reported SHA doesn't match the local file's SHA after write, abort and tell the user — the wire is misbehaving.

---

## Errors

- `remote not found` → check the remote path; tilde expands to the Mac mini user's `$HOME`.
- `local exists` → choose a different `<local-path>` or remove the existing file.
- `connection refused` / `timeout` → run `/macmini status`.
- `401 unauthorized` → re-run `/load-creds CRD_SERVER_TOKEN`.
