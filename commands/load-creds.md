# Load Credentials

Load API keys from the user's 1Password vault into the current project's `.env` via `op inject`.

Usage:
- `/load-creds` — auto-detect env vars referenced by the project, confirm with user, then inject.
- `/load-creds OPENAI_API_KEY,SUPABASE_URL` — load a specific comma-separated list.

## Steps

1. **Verify `op` is available and signed in**:
   ```bash
   op whoami
   ```
   - If "command not found": instruct the user to install 1Password CLI (`brew install --cask 1password-cli` or the 1Password desktop app with CLI integration). Stop.
   - If "not signed in" / no accounts: instruct the user to enable 1Password desktop app integration (Settings → Developer → "Integrate with 1Password CLI"). `op signin`'s eval form does NOT persist into this slash command's shell, so desktop integration is the right fix. Stop.

2. **Multi-account check**:
   ```bash
   op account list --format=json
   ```
   If more than one account is returned and `OP_ACCOUNT` is not set in the environment, ask the user which account to use and pass `--account <shorthand>` on subsequent `op` calls.

3. **Read the catalog**:
   ```bash
   cat ~/.claude-dotfiles/credentials.md
   ```
   Parse the markdown tables to build a map of `env_var → op:// reference`.

4. **Identify what this project needs**:
   - If `$ARGUMENTS` is non-empty, treat it as a comma-separated list of env var names.
   - Otherwise, scan the project for env var references in: `.env.example`, `.env.op`, README files, `package.json` scripts, and source files (`grep -rEho 'process\.env\.[A-Z_]+|os\.environ\[.[A-Z_]+.|getenv\(.[A-Z_]+.\)' src/`). Show the detected list to the user and ask for confirmation.

5. **Gitignore safety FIRST** (before writing any files):
   - Ensure `.gitignore` exists and contains both `.env` and `.env.op`. Create or append as needed.
   - Verify `.env` is not currently tracked:
     ```bash
     git ls-files --error-unmatch .env 2>/dev/null && echo "WARNING: .env is tracked — run: git rm --cached .env"
     ```

6. **Build `.env.op`** (op-references file, distinct from any committed `.env.example`):
   - If `.env.op` already exists, parse its existing key=value pairs.
   - Upsert: for each requested env var found in the catalog, set `<KEY>=<op_ref>` (last write wins on duplicates).
   - Warn the user about any requested vars NOT in the catalog — those need to be added to `~/.claude-dotfiles/credentials.md` first or pasted manually.
   - Write the merged result back to `.env.op`.

7. **Inject**:
   ```bash
   op inject -i .env.op -o .env
   ```
   May trigger a Touch ID prompt. If it fails (e.g., reference not found), report the specific `op://` ref to the user — likely needs a fix in the catalog or the 1Password item.

8. **Confirm**: print the list of env var NAMES that were injected. Never print `.env` contents or resolved values.

## Safety
- Never echo resolved secret values to the terminal.
- Never log `.env` contents during debugging.
- The slash command's commands themselves contain no secrets (only `op://` references), so shell history is fine.
