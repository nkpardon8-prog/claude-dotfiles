# Setup & Operations

Full install guide, auto-sync behavior, credential system, and troubleshooting for the
[claude-dotfiles](../README.md) repo. The README stays focused on the skills; everything
operational lives here.

> This guide is written so a Claude Code session can execute it. Paste it into a fresh session
> and it'll walk the steps. Where you see `[USER INPUT]`, ask for the value — never guess it.
> This dotfiles repo auto-syncs across devices; **project code repos are never pushed without
> explicit approval.**

---

## What's in the repo

```
~/.claude-dotfiles/
├── CLAUDE.md               # Global rules (loaded every session)
├── credentials.template.md # Template for the 1Password catalog (real catalog lives at
│                           #   ~/.config/claude/credentials.md — local-only, gitignored)
├── commands/               # Slash commands (available as /command-name)
│   ├── *.md                # Core commands (plan, implement, mission, ...)
│   ├── parsa/  plan2bid/  ui-ux-pro-max/   # namespaced suites
├── agents/                 # Sub-agents spawned by skills
├── rules/                  # Global rules applied to all projects
├── patterns/               # Learned behavioral patterns (filled by /learn)
├── docs/                   # Long-form docs (this file, ARCHITECTURE, COMMANDS, STATUSLINE, ...)
├── scripts/                # sync, statusline, cleanup, whisper, hooks
├── .env.example            # Whisper key template
└── .env                    # Your API keys (gitignored)
```

---

## Prerequisites

```bash
claude --version        # Claude Code CLI installed
gh auth status          # GitHub CLI authenticated
git config user.name    # Git configured
git config user.email
```

If git isn't configured:
```bash
git config --global user.name  "[USER INPUT: full name]"
git config --global user.email "[USER INPUT: email]"
```

---

## Step 1 — Clone

```bash
git clone https://github.com/nkpardon8-prog/claude-dotfiles.git "$HOME/.claude-dotfiles"
ls "$HOME/.claude-dotfiles/CLAUDE.md"   # verify
```

## Step 2 — Make the sync script executable

```bash
chmod +x "$HOME/.claude-dotfiles/scripts/dotfiles-sync.sh"
```

## Step 3 — Symlink into ~/.claude

Check for existing targets first; if any exist, confirm with the user before replacing:
```bash
ls -la "$HOME/.claude/CLAUDE.md" "$HOME/.claude/commands" "$HOME/.claude/agents" \
       "$HOME/.claude/rules" "$HOME/.claude/patterns" 2>/dev/null
```

```bash
rm -f  "$HOME/.claude/CLAUDE.md" 2>/dev/null
rm -rf "$HOME/.claude/commands" "$HOME/.claude/agents" "$HOME/.claude/rules" \
       "$HOME/.claude/patterns" 2>/dev/null

ln -sf "$HOME/.claude-dotfiles/CLAUDE.md"  "$HOME/.claude/CLAUDE.md"
ln -sf "$HOME/.claude-dotfiles/commands"   "$HOME/.claude/commands"
ln -sf "$HOME/.claude-dotfiles/agents"     "$HOME/.claude/agents"
ln -sf "$HOME/.claude-dotfiles/rules"      "$HOME/.claude/rules"
ln -sf "$HOME/.claude-dotfiles/patterns"   "$HOME/.claude/patterns"
```

## Step 4 — Auto-sync hooks in settings.json

Read `~/.claude/settings.json` (create if missing) and merge:

```json
{
  "hooks": {
    "SessionStart": [
      { "hooks": [ {
        "type": "command",
        "command": "cd ~/.claude-dotfiles && git pull --ff-only 2>/dev/null; if [ -f ~/.config/claude/credentials.md ] && grep -nIE '(sk-(ant|proj|svcacct)?-?[A-Za-z0-9_-]{20,}|AIza[0-9A-Za-z_-]{35}|ghp_[A-Za-z0-9]{36,}|gho_[A-Za-z0-9]{36,}|ghu_[A-Za-z0-9]{36,}|ghs_[A-Za-z0-9]{36,}|ghr_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{40,}|AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}|xox[abposr]-[A-Za-z0-9-]{10,}|hf_[A-Za-z0-9]{30,}|ya29\\.[A-Za-z0-9_-]{20,}|whsec_[A-Za-z0-9]{20,}|(rk|sk|pk)_(live|test)_[A-Za-z0-9]{20,}|-----BEGIN +(RSA +|OPENSSH +)?PRIVATE +KEY-----)' ~/.config/claude/credentials.md 2>/dev/null; then echo 'WARNING: possible secret value in ~/.config/claude/credentials.md — should be op:// references only. Rotate the leaked secret.' >&2; fi; true",
        "timeout": 10,
        "statusMessage": "Syncing dotfiles..."
      } ] }
    ],
    "PostToolUse": [
      { "matcher": "Edit|Write", "hooks": [ {
        "type": "command",
        "command": "$HOME/.claude-dotfiles/scripts/dotfiles-sync.sh",
        "async": true
      } ] }
    ]
  }
}
```

- **SessionStart** — auto-pulls latest dotfiles, then runs a non-blocking secret-leak check on
  `~/.config/claude/credentials.md`.
- **PostToolUse (Edit|Write)** — auto-pushes dotfiles changes. Runs a hard pre-push secret scan
  first; on any match the push is **blocked** (exit 2) and you're told to rotate.

## Step 5 — Plugins (optional)

```bash
for p in agent-sdk-dev claude-code-setup claude-md-management code-review code-simplifier \
         commit-commands feature-dev hookify learning-output-style playground \
         pr-review-toolkit security-guidance skill-creator; do claude plugin install "$p"; done
```

## Step 6 — MCP servers (per-project)

`.mcp.json` is **per-project and contains API keys — NOT synced.** Each project on each device
needs its own. Template:

```json
{
  "mcpServers": {
    "supabase":   { "command": "npx", "args": ["-y", "@supabase/mcp-server-supabase@latest", "--access-token", "[USER INPUT]"], "type": "stdio" },
    "netlify":    { "command": "npx", "args": ["-y", "@netlify/mcp"], "type": "stdio", "env": { "NETLIFY_AUTH_TOKEN": "[USER INPUT]" } },
    "cloudflare": { "command": "npx", "args": ["-y", "@cloudflare/mcp-server-cloudflare"], "type": "stdio", "env": { "CLOUDFLARE_API_TOKEN": "[USER INPUT]" } }
  }
}
```

## Step 7 — Shell aliases (optional)

```bash
alias cco='claude --model opus'
alias ccs='claude --model sonnet'
alias ccp='claude --model opusplan'
alias cch='claude --model haiku'
```

## Step 8 — Verify

```bash
ls -la "$HOME/.claude/commands"                       # → symlink into .claude-dotfiles
grep -c "SessionStart" "$HOME/.claude/settings.json"  # → ≥1
test -x "$HOME/.claude-dotfiles/scripts/dotfiles-sync.sh" && echo "sync OK"
```
Then start a session: global rules should load, and `/` should list the commands.

---

## Auto-sync behavior

| Event | Action |
|---|---|
| Session starts | `git pull` latest dotfiles (SessionStart hook) |
| Any dotfile edited | `git add + commit + push` (PostToolUse hook, after a pre-push secret scan) |
| `/learn` runs | Saves patterns, then pushes |
| Manual | `cd ~/.claude-dotfiles && git add -A && git commit -m "update" && git push` |

Changes appear on other devices at next session start.

## Adding commands, agents, or rules

| To add | Create file at | Becomes |
|---|---|---|
| Command | `commands/foo.md` | `/foo` |
| Namespaced command | `commands/<ns>/foo.md` | `/<ns>:foo` |
| Sub-agent | `agents/foo.md` | `subagent_type: "foo"` |
| Global rule | `rules/foo.md` | Loaded every session |

The PostToolUse hook auto-pushes after the edit lands.

---

## Credentials (1Password-backed)

`/load-creds` + a 1Password catalog inject API keys into a project's `.env` with no copy/paste.
**Real secrets never live in this synced repo.**

- **Real secrets** live in your 1Password vault (encrypted, biometric unlock).
- **The catalog** at `~/.config/claude/credentials.md` is **local-only, never synced** — it maps
  env var names → `op://` references. The template at `credentials.template.md` (in this repo) is
  a starting point; copy it to the local path on a fresh machine and edit.
- `/load-creds` writes a temp `.env.op`, runs `op inject`, verifies no `op://` strings remain,
  then **merges** resolved values into the existing `.env` (preserving manual entries) and
  `chmod 600`s it. Touch ID fires once.
- **Two layers of leak defense:** the pre-push scan in `dotfiles-sync.sh` **blocks** any push
  whose staged/untracked files match known secret shapes (exit 2); SessionStart warns
  (non-blocking) on the same patterns in the catalog.

**One-time per device:**
1. `brew install --cask 1password-cli` (or your OS equivalent).
2. Enable an auth mode: 1Password app → Settings → Developer → "Integrate with 1Password CLI"
   (interactive), or `OP_SERVICE_ACCOUNT_TOKEN` (CI), or `eval $(op signin)`.
3. `op whoami` to verify.
4. `mkdir -p ~/.config/claude && cp ~/.claude-dotfiles/credentials.template.md ~/.config/claude/credentials.md`
5. Edit the catalog: replace `<VAULT>` with your real vault name (`op vault list`). Smoke-test a
   ref: `op read 'op://<VAULT>/OpenAI/credential'`.
6. In a Claude session: `/load-creds OPENAI_API_KEY` → produces a gitignored `.env` with the key.

Multi-account: if `op account list` shows >1, `/load-creds` threads `--account` through every
call. Platform: POSIX shell + `op`; tested on macOS, works on Linux; Windows needs WSL/git-bash.

---

## Troubleshooting

| Problem | Fix |
|---|---|
| Broken symlinks after moving dotfiles | Re-run Step 3 with the correct path |
| `gh auth` fails on new device | `gh auth login` |
| SessionStart hook fails silently | Confirm `~/.claude/settings.json` has the Step 4 hooks |
| `/` commands not showing | `ls -la ~/.claude/commands` — fix the symlink |
| Git pull conflicts | `cd ~/.claude-dotfiles && git stash && git pull && git stash pop` |
| Plugin install fails | `npm cache clean --force`, retry |
| `/load-creds` "not signed in" | Enable 1Password CLI integration, OR set `OP_SERVICE_ACCOUNT_TOKEN`, OR `eval $(op signin)` |
| `op inject` fails on a ref | `op read 'op://...'` — vault name probably differs; `op vault list` |
| Push blocked: "possible secret detected" | Pre-push scan found a real-looking secret — remove it, rotate, rerun |
| `/load-creds` aborts: ".env tracked by git" | `git rm --cached .env && git commit -m 'untrack .env'`, rerun |
| SessionStart warns about secret in catalog | A real secret got pasted in — replace with `op://` ref and **rotate immediately** |

---

For how everything wires together (load order, sync flow, credential flow, skill routing):
[`ARCHITECTURE.md`](ARCHITECTURE.md). For the full ~80-command reference: [`COMMANDS.md`](COMMANDS.md).
