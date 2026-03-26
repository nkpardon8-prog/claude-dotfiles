# Claude Dotfiles — Agent-Directed Setup Guide

## For AI Agents

You are Claude Code, helping Nick set up his Claude Code development environment on a new device. Follow these steps **IN ORDER**. Where you see `[USER INPUT]`, ask the user to provide the value. Do not skip steps. Do not guess values for `[USER INPUT]` markers.

**Important context:** This dotfiles repo auto-syncs across devices. Changes are pulled at session start and pushed automatically after any config modifications. Project code repos are NEVER pushed without explicit user approval — only this dotfiles repo auto-syncs.

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
gh repo clone nkpardon8-prog/claude-dotfiles "$HOME/dotfiles/claude"
```

**Verify:**
```bash
ls "$HOME/dotfiles/claude/CLAUDE.md"
```
Should show the file. If not, check `gh auth status`.

---

## Step 2: Make Sync Script Executable

```bash
chmod +x "$HOME/dotfiles/claude/scripts/dotfiles-sync.sh"
```

---

## Step 3: Create Symlinks

First, check that none of these targets already exist:
```bash
ls -la "$HOME/.claude/CLAUDE.md" "$HOME/.claude/commands" "$HOME/.claude/rules" "$HOME/.claude/patterns" 2>/dev/null
```

If any exist, ask the user: "These already exist — safe to replace them with symlinks to your dotfiles?" If yes:

```bash
# Remove existing targets (if any)
rm -f "$HOME/.claude/CLAUDE.md" 2>/dev/null
rm -rf "$HOME/.claude/commands" 2>/dev/null
rm -rf "$HOME/.claude/rules" 2>/dev/null
rm -rf "$HOME/.claude/patterns" 2>/dev/null

# Create symlinks with absolute paths
ln -sf "$HOME/dotfiles/claude/CLAUDE.md" "$HOME/.claude/CLAUDE.md"
ln -sf "$HOME/dotfiles/claude/commands" "$HOME/.claude/commands"
ln -sf "$HOME/dotfiles/claude/rules" "$HOME/.claude/rules"
ln -sf "$HOME/dotfiles/claude/patterns" "$HOME/.claude/patterns"
```

**Verify:**
```bash
ls -la "$HOME/.claude/CLAUDE.md"
# Should show: CLAUDE.md -> /Users/[user]/dotfiles/claude/CLAUDE.md

ls -la "$HOME/.claude/commands"
# Should show: commands -> /Users/[user]/dotfiles/claude/commands
```

---

## Step 4: Configure settings.json

Read `~/.claude/settings.json`. If it doesn't exist, create it. Ensure it contains these settings (merge with any existing content):

```json
{
  "permissions": {
    "allow": [
      "[USER INPUT: add project-specific file read permissions if needed, or remove this array]"
    ]
  },
  "effortLevel": "high",
  "skipDangerousModePermissionPrompt": true,
  "hooks": {
    "SessionStart": [
      {
        "type": "command",
        "command": "git -C $HOME/dotfiles/claude pull --ff-only 2>/dev/null || true"
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Edit|Write",
        "type": "command",
        "command": "$HOME/dotfiles/claude/scripts/dotfiles-sync.sh"
      }
    ]
  }
}
```

Ask the user: "Do you need any specific file read permissions added? (e.g., paths to other project directories)"

**What the hooks do:**
- `SessionStart`: Auto-pulls latest dotfiles when you start a Claude session
- `PostToolUse` (Edit|Write): Auto-pushes dotfiles changes after any file edit (the script checks if the edited file is in the dotfiles dir)

---

## Step 5: Install Plugins

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

## Step 6: Configure MCP Servers

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

## Step 7: Add Shell Aliases

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

## Step 8: Set Project Model Default (Optional)

For projects where you want auto-routing (Opus for planning, Sonnet for execution), add to the project's `.claude/settings.json`:

```json
{
  "model": "opusplan"
}
```

---

## Step 9: Verify Everything

Run these checks:

```bash
# 1. Symlinks are correct
echo "=== Symlinks ==="
ls -la "$HOME/.claude/CLAUDE.md"
ls -la "$HOME/.claude/commands"
ls -la "$HOME/.claude/rules"
ls -la "$HOME/.claude/patterns"

# 2. Shell aliases work
echo "=== Aliases ==="
source ~/.zshrc 2>/dev/null
which cco ccs ccp cch 2>/dev/null && echo "Aliases OK" || echo "Aliases not found"

# 3. Settings hook exists
echo "=== Hooks ==="
cat "$HOME/.claude/settings.json" | grep -c "SessionStart" && echo "SessionStart hook OK"

# 4. Sync script is executable
echo "=== Sync Script ==="
test -x "$HOME/dotfiles/claude/scripts/dotfiles-sync.sh" && echo "Sync script OK" || echo "Sync script not executable"
```

Then start a Claude Code session and verify:
- Global rules load (CLAUDE.md content should be in context)
- Type `/user:` — you should see: learn, architect, verify, checkpoint, tdd

---

## What Each File Does

| File | Purpose |
|------|---------|
| `CLAUDE.md` | 3 global rules: doc discipline, test before done, push policies (auto for dotfiles, ask for projects) |
| `commands/learn.md` | `/user:learn` — extract behavioral patterns from session, auto-push to this repo |
| `commands/architect.md` | `/user:architect` — interactive project doc scaffolding (three-tier: hot/warm/cold) |
| `commands/verify.md` | `/user:verify` — build→typecheck→lint→test→security pipeline with hard gates |
| `commands/checkpoint.md` | `/user:checkpoint [name]` — named git snapshots for safe rollback |
| `commands/tdd.md` | `/user:tdd [feature]` — RED→GREEN→REFACTOR test-driven development cycle |
| `rules/backend-patterns.md` | Global rules: repository pattern, N+1 prevention, service layers, error handling |
| `patterns/` | Learned behavioral patterns (populated by `/user:learn`, auto-synced) |
| `patterns/INDEX.md` | Index of all learned patterns with confidence scores |
| `scripts/dotfiles-sync.sh` | Auto-push script called by PostToolUse hook when dotfiles change |

---

## Auto-Sync Behavior

This setup auto-syncs in both directions:

| Event | Action |
|-------|--------|
| **Session starts** | `git pull` latest dotfiles (SessionStart hook) |
| **Any file in dotfiles is edited** | `git add + commit + push` (PostToolUse hook via sync script) |
| **`/user:learn` runs** | Saves patterns then pushes (built into the command) |
| **Manual changes** | Run `cd ~/dotfiles/claude && git add -A && git commit -m "update" && git push` |

On the other device, changes appear at next session start (auto-pull).

---

## Updating

**Adding a new command:** Create `~/dotfiles/claude/commands/[name].md` — it becomes `/user:[name]` globally. The sync script auto-pushes.

**Adding a new rule:** Create `~/dotfiles/claude/rules/[name].md` — it applies to all projects. Auto-pushed.

**Editing CLAUDE.md:** Edit `~/dotfiles/claude/CLAUDE.md` (the symlink target). Auto-pushed.

**On other devices:** Changes auto-pull at next session start.

---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| Broken symlinks after moving dotfiles | Re-run Step 3 symlink commands with correct `$HOME` path |
| `gh auth` fails on new device | Run `gh auth login` and follow prompts |
| SessionStart hook fails silently | Check `~/.claude/settings.json` has the hooks config from Step 4 |
| `/user:` commands not showing | Verify `~/.claude/commands` symlink: `ls -la ~/.claude/commands` |
| Git pull conflicts | `cd ~/dotfiles/claude && git stash && git pull && git stash pop` |
| Sync script not running | Check it's executable: `chmod +x ~/dotfiles/claude/scripts/dotfiles-sync.sh` |
| Plugin install fails | `npm cache clean --force` then retry |
| Model alias not recognized | Check `claude --help | grep model` for valid aliases |
