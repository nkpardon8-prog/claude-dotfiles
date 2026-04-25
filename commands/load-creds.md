# Load Credentials

Inject API keys from the user's 1Password vault into the current project's `.env` via `op inject`.
Catalog lives at `~/.config/claude/credentials.md` (local-only, never synced).

Usage:
- `/load-creds` — auto-detect env vars referenced by the project, confirm with user, then inject.
- `/load-creds OPENAI_API_KEY,SUPABASE_URL` — load a specific comma-separated list.

## Steps

### 1. Verify `op` is available and signed in

```bash
op whoami
```
- If "command not found": tell user to install — `brew install --cask 1password-cli` (macOS), or 1Password CLI for Linux/Windows. Stop.
- If "not signed in": three valid auth modes; pick whichever the user has set up:
  - **Desktop app integration** (interactive macOS/Windows/Linux): open 1Password app → Settings → Developer → "Integrate with 1Password CLI". Touch ID / biometric unlock.
  - **`OP_SERVICE_ACCOUNT_TOKEN`** env var: non-interactive, for headless/CI.
  - **`op signin`** eval: interactive but **only persists in the same shell**, so it does not work across slash-command shells unless the user runs `eval $(op signin)` in their main terminal before invoking Claude.
- Stop and tell the user which option to use. Do not proceed with a stale-auth workaround.

### 2. Multi-account: pin the account for the whole flow

```bash
op account list --format=json
```
- If 0 accounts → not signed in (already handled above).
- If 1 account → set `OP_ACC=""` (no `--account` needed).
- If 2+ accounts AND `$OP_ACCOUNT` is unset → ask the user which to use, then set `OP_ACC="--account <chosen>"` where `<chosen>` is the **sign-in address** or **account ID** from the JSON (`url` or `account_uuid` field), per 1Password docs. Use this on **every** `op` call below — `op read`, `op inject`, etc.
- If `$OP_ACCOUNT` is already set in the env, set `OP_ACC=""` and trust the env var.

### 3. Read the catalog

```bash
test -f ~/.config/claude/credentials.md || { echo "Catalog missing. Copy template: cp ~/.claude-dotfiles/credentials.template.md ~/.config/claude/credentials.md and edit." >&2; exit 1; }
cat ~/.config/claude/credentials.md
```
Parse the markdown tables to build `env_var → op_ref` (and remember which refs contain spaces).

### 4. Identify what this project needs

- If `$ARGUMENTS` is non-empty: comma-separated list of env var names.
- Otherwise: scan the project for env var references. Be broad — projects vary widely:
  - Files: `.env.example`, `.env.template`, `.env.sample`, `README*`, `package.json`, `next.config.*`, `vite.config.*`, `astro.config.*`, `nuxt.config.*`, `Cargo.toml`, `pyproject.toml`, `requirements.txt`.
  - Dirs: `src/`, `app/`, `pages/`, `lib/`, `server/`, `backend/`, `apps/*/`, `packages/*/`, `.github/workflows/`, `infra/`, `terraform/`.
  - Patterns to grep (combine, run via `grep -rEho` against the dirs above):
    - JS/TS: `process\.env\.[A-Z][A-Z0-9_]+`, `process\.env\[["'][A-Z][A-Z0-9_]+["']\]`, `import\.meta\.env\.[A-Z][A-Z0-9_]+`
    - Python: `os\.environ\.get\(["'][A-Z][A-Z0-9_]+["']\)`, `os\.environ\[["'][A-Z][A-Z0-9_]+["']\]`, `os\.getenv\(["'][A-Z][A-Z0-9_]+["']\)`, `getenv\(["'][A-Z][A-Z0-9_]+["']\)`
    - Go: `os\.Getenv\(["'][A-Z][A-Z0-9_]+["']\)`, `os\.LookupEnv\(["'][A-Z][A-Z0-9_]+["']\)`
    - Rust: `env!\(["'][A-Z][A-Z0-9_]+["']\)`, `std::env::var\(["'][A-Z][A-Z0-9_]+["']\)`
    - Deno: `Deno\.env\.get\(["'][A-Z][A-Z0-9_]+["']\)`
    - Shell / `.env*` files: `^[A-Z][A-Z0-9_]+=` (line starts with KEY=)
- Show the detected list and ask the user to confirm/trim.

### 5. Pre-flight safety — ABORT (don't just warn) on tracked secret files

This step runs **before** any file write or any `op` resolution. If any check fails, **stop with an error**; do not proceed.

```bash
# 5a. .env or .env.op already tracked → ABORT
for f in .env .env.op; do
  if git ls-files --error-unmatch "$f" >/dev/null 2>&1; then
    echo "ERROR: $f is currently tracked by git. Aborting to prevent secret leak." >&2
    echo "  Fix: git rm --cached $f && git commit -m 'untrack $f'" >&2
    exit 1
  fi
done

# 5b. Ensure .gitignore exists and has both entries
touch .gitignore
for entry in .env .env.op; do
  grep -qxF "$entry" .gitignore || echo "$entry" >> .gitignore
done

# 5c. Check no symlinks pointing outside the project for these files
for f in .env .env.op .gitignore; do
  if [ -L "$f" ]; then
    target=$(readlink "$f")
    case "$target" in
      /*|*..*) echo "ERROR: $f is a symlink to $target — refusing to write." >&2; exit 1 ;;
    esac
  fi
done
```

### 6. Build `.env.op` (op-references file)

- Parse existing `.env.op` if present into a key-value map (preserve comments and blank lines as a separate ordered list — re-emit them in their original positions if possible; otherwise put them at the top).
- For each requested env var found in the catalog: upsert the key. Last write wins on duplicates.
- **Quote values containing spaces or special characters**: emit `KEY="op://<VAULT>/Google AI/credential"`, not `KEY=op://<VAULT>/Google AI/credential`.
- Warn the user about any requested vars NOT in the catalog — those need to be added to `~/.config/claude/credentials.md` or pasted manually.
- Write the merged result back to `.env.op`.

### 7. Inject — atomically, merging into existing `.env`

`.env` is treated as **authoritative for non-catalog values** (manual entries, local overrides). Never overwrite it blindly.

```bash
# 7a. Resolve op:// → real values into a temp file (NOT directly to .env)
TMP_RESOLVED="$(mktemp -t loadcreds.XXXXXX)"
trap 'rm -f "$TMP_RESOLVED"' EXIT

if ! op $OP_ACC inject -i .env.op -o "$TMP_RESOLVED"; then
  echo "ERROR: op inject failed. Check ~/.config/claude/credentials.md and verify each ref with: op $OP_ACC read 'op://...'" >&2
  exit 1
fi

# 7b. Verify no unresolved op:// strings remain (partial resolution defense)
if grep -q 'op://' "$TMP_RESOLVED"; then
  echo "ERROR: Resolved file still contains op:// strings — partial resolution. Refusing to write .env." >&2
  grep -n 'op://' "$TMP_RESOLVED" >&2
  exit 1
fi

# 7c. Merge into existing .env (preserve any keys not in .env.op)
TMP_MERGED="$(mktemp -t loadcreds.XXXXXX)"
trap 'rm -f "$TMP_RESOLVED" "$TMP_MERGED"' EXIT

# Build set of keys being injected (from .env.op, before resolution)
INJECTED_KEYS=$(grep -E '^[A-Z][A-Z0-9_]*=' .env.op | cut -d= -f1)

# Start with existing .env entries that are NOT being overwritten
if [ -f .env ]; then
  # Keep lines that are: comments, blanks, OR keys not in INJECTED_KEYS
  awk -v keys="$INJECTED_KEYS" 'BEGIN{split(keys,a," "); for(k in a) inj[a[k]]=1}
       /^[[:space:]]*#/ || /^[[:space:]]*$/ {print; next}
       /^[A-Z][A-Z0-9_]*=/ {key=$0; sub(/=.*$/,"",key); if(!inj[key]) print; next}
       {print}' .env > "$TMP_MERGED"
fi

# Append the freshly-resolved values
cat "$TMP_RESOLVED" >> "$TMP_MERGED"

# Atomic replace
mv "$TMP_MERGED" .env
chmod 600 .env
```

May trigger a Touch ID prompt during step 7a.

### 8. Confirm

Print only the env var **names** that were injected. Never print resolved values. Suggest verifying the project boots: `npm run dev` / `python -m app` / etc.

## Safety
- Never echo `.env` contents.
- Never log resolved values during debugging.
- The `.env` file is `chmod 600` after write so other users can't read it.
- The slash command commands themselves contain only `op://` references — shell history is fine.
- If an `op` call fails partway, the trap deletes temp files. The pre-existing `.env` is **not** modified until step 7c's atomic `mv`.
