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
| `/afk [hours]` | Fire-and-forget unattended review. Walks-away mode: surveys repo, packs tasks by complexity weight, ticks via `ScheduleWakeup` for the requested duration. Default 3h, `0` = infinite (stops on `STOP` sentinel). Single-agent Opus 4.7 medium effort. Auto-fixes only on 100%-confidence purely-additive changes. Output to `<git_root>/tmp/afk/<session>/`. |
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
| `/load-creds` | Inject API keys from 1Password into the project's `.env` via `op inject`. Reads the catalog at `~/.config/claude/credentials.md` (local-only, never synced). |

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
├── credentials.template.md # Template for the 1Password catalog. Real catalog lives at ~/.config/claude/credentials.md (local-only, gitignored)
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
            "command": "cd ~/.claude-dotfiles && git pull --ff-only 2>/dev/null; if [ -f ~/.config/claude/credentials.md ] && grep -nIE '(sk-(ant|proj|svcacct)?-?[A-Za-z0-9_-]{20,}|AIza[0-9A-Za-z_-]{35}|ghp_[A-Za-z0-9]{36,}|gho_[A-Za-z0-9]{36,}|ghu_[A-Za-z0-9]{36,}|ghs_[A-Za-z0-9]{36,}|ghr_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{40,}|AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}|xox[abposr]-[A-Za-z0-9-]{10,}|hf_[A-Za-z0-9]{30,}|ya29\\.[A-Za-z0-9_-]{20,}|whsec_[A-Za-z0-9]{20,}|(rk|sk|pk)_(live|test)_[A-Za-z0-9]{20,}|-----BEGIN +(RSA +|OPENSSH +)?PRIVATE +KEY-----)' ~/.config/claude/credentials.md 2>/dev/null; then echo 'WARNING: possible secret value in ~/.config/claude/credentials.md — should be op:// references only. Rotate the leaked secret.' >&2; fi; true",
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
- `SessionStart`: Auto-pulls latest dotfiles when you start a Claude session, then runs a non-blocking secret-leak check against `~/.config/claude/credentials.md` (sk-/sk-ant-/sk-proj-/AKIA/AIza/ghp_/gho_/ghs_/github_pat_/xox[abposr]-/hf_/ya29./whsec_/rk_live_/sk_live_/PEM blocks). The PostToolUse sync script does a stricter scan that **blocks** the push entirely if a real secret is detected anywhere in the dotfiles tree.
- `PostToolUse` (Edit|Write): Auto-pushes dotfiles changes after any file edit. Runs a hard pre-push secret scan first; on any match, the push is blocked (exit 2) and the user is told to rotate.

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

The `/load-creds` slash command + a 1Password catalog let any Claude session inject API keys into a project's `.env` without copy/paste. **Real secret values never live in this synced repo** — the catalog (which contains only `op://` references) lives outside the repo at a local path, and a regex-based pre-push guard blocks commits whose contents match common API-key/PEM shapes. The guard is best-effort: novel or obfuscated secret formats can still slip through, so don't paste raw secrets anywhere in `~/.claude-dotfiles/`.

**Architecture:**
- **Real secrets** live in your 1Password vault (encrypted, biometric-unlock).
- **The catalog** lives at `~/.config/claude/credentials.md` — **local-only, never synced via git**, never pushed anywhere. Maps env var names → `op://` references.
- **The template** at `~/.claude-dotfiles/credentials.template.md` (in this synced repo) is a reference — copy it to the local path on a fresh machine and edit.
- `/load-creds` writes a temporary `.env.op` (op://-references file, gitignored), runs `op inject` to a temp file, verifies no `op://` strings remain (partial-resolution defense), and **merges** the resolved values into the existing `.env` (preserving manual non-catalog entries). Touch ID prompt fires once.
- **Two layers of leak defense:**
  - Pre-push: `dotfiles-sync.sh` scans staged + untracked files for known secret patterns (sk-/sk-ant-/sk-proj-/AKIA/AIza/ghp_/gho_/ghs_/github_pat_/xox[abposr]-/hf_/ya29./whsec_/(rk|sk|pk)_(live|test)/PEM). On match, the push is **blocked** (exit 2) — never silent.
  - SessionStart: warns (non-blocking) on the same patterns in `~/.config/claude/credentials.md`.
- **Safety in the slash command:** `/load-creds` aborts (not warns) if `.env` or `.env.op` is currently tracked by git, refuses to write through symlinks pointing outside the project, threads `--account` through every `op` call when multiple 1Password accounts are signed in, and `chmod 600`s the resulting `.env`.

**One-time setup on each device:**
1. Install 1Password CLI: `brew install --cask 1password-cli` (macOS) or follow the 1Password CLI install for your OS.
2. Pick an auth mode and enable it:
   - **Desktop app integration** (recommended for interactive use): 1Password app → Settings → Developer → "Integrate with 1Password CLI". Biometric/Touch ID unlock.
   - **Service account token** (non-interactive / CI): export `OP_SERVICE_ACCOUNT_TOKEN`.
   - **`eval $(op signin)`** in your main shell before invoking Claude (only persists in that shell).
3. Verify: `op whoami`.
4. Create your local catalog:
   ```bash
   mkdir -p ~/.config/claude
   cp ~/.claude-dotfiles/credentials.template.md ~/.config/claude/credentials.md
   ```
5. Edit `~/.config/claude/credentials.md`: replace `<VAULT>` placeholders with your real vault name (commonly `Personal`, but `op vault list` will tell you). Verify each ref:
   ```bash
   op vault list
   op item list --vault <VAULT>
   op item get "OpenAI" --format json | jq '.fields[] | {label, id}'
   op read 'op://<VAULT>/OpenAI/credential'   # smoke test
   ```
6. Smoke-test `/load-creds`:
   ```bash
   cd /tmp && mkdir test-creds && cd test-creds && git init
   ```
   Then in a Claude session: `/load-creds OPENAI_API_KEY`. Should produce `.env` with the real key, `.env.op` with the ref, and both gitignored.

**Editing the catalog:** add rows to the appropriate table in `~/.config/claude/credentials.md`. The file is local-only — no auto-sync. Copy your edits to other machines manually (it's small). Never paste real secret values.

**Multi-account 1Password:** if `op account list` shows >1 account, `/load-creds` prompts to pick one and threads `--account <addr>` through every `op` call (or you can export `OP_ACCOUNT`).

**Platform support:** `/load-creds` assumes a POSIX shell + `op`, `awk`, `grep`, `mktemp`, `mv`, `chmod`, `git`. Tested on macOS. Linux works (install `op` per distro, then desktop integration via the 1Password Linux app). Native Windows is not supported without WSL or git-bash.

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
| `/load-creds` says "not signed in" | Open 1Password app → Settings → Developer → enable "Integrate with 1Password CLI", OR export `OP_SERVICE_ACCOUNT_TOKEN`, OR run `eval $(op signin)` in your main shell. |
| `op inject` fails on a specific reference | Verify with `op read 'op://...'`. Vault name probably differs — `op vault list` to confirm, fix `~/.config/claude/credentials.md`. |
| SessionStart warns about secret in catalog | A real secret got pasted into `~/.config/claude/credentials.md`. Replace with `op://` ref and **rotate the leaked secret immediately**. |
| Auto-push blocked with "BLOCKED: possible secret detected" | The pre-push scanner (`dotfiles-sync.sh`) found a real-looking secret in a staged or untracked file. Remove it, rotate the credential, and rerun. |
| `/load-creds` aborts: ".env is currently tracked by git" | Project committed `.env` historically. Fix: `git rm --cached .env && git commit -m 'untrack .env'`, then rerun. |
| Catalog missing on fresh machine | `mkdir -p ~/.config/claude && cp ~/.claude-dotfiles/credentials.template.md ~/.config/claude/credentials.md`, then edit. |
