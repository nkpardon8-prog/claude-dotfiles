# Claude Dotfiles

**A proprietary slash-command operating system for Claude Code.**

~80 commands that web together into a working software-engineering practice: discuss → plan → review → implement → review → verify → commit → ship. Plus full industry suites for construction estimation, drug discovery, UI/UX design, partner-project workflows, and a session-continuity layer that survives context compaction across days.

Years of refining how to get real work done with Claude — distilled into commands that compose. Every workflow below is one slash away.

---

## The flow

```
                  ┌──────────────────────────────────────────────┐
                  │              FEATURE LIFECYCLE                │
                  └──────────────────────────────────────────────┘

   /discussion ──▶ /plan ──▶ /implement ──▶ /verify ──▶ /prepare-pr
       │            │           │             │
       │            │           │             └─▶ /codex-review
       │            │           │                 /master-review
       │            │           │                 /local-review
       │            │           │
       │            │           └─▶ implementer agents (parallel)
       │            │               implementation-reviewer
       │            │
       │            └─▶ plan-reviewer (auto, iterative)
       │
       └─▶ ./tmp/briefs/  ──▶  ./tmp/ready-plans/  ──▶  ./tmp/done-plans/

         At any point: /pre-compact  ─▶  CLAUDE.local.md  ─▶  next session
                       /checkpoint   ─▶  named git tag
                       /learn        ─▶  patterns/  (auto-pushed)
```

Every arrow above is a real command, in this repo, that hands its output to the next stage. Not a diagram of an idea — a diagram of the actual file pipeline.

---

## Commands at a glance

Full reference: **[`docs/COMMANDS.md`](docs/COMMANDS.md)**.

### Build software

| Command | What it does |
|---|---|
| `/discussion` | Conversation-only mode. Researches the codebase, talks through tradeoffs, saves a brief to `./tmp/briefs/`. No code changes. |
| `/plan` | Thorough plan with codebase + web research. Auto-runs plan-reviewer twice and iterates. Saves to `./tmp/ready-plans/`. |
| `/simple-plan` | Lightweight gut-check before doing what the user just asked. |
| `/implement <plan>` | Executes a plan via parallel implementer sub-agents. Auto-runs implementation-reviewer at the end. Moves plan to `./tmp/done-plans/`. |
| `/investigate` | Hypothesis-driven root-cause analysis when something breaks. |
| `/tdd` | RED → GREEN → REFACTOR cycle. |

### Review

| Command | What it does |
|---|---|
| `/codex-review` | Universal review engine. Codex CLI runs 2 specialist passes + 1 verify; Claude Opus runs 4 lens agents (Depth, Breadth, Adversary, Gaps) + meta. Report-only. |
| `/master-review` | Autonomous review + fix loop. 3 Opus + 3 Codex + 2 Antigravity reviewers in parallel; Claude fixes via `/implement`; verification loop until 3 consecutive clean passes. |
| `/local-review` | Offline second opinion via LM Studio (paired with `/toggle-local-review`, `/set-primary-local`, `/hybrid-status`). |
| `/parsa:review:all` | Eleven principle-by-principle review agents in parallel (single-pattern, reuse, scope, clarity, antipatterns, circular-deps, frontend & backend architecture, TanStack Query, self-contained, documentation). |
| `/supabase-audit` | Read-only schema/RLS/security/prod audit. Refuses prod without `--env=prod`. |

### Verify, commit, ship

| Command | What it does |
|---|---|
| `/verify` | Build → typecheck → lint → test → security. Hard-gates each step. |
| `/commit` | Stages and commits only the files related to this session — leaves unrelated edits alone. |
| `/checkpoint <name>` | Named git tag for safe rollback before risky changes. |
| `/prepare-pr` | Commit by-plan, rebase main, build, open or update a PR. |
| `/netlifydeploy` / `/renderdeploy` | One-shot deploys. Confirm-before-deploy. |

### Sessions, memory, docs

| Command | What it does |
|---|---|
| `/pre-compact` | Calibrated handoff before context compaction. Quick/Deep/Chunked mining passes, chain tracking across compactions (`Seq:` + `Parent:`), two-phase write with line floors, "What We Tried" + "Evidence & Data" sections. The single dialed-in tool for session continuity. |
| `/learn` | Extracts behavioral patterns from this session, indexes them in `patterns/INDEX.md`, auto-pushes. |
| `/document` | Audits or bootstraps the project's `docs/` tree. |
| `/architect` | Interactive scaffolding for a new project's three-tier doc system. |

### Research, audio, credentials

| Command | What it does |
|---|---|
| `/research-web` | Web research with validated references and citations. |
| `/transcribe` | Voice memo / call recording → Whisper transcript → project-aware analysis report. ([setup](docs/transcribe.md)) |
| `/load-creds` | Inject API keys from 1Password into the project's `.env` via `op inject`. Reads the catalog at `credentials.md`. |

### Industry suites

| Suite | Top-level | Sub-commands | Purpose |
|---|---|---:|---|
| **plan2bid** | `/plan2bid` | 16 | Full construction estimation: read drawings/specs, extract scope, price labor + materials, scenario analysis, GC-ready PDF/Excel exports. |
| **ui-ux-pro-max** | `/ui-ux-pro-max` | 6 | Design intelligence: brand, design tokens, shadcn/Tailwind UI, Chart.js slides, banners, logos. 161 palettes, 57 font pairings, 25 chart types across 10 stacks. |
| **MoleCopilot** | (no umbrella) | 6 | Drug discovery: docking, virtual screening, ADMET, MolMIM AI optimization, target prep, dashboard. 22 MCP tools. |
| **parsa partner suite** | (namespaced) | ~25 | Mirror of the core flow with `parsa:` namespace — `:create-prp`, `:fix-bug`, `:review:*`, `:linter:*`, `:refactor:*`, `:cl:*`. |
| **FRAIM** | `/fraim` | (MCP) | Job orchestration via the `fraim` MCP server. Discovers and runs phased jobs. |
| **CRM** | `/crm` | — | Leads, deals, emails, campaigns, Apollo prospecting. |

### Toolkit

| Command | What it does |
|---|---|
| `/skillset` / `/buildskill` | Initialize an industry skill registry; build new commands within it. |
| `/antigravity` | Switch Google AI profiles for review loops. |
| `/set-primary-cloud` / `/set-primary-local` | Switch Claude Code routing between Anthropic and LM Studio. |

### Sub-agents (used by skills, not invoked directly)

| Agent | Purpose |
|---|---|
| `plan-reviewer` | Reviews plans for gaps, risks, feasibility |
| `implementer` | Writes code from a plan |
| `implementation-reviewer` | Reviews completed work vs the plan |
| `codebase-explorer` | Read-only repo exploration |
| `researcher` | Web + codebase research |

---

## Why this works

Three properties make these commands more than a pile of prompts:

1. **They web together.** `/discussion` → brief → `/plan` → ready-plan → `/implement` → done-plan → `/prepare-pr` → PR. Each command consumes the previous command's artifact. No manual copy-paste between stages.

2. **They review themselves.** `/plan` runs the plan-reviewer twice automatically. `/implement` runs the implementation-reviewer at the end. `/master-review` loops 3 Opus + 3 Codex + 2 Antigravity reviewers until three consecutive clean passes. Quality is built into the pipeline, not bolted on.

3. **They survive compaction.** `/pre-compact` writes a structured `CLAUDE.local.md` with a `Seq:` chain, a "What We Tried" log, and an "Evidence & Data" section. The next session auto-loads it via `@CLAUDE.local.md`. Multi-day work doesn't lose context.

This is what the dotfiles are. Everything below — symlinks, hooks, sync scripts, credential injection — is plumbing that makes the commands always available, always in sync, always loaded.

For the plumbing details: **[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)**.

For the full command spec, every flag, every sub-command: **[`docs/COMMANDS.md`](docs/COMMANDS.md)**.

---

## Setup on a new machine

The rest of this README is the install guide. It's written for a Claude Code session — paste the README into a fresh session and it'll walk through the steps.

### For AI Agents

You are Claude Code, helping set up a Claude Code development environment on a new device. Follow the steps below **IN ORDER**. Where you see `[USER INPUT]`, ask the user to provide the value. Do not skip steps. Do not guess values for `[USER INPUT]` markers.

**Important context:** This dotfiles repo auto-syncs across devices. Changes are pulled at session start and pushed automatically after any config modifications. Project code repos are NEVER pushed without explicit user approval — only this dotfiles repo auto-syncs.

### What's in this repo

```
~/.claude-dotfiles/
├── CLAUDE.md               # Global rules (loaded every session)
├── credentials.md          # 1Password-backed API key catalog (op:// refs only, no secrets)
├── commands/               # Slash commands (available as /command-name)
│   ├── *.md                # Core commands (plan, implement, investigate, ...)
│   ├── parsa/              # Partner commands  (/parsa:*)
│   ├── plan2bid/           # Construction estimation suite (/plan2bid:*)
│   └── ui-ux-pro-max/      # UI/UX design suite (/ui-ux-pro-max:*)
├── agents/                 # Sub-agents spawned by skills
├── rules/                  # Global rules applied to all projects
├── patterns/               # Learned behavioral patterns (filled by /learn)
│   └── INDEX.md
├── docs/                   # Long-form documentation
│   ├── ARCHITECTURE.md     # How everything wires together
│   ├── COMMANDS.md         # Full slash-command reference
│   └── transcribe.md       # /transcribe setup
├── scripts/
│   ├── dotfiles-sync.sh    # Auto-push hook script
│   ├── clean-dead-processes.sh  # RAM cleanup (cron 2-day)
│   └── whisper-transcribe.sh    # Audio → text (used by /transcribe)
├── .env.example            # Whisper key template
└── .env                    # Your API keys (gitignored)
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

## Auto-Sync Behavior

| Event | Action |
|-------|--------|
| **Session starts** | `git pull` latest dotfiles (SessionStart hook) |
| **Any file in dotfiles is edited** | `git add + commit + push` (PostToolUse hook via sync script) |
| **`/learn` runs** | Saves patterns then pushes (built into the command) |
| **Manual changes** | Run `cd ~/.claude-dotfiles && git add -A && git commit -m "update" && git push` |

On other devices, changes appear at next session start (auto-pull).

---

## Adding new commands, agents, or rules

| To add | Create file at | Becomes |
|---|---|---|
| Command | `commands/foo.md` | `/foo` |
| Namespaced command | `commands/<ns>/foo.md` | `/<ns>:foo` |
| Sub-agent | `agents/foo.md` | `subagent_type: "foo"` |
| Global rule | `rules/foo.md` | Loaded every session |

The PostToolUse hook auto-pushes after the edit lands. On other devices, the change appears at next session start (auto-pull).

If a new command should match natural-language requests, add one row to the Skill Routing table in `CLAUDE.md`.

For deeper architecture (load order, sync flow, credential flow, skill routing): see [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

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
