---
description: Hot-swap the Mac mini server's bearer token without restarting the server or dropping connections.
argument-hint: ""
---

# /macmini rotate-token

## What this does

Issues a hot-swap of the server's bearer token. The Mac mini server generates a new token, swaps it into memory, and atomically writes it to the on-disk `TokenPath` — all without restarting the LaunchAgent and without dropping in-flight connections. The new token is returned **once** in the response. You then update 1Password and re-run `/load-creds` so future agent calls authenticate with the new value.

This is **not** the same as re-running `install.sh`. Use this for routine rotation. Use `install.sh --rotate-token` only when you've lost access to a still-authenticated session and need to bootstrap from scratch on the Mac mini directly.

---

## Steps

### 1. Hot-swap on the server

```bash
macmini-client rotate-token
```

The server returns the new token plus a fingerprint (a short hash you can compare later without echoing the token itself). Example response shape:

```
new_token:    <one-time-display>
fingerprint:  sha256:abcd...1234
```

**The new token is shown ONCE.** If you don't capture it now, you'll need to rotate again.

### 2. Print the new token + fingerprint

Surface them to the user. Make it clear the token will not be re-displayed.

### 3. Update 1Password

Walk the user through replacing the value at:

```
op://<VAULT>/Mac mini CRD/Server Token
```

The catalog at `~/.config/claude/credentials.md` does **not** change — only the vault entry value does, since `/load-creds` reads from 1Password.

### 4. Refresh dev-machine env

After the user confirms 1Password is updated:

```
/load-creds CRD_SERVER_TOKEN
```

This pulls the new value into `.env` for subsequent agent calls.

### 5. Smoke test

```bash
macmini-client health
```

Must succeed with the new token. If this fails:

- The new token didn't make it to 1Password correctly → re-edit the vault entry.
- `/load-creds` ran in a different session → re-run it in the active session.
- The fingerprint reported by the server (`macmini-client health` includes it) doesn't match what you stored → rotate again.

---

## Notes

- No restart, no connection drop. Existing in-flight `/run` calls keep their old auth context until they complete; new calls require the new token.
- If you lose the new token between step 1 and step 3, just rotate again — it's cheap.
- **Treat the token like an SSH key.** `/run` is ssh-equivalent for the user account; the bearer token is the only barrier. Rotate immediately if you suspect leak.
