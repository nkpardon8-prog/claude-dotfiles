# Load Credentials

Fill the current project's `.env` with the API keys it needs. Values come from the project's own env
files, an env file the user names, or the current shell environment; any value that cannot be found is
left as an empty placeholder for the user to paste into `.env` themselves. Never use 1Password or the
`op` CLI.
Catalog lives at `~/.config/claude/credentials.md` (env var NAMES and where each comes from; local-only,
never synced, never holds values).

Usage:
- `/load-creds` — auto-detect env vars referenced by the project, confirm with user, then fill `.env`.
- `/load-creds OPENAI_API_KEY,SUPABASE_URL` — load a specific comma-separated list.
- `/load-creds --from /path/to/other/.env OPENAI_API_KEY` — copy matching keys from an env file the user names.

## Steps

### 1. Read the catalog

```bash
test -f ~/.config/claude/credentials.md || { echo "Catalog missing. Copy template: cp ~/.claude-dotfiles/credentials.template.md ~/.config/claude/credentials.md and edit." >&2; exit 1; }
cat ~/.config/claude/credentials.md
```
Parse the markdown tables to build `env_var -> source` (the "Where it comes from" column tells the user
where to get a value they have to paste; it is never a value).

### 4. Identify what this project needs

- If `$ARGUMENTS` is non-empty: comma-separated list of env var names. A `--from <path>` pair names the env file to copy values from (`SRC_FILE`).
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

This step runs **before** any file write or any value lookup. If any check fails, **stop with an error**; do not proceed.

```bash
# 5a. .env already tracked -> ABORT
if git ls-files --error-unmatch .env >/dev/null 2>&1; then
  echo "ERROR: .env is currently tracked by git. Aborting to prevent secret leak." >&2
  echo "  Fix: git rm --cached .env && git commit -m 'untrack .env'" >&2
  exit 1
fi

# 5b. Ensure .gitignore exists and ignores .env and the temp files this flow writes
touch .gitignore
for entry in .env '.env.tmp.*'; do
  grep -qxF "$entry" .gitignore || echo "$entry" >> .gitignore
done

# 5c. Refuse symlinks pointing outside the project for these files
for f in .env .gitignore; do
  if [ -L "$f" ]; then
    target=$(readlink "$f")
    case "$target" in
      /*|*..*) echo "ERROR: $f is a symlink to $target — refusing to write." >&2; exit 1 ;;
    esac
  fi
done
```

### 6. Find a value for each requested var (never print it)

For each requested var, in this order, stop at the first hit:
1. The project's `.env` already has a non-empty value: leave it alone.
2. An env file the user named with `--from <path>` (or one they point you at when asked): copy that
   line as written. Read it with `grep`/`cut` into a variable; do not `cat` it.
3. The current shell environment (`printenv "$KEY"`): emit it quoted.
4. Not found: emit an empty placeholder `KEY=` and tell the user where the catalog says to get it
   (the "Where it comes from" column) and to paste the value into `.env` themselves. Do not ask the user to
   paste a secret into chat; if they do anyway, treat it as compromised and suggest rotating it.

Also warn about any requested vars NOT in the catalog: they need adding to `~/.config/claude/credentials.md`.

### 7. Write — atomically, merging into existing `.env`

`.env` is treated as **authoritative for values already set** (manual entries, local overrides). Never overwrite it blindly.

```bash
# Temp files live in the PROJECT DIR so the final mv is a same-filesystem rename (truly atomic).
TMP_NEW=".env.tmp.new.$$"
TMP_MERGED=".env.tmp.merged.$$"
trap 'rm -f "$TMP_NEW" "$TMP_MERGED"' EXIT INT TERM
umask 077

# 7a. Build the new lines. KEYS = the confirmed requested var names; SRC_FILE = the --from file, if any.
: > "$TMP_NEW"
MISSING=""
for KEY in $KEYS; do
  if [ -f .env ] && grep -qE "^$KEY=.+" .env; then continue; fi        # already set: keep it
  line=""
  if [ -n "$SRC_FILE" ]; then line=$(grep -E "^$KEY=.+" "$SRC_FILE" | tail -1); fi
  if [ -z "$line" ]; then
    val=$(printenv "$KEY" || true)
    if [ -n "$val" ]; then
      esc=${val//\\/\\\\}; esc=${esc//\"/\\\"}
      line="$KEY=\"$esc\""
    fi
  fi
  if [ -z "$line" ]; then line="$KEY="; MISSING="$MISSING $KEY"; fi
  printf '%s\n' "$line" >> "$TMP_NEW"
done

# 7b. Merge: keep comments/blanks and every existing line whose key is NOT being rewritten, then append.
# Keys are passed as a \037-delimited list (newline- or space-delimited breaks awk with 2+ keys).
NEW_KEYS=$(grep -E '^[A-Z][A-Z0-9_]*=' "$TMP_NEW" | sed 's/=.*$//' | tr '\n' '\037')

if [ -f .env ]; then
  awk -v keys="$NEW_KEYS" '
    BEGIN {
      n = split(keys, a, "\037")
      for (i = 1; i <= n; i++) if (a[i] != "") inj[a[i]] = 1
    }
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { print; next }
    /^[A-Z][A-Z0-9_]*=/ {
      key = $0
      sub(/=.*$/, "", key)
      if (!(key in inj)) print
      next
    }
    { print }
  ' .env > "$TMP_MERGED"
else
  : > "$TMP_MERGED"
fi
cat "$TMP_NEW" >> "$TMP_MERGED"
chmod 600 "$TMP_MERGED"

# 7c. Atomic same-filesystem rename
mv -f "$TMP_MERGED" .env
```

The merge logic: keep comments/blanks and untouched keys from the old `.env`, drop any line whose key is being rewritten, append the new lines. Idempotent: re-running with the same inputs yields the same `.env`.

### 8. Confirm

Print only the env var **names**: which were filled, which were left as empty placeholders (with the
catalog's "where it comes from" hint for each). Never print values. Suggest verifying the project boots:
`npm run dev` / `python -m app` / etc.

## Safety
- Never echo `.env` contents, and never `cat` a source env file.
- Never log values during debugging.
- The `.env` file is `chmod 600` after write so other users can't read it.
- The temp files are gitignored and deleted by the trap on any exit. The pre-existing `.env` is **not**
  modified until step 7c's atomic `mv`.
