# Claude Dotfiles — Agent-Directed Setup Guide

## For AI Agents

You are Claude Code, helping set up a Claude Code development environment on a new device. Follow these steps **IN ORDER**. Where you see `[USER INPUT]`, ask the user to provide the value. Do not skip steps. Do not guess values for `[USER INPUT]` markers.

**Important context:** This dotfiles repo auto-syncs across devices. Changes are pulled at session start and pushed automatically after any config modifications. Project code repos are NEVER pushed without explicit user approval — only this dotfiles repo auto-syncs.

---

## What's In This Repo

```
~/.claude-dotfiles/
├── CLAUDE.md               # Global rules (loaded every session)
├── credentials.md          # 1Password-backed API key catalog (op:// refs only, no secrets)
├── commands/               # Slash commands (available as /command-name)
│   ├── load-creds.md       # /load-creds — inject 1Password creds into a project's .env
│   ├── *.md                # Core commands (plan, commit, investigate, etc.)
│   ├── parsa/              # Partner commands (review, linter, refactor, cl/)
│   └── plan2bid/           # Construction estimation suite
├── agents/                 # Custom sub-agents (plan-reviewer, implementer, etc.)
├── rules/                  # Global rules applied to all projects
├── patterns/               # Learned behavioral patterns (populated by /learn)
│   └── INDEX.md            # Pattern index with confidence scores
├── docs/                   # Long-form docs for individual commands
│   └── transcribe.md       # /transcribe setup and usage
├── scripts/
│   ├── dotfiles-sync.sh    # Auto-push script for PostToolUse hook
│   └── whisper-transcribe.sh  # Audio → text via OpenAI Whisper (used by /transcribe)
├── .env.example            # Template for .env (API keys used by commands)
└── .env                    # Your API keys (gitignored, never committed)
```

---

## Prerequisites

Before starting, verify each of these:

```bash
# 1. Claude Code CLI is installed
claude --version

# 2. GitHub CLI is installed and authenticated
gh auth status

# 3. Git is configured
git config user.name
git config user.email
```

If git is not configured, ask the user for their name and email, then:
```bash
git config --global user.name "[USER INPUT: full name]"
git config --global user.email "[USER INPUT: email]"
```

---

## Step 1: Clone This Repo

```bash
git clone https://github.com/nkpardon8-prog/claude-dotfiles.git "$HOME/.claude-dotfiles"
```

**Verify:**
```bash
ls "$HOME/.claude-dotfiles/CLAUDE.md"
```
Should show the file. If not, check `gh auth status`.

---

## Step 2: Make Sync Script Executable

```bash
chmod +x "$HOME/.claude-dotfiles/scripts/dotfiles-sync.sh"
```

---

## Step 3: Create Symlinks

First, check that none of these targets already exist:
```bash
ls -la "$HOME/.claude/CLAUDE.md" "$HOME/.claude/commands" "$HOME/.claude/agents" "$HOME/.claude/rules" "$HOME/.claude/patterns" 2>/dev/null
```

If any exist, ask the user: "These already exist — safe to replace them with symlinks to your dotfiles?" If yes:

```bash
# Remove existing targets (if any)
rm -f "$HOME/.claude/CLAUDE.md" 2>/dev/null
rm -rf "$HOME/.claude/commands" 2>/dev/null
rm -rf "$HOME/.claude/agents" 2>/dev/null
rm -rf "$HOME/.claude/rules" 2>/dev/null
rm -rf "$HOME/.claude/patterns" 2>/dev/null

# Create symlinks
ln -sf "$HOME/.claude-dotfiles/CLAUDE.md" "$HOME/.claude/CLAUDE.md"
ln -sf "$HOME/.claude-dotfiles/commands" "$HOME/.claude/commands"
ln -sf "$HOME/.claude-dotfiles/agents" "$HOME/.claude/agents"
ln -sf "$HOME/.claude-dotfiles/rules" "$HOME/.claude/rules"
ln -sf "$HOME/.claude-dotfiles/patterns" "$HOME/.claude/patterns"
```

**Verify:**
```bash
ls -la "$HOME/.claude/commands"
# Should show: commands -> /Users/[user]/.claude-dotfiles/commands

ls -la "$HOME/.claude/agents"
# Should show: agents -> /Users/[user]/.claude-dotfiles/agents
```

---

## Step 4: Configure Auto-Sync in settings.json

Read `~/.claude/settings.json`. If it doesn't exist, create it. Merge the following hooks with any existing content:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "cd ~/.claude-dotfiles && git pull --ff-only 2>/dev/null; if grep -nE '(sk-[A-Za-z0-9]{20,}|AIza[0-9A-Za-z_-]{35}|eyJ[A-Za-z0-9_-]{20,}\\.[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+)' ~/.claude-dotfiles/credentials.md 2>/dev/null; then echo 'WARNING: possible secret value detected in credentials.md - should be op:// references only' >&2; fi; true",
            "timeout": 10,
            "statusMessage": "Syncing dotfiles..."
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Edit|Write",
        "hooks": [
          {
            "type": "command",
            "command": "$HOME/.claude-dotfiles/scripts/dotfiles-sync.sh",
            "async": true
          }
        ]
      }
    ]
  }
}
```

**What the hooks do:**
- `SessionStart`: Auto-pulls latest dotfiles when you start a Claude session, then runs a non-blocking secret-leak check against `credentials.md` (catches accidental `sk-*`, `AIza*`, full JWTs).
- `PostToolUse` (Edit|Write): Auto-pushes dotfiles changes after any file edit (the script checks if the edited file is in the dotfiles dir)

---

## Step 5: Install Plugins (Optional)

Run each of these. The user can skip any they don't want:

```bash
claude plugin install agent-sdk-dev
claude plugin install claude-code-setup
claude plugin install claude-md-management
claude plugin install code-review
claude plugin install code-simplifier
claude plugin install commit-commands
claude plugin install feature-dev
claude plugin install hookify
claude plugin install learning-output-style
claude plugin install playground
claude plugin install pr-review-toolkit
claude plugin install security-guidance
claude plugin install skill-creator
```

Ask the user: "Want to install all of these, or skip some?"

---

## Step 6: Configure MCP Servers (Per-Project)

For each project, create a `.mcp.json` file in the project root. Template:

```json
{
  "mcpServers": {
    "supabase": {
      "command": "npx",
      "args": ["-y", "@supabase/mcp-server-supabase@latest", "--access-token", "[USER INPUT: Supabase personal access token]"],
      "type": "stdio"
    },
    "apollo": {
      "command": "npx",
      "args": ["-y", "@thevgergroup/apollo-io-mcp@latest"],
      "type": "stdio",
      "env": { "APOLLO_API_KEY": "[USER INPUT: Apollo API key]" }
    },
    "resend": {
      "command": "npx",
      "args": ["-y", "resend-mcp"],
      "type": "stdio",
      "env": { "RESEND_API_KEY": "[USER INPUT: Resend API key]" }
    },
    "netlify": {
      "command": "npx",
      "args": ["-y", "@netlify/mcp"],
      "type": "stdio",
      "env": { "NETLIFY_AUTH_TOKEN": "[USER INPUT: Netlify personal access token]" }
    },
    "cloudflare": {
      "command": "npx",
      "args": ["-y", "@cloudflare/mcp-server-cloudflare"],
      "type": "stdio",
      "env": { "CLOUDFLARE_API_TOKEN": "[USER INPUT: Cloudflare API token]" }
    }
  }
}
```

**IMPORTANT:** `.mcp.json` is per-project and contains API keys — it is NOT synced via dotfiles. Each project on each device needs its own `.mcp.json`.

---

## Step 7: Add Shell Aliases (Optional)

Append to `~/.zshrc` (or `~/.bashrc` if using bash):

```bash
# Claude Code model shortcuts
alias cco='claude --model opus'
alias ccs='claude --model sonnet'
alias ccp='claude --model opusplan'
alias cch='claude --model haiku'
```

Then reload:
```bash
source ~/.zshrc
```

---

## Step 8: Verify Everything

Run these checks:

```bash
# 1. Symlinks are correct
echo "=== Symlinks ==="
ls -la "$HOME/.claude/CLAUDE.md"
ls -la "$HOME/.claude/commands"
ls -la "$HOME/.claude/agents"
ls -la "$HOME/.claude/rules"
ls -la "$HOME/.claude/patterns"

# 2. Shell aliases work (if configured)
echo "=== Aliases ==="
source ~/.zshrc 2>/dev/null
which cco ccs ccp cch 2>/dev/null && echo "Aliases OK" || echo "Aliases not found (optional)"

# 3. Settings hook exists
echo "=== Hooks ==="
cat "$HOME/.claude/settings.json" | grep -c "SessionStart" && echo "SessionStart hook OK"

# 4. Sync script is executable
echo "=== Sync Script ==="
test -x "$HOME/.claude-dotfiles/scripts/dotfiles-sync.sh" && echo "Sync script OK" || echo "Sync script not executable"
```

Then start a Claude Code session and verify:
- Global rules load (CLAUDE.md content should be in context)
- Slash commands are available (type `/` to see the list)

---

## Command Reference

### Core Commands

| Command | Purpose |
|---------|---------|
| `/plan` | Create implementation plans with codebase + web research |
| `/simple-plan` | Quick gut-check plan before implementing |
| `/implement` | Execute an approved plan via parallel sub-agents |
| `/investigate` | Hypothesis-driven bug root cause analysis |
| `/commit` | Selective git commit (only session-related changes) |
| `/prepare-pr` | Commit, rebase, build, and create/update a PR |
| `/discussion` | Interactive discussion about approach/features |
| `/research-web` | Web research with validated references |
| `/learn` | Extract behavioral patterns from the session |
| `/architect` | Interactive project documentation scaffolding |
| `/verify` | Full build/typecheck/lint/test/security pipeline |
| `/checkpoint` | Named git snapshot for safe rollback |
| `/tdd` | RED/GREEN/REFACTOR test-driven development |
| `/plan_base` | Base plan template |
| `/skillset` | Industry skill registry manager |
| `/buildskill` | Design and build new industry-specific commands |
| `/transcribe` | Transcribe audio (Voice Memos, calls) via OpenAI Whisper + project-aware report — see [docs/transcribe.md](docs/transcribe.md) |
| `/load-creds` | Inject API keys from 1Password into a project's `.env` via `op inject`. Reads `~/.claude-dotfiles/credentials.md` catalog. |

### Industry-Specific Commands

| Command | Purpose |
|---------|---------|
| `/plan2bid` | Construction estimation orchestrator |
| `/plan2bid:run` | Full estimation pipeline (docs to estimate) |
| `/plan2bid:doc-reader` | Analyze construction PDFs and blueprints |
| `/plan2bid:rag` | Semantic search across construction docs |
| `/plan2bid:scope` | Scope boundary analysis per trade |
| `/plan2bid:compare` | Side-by-side estimate comparison |
| `/plan2bid:grade` | Grade estimate against human reference |
| `/plan2bid:price-check` | Verify material pricing against web sources |
| `/plan2bid:pricing-profile` | Manage labor rates, markups, vendor prefs |
| `/plan2bid:scenarios` | What-if scenario generator |
| `/plan2bid:validate` | Pre-flight validation for estimation |
| `/plan2bid:pdf` | Export estimate to professional PDF |
| `/plan2bid:excel` | Export estimate to styled Excel workbook |
| `/plan2bid:reverse-engineer` | Reverse-engineer estimator methodology |
| `/crm` | CRM agent (leads, emails, campaigns, Apollo) |
| `/netlifydeploy` | One-shot Netlify deployment |
| `/dock` | Molecular docking job |
| `/screen` | Virtual screening campaign |
| `/optimize` | Optimize docking hits via MolMIM AI |
| `/admet` | ADMET/drug-likeness analysis |
| `/dashboard` | Launch MoleCopilot web dashboard |
| `/prep-target` | Prepare protein target for docking |

### Partner Commands (parsa/)

| Command | Purpose |
|---------|---------|
| `/parsa:simple-plan` | Quick plan |
| `/parsa:implement-plan` | Execute plan from file |
| `/parsa:review-plan` | Review plan for gaps and simplification |
| `/parsa:fix-bug` | Systematic debugging with hypothesis-driven logging |
| `/parsa:create-prp` | Create PRP |
| `/parsa:review-prp` | Review PRP |
| `/parsa:review:all` | Comprehensive 11-principle code review |
| `/parsa:linter:codebase` | Fix all TS type errors + ESLint warnings |
| `/parsa:linter:local-changes` | Fix lint in changed files only |
| `/parsa:linter:commit` | Commit |
| `/parsa:refactor:simple` | Simple refactor |
| `/parsa:refactor:medium` | Medium refactor |
| `/parsa:refactor:deep` | Deep refactor |
| `/parsa:cl:create_plan` | Implementation plan |
| `/parsa:cl:implement_plan` | Execute plan |
| `/parsa:cl:commit` | Git commit |
| `/parsa:cl:research_web` | Web research |
| `/parsa:cl:research_codebase` | Codebase research |

## Agent Reference

| Agent | Purpose |
|-------|---------|
| `codebase-explorer` | Read-only agent for exploring and understanding codebases |
| `implementation-reviewer` | Reviews completed implementation against the original plan |
| `implementer` | Executes implementation plans by writing code changes |
| `plan-reviewer` | Reviews plans for gaps, risks, and feasibility |
| `researcher` | Performs web and codebase research |

---

## Auto-Sync Behavior

| Event | Action |
|-------|--------|
| **Session starts** | `git pull` latest dotfiles (SessionStart hook) |
| **Any file in dotfiles is edited** | `git add + commit + push` (PostToolUse hook via sync script) |
| **`/learn` runs** | Saves patterns then pushes (built into the command) |
| **Manual changes** | Run `cd ~/.claude-dotfiles && git add -A && git commit -m "update" && git push` |

On other devices, changes appear at next session start (auto-pull).

---

## Adding New Commands, Agents, or Rules

**Adding a new command:** Create `~/.claude-dotfiles/commands/[name].md` — it becomes `/[name]` globally. The sync script auto-pushes.

**Adding a new agent:** Create `~/.claude-dotfiles/agents/[name].md` — it becomes available as a sub-agent type globally. Auto-pushed.

**Adding a new rule:** Create `~/.claude-dotfiles/rules/[name].md` — it applies to all projects. Auto-pushed.

**Editing CLAUDE.md:** Edit `~/.claude-dotfiles/CLAUDE.md` (the symlink target). Auto-pushed.

**Subdirectory commands:** Commands in subdirectories (e.g., `parsa/fix-bug.md`) are available as `/parsa:fix-bug`. The directory name becomes a namespace prefix.

**On other devices:** Changes auto-pull at next session start.

---

## What Each Core File Does

| File | Purpose |
|------|---------|
| `CLAUDE.md` | Global rules: doc discipline, test before done, push policies, credential handling (1Password-backed via `/load-creds`), Skill Routing table, MCP catalog, FRAIM lifecycle, MoleCopilot context |
| `credentials.md` | 1Password CLI catalog. Maps env var names → `op://` references. Read by `/load-creds`. **Never contains real secret values** — only references. |
| `commands/learn.md` | Extract behavioral patterns from session, auto-push to this repo |
| `commands/architect.md` | Interactive project doc scaffolding (three-tier: hot/warm/cold) |
| `commands/verify.md` | Build/typecheck/lint/test/security pipeline with hard gates |
| `commands/checkpoint.md` | Named git snapshots for safe rollback |
| `commands/tdd.md` | RED/GREEN/REFACTOR test-driven development cycle |
| `rules/backend-patterns.md` | Global rules: repository pattern, N+1 prevention, service layers, error handling |
| `patterns/INDEX.md` | Index of all learned patterns with confidence scores |
| `scripts/dotfiles-sync.sh` | Auto-push script called by PostToolUse hook when dotfiles change |

---

## Credentials System (1Password-backed)

The `credentials.md` catalog + `/load-creds` slash command let any Claude session inject API keys into a project's `.env` without copy/paste, while keeping zero secrets at rest in this repo.

**How it works:**
1. Real secrets live in 1Password (encrypted, biometric-unlock).
2. `~/.claude-dotfiles/credentials.md` is a non-secret catalog: env var name → `op://` reference (e.g. `OPENAI_API_KEY → op://<VAULT>/OpenAI/credential`). Synced via this dotfiles repo.
3. `/load-creds` (or its flow): writes `.env.op` containing the references, then runs `op inject -i .env.op -o .env` to materialize the real `.env`. May trigger a Touch ID prompt.
4. Both `.env` and `.env.op` get added to `.gitignore` *before* injection.
5. The `SessionStart` hook scans `credentials.md` for accidentally-pasted real secrets and warns (non-blocking).

**One-time setup on each device:**
1. Install: `brew install --cask 1password-cli` (or use the 1Password desktop app).
2. Open 1Password → **Settings → Developer → "Integrate with 1Password CLI"**. This enables Touch ID unlock for `op` commands. `op signin` (eval-based) does NOT persist into slash-command shells, so desktop integration is required.
3. Verify: `op whoami` should return your account info.
4. Edit `credentials.md` and replace placeholder `op://<VAULT>/...` paths with real ones from your vault. Discover paths with:
   ```bash
   op item list --vault <VAULT>
   op item get "OpenAI" --format json | jq '.fields[] | {label, id}'
   ```
   Verify a ref with: `op read 'op://<VAULT>/OpenAI/credential'`.

**Editing the catalog:** add a row to the appropriate table in `credentials.md`. The file auto-syncs via the dotfiles push hook. Never paste real secret values — only `op://` references and human-readable names.

**Multi-account:** if `op account list` shows >1 account, `/load-creds` prompts to pick one and uses `--account <shorthand>`.

---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| Broken symlinks after moving dotfiles | Re-run Step 3 symlink commands with correct path |
| `gh auth` fails on new device | Run `gh auth login` and follow prompts |
| SessionStart hook fails silently | Check `~/.claude/settings.json` has the hooks config from Step 4 |
| `/` commands not showing | Verify `~/.claude/commands` symlink: `ls -la ~/.claude/commands` |
| Git pull conflicts | `cd ~/.claude-dotfiles && git stash && git pull && git stash pop` |
| Sync script not running | Check it's executable: `chmod +x ~/.claude-dotfiles/scripts/dotfiles-sync.sh` |
| Plugin install fails | `npm cache clean --force` then retry |
| `/load-creds` says "not signed in" | Open 1Password app → Settings → Developer → enable "Integrate with 1Password CLI" |
| `op inject` fails on a specific reference | Verify with `op read 'op://...'`. Likely the catalog ref doesn't match your vault's actual item/field names — fix in `credentials.md`. |
| SessionStart warns about secret in `credentials.md` | A real secret value got pasted in. Replace with the `op://` reference and rotate the leaked key. |
