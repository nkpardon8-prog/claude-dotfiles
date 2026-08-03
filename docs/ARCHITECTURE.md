# Architecture

How `~/.claude-dotfiles` plugs into Claude Code, and what runs when.

---

## On disk

```
~/.claude-dotfiles/                        ← this repo, version-controlled
├── CLAUDE.md                              ← global rules (loaded every session)
├── credentials.template.md                ← template for the op:// catalog (the real
│                                             catalog is local-only, see "Credential flow")
├── settings.json.template                 ← reference copy of ~/.claude/settings.json
├── CHANGELOG.md
├── commands/                              ← slash commands → /name
│   ├── *.md                               (top-level: /plan, /implement, ...)
│   └── god-review/  database-audit/  ui-audit/  desktop/  macmini/  windows/
│                                          (namespaced suites: /<ns>:*)
├── agents/                                ← sub-agents spawned by skills
├── rules/                                 ← global rule files
├── skills/                                ← non-command skill assets (_shared/, desktop/, ...)
├── templates/                             ← CLAUDE.md / AGENTS.md scaffolds for new projects
├── codex/                                 ← generated Codex-CLI layer (codex/generated/)
├── docs/                                  ← long-form docs (this folder)
├── archive/                               ← retired packs + write-ups, not loaded by Claude Code
├── scripts/
│   ├── dotfiles-sync.sh                   (auto-push on edit)
│   ├── statusline.sh                      (statusline renderer)
│   ├── secret-scan.sh                     (pre-commit / sync secret gate)
│   ├── clean-dead-processes.sh            (RAM cleanup, cron 2-day)
│   ├── whisper-transcribe.sh              (used by /transcribe)
│   ├── hooks/                             (lifecycle hooks - see scripts/hooks/README.md)
│   ├── progress/on-session-start-cleanup.sh
│   ├── lint-commands/                     (skill size + contract lints)
│   └── *-assumptions/                     (hermetic assumption suites, bash run-all.sh)
├── .env / .env.example                    (Whisper key, etc.)
└── .gitignore
```

`~/.claude/` is the runtime location Claude Code reads. It's wired to this repo via symlinks:

```
~/.claude/CLAUDE.md             →   ~/.claude-dotfiles/CLAUDE.md
~/.claude/commands              →   ~/.claude-dotfiles/commands
~/.claude/agents                →   ~/.claude-dotfiles/agents
~/.claude/rules                 →   ~/.claude-dotfiles/rules
~/.claude/statusline.sh         →   ~/.claude-dotfiles/scripts/statusline.sh
~/.claude/refresh-ratelimit.sh  →   ~/.claude-dotfiles/scripts/refresh-ratelimit.sh
```

Edit a file in `~/.claude-dotfiles/`, the change is live in the next session — no copy step.

---

## Sync flow (multi-device)

```
┌──────────────┐         git pull --ff-only          ┌──────────────┐
│  GitHub      │ ──────────────────────────────────▶ │  Device A    │
│  origin/main │                                     │  ~/.claude-  │
│              │ ◀────────────────────────────────── │  dotfiles    │
└──────────────┘         git push (auto)             └──────────────┘
       ▲                                                     │
       │                                                     │ user edits
       │                                                     ▼ a file
       │                                              ┌──────────────┐
       │                                              │ PostToolUse  │
       │                                              │ hook fires   │
       │                                              │ sync script  │
       │                                              └──────┬───────┘
       │                                                     │
       └─────────────────────────────────────────────────────┘
                          push to origin/main
```

Two hooks in `~/.claude/settings.json` make this happen:

| Hook | Trigger | Action |
|---|---|---|
| `SessionStart` | New Claude Code session | `git pull --ff-only`, reinstall the local git hooks, and secret-leak scan `~/.config/claude/credentials.md` (warn-only; it should hold `op://` references, never values) |
| `PostToolUse` (Edit\|Write) | Any file edit | Run `scripts/dotfiles-sync.sh` — checks if the edit was inside the dotfiles dir, then `git add + commit + push` |

Project repos are **not** auto-pushed. Only this dotfiles repo. The rule lives in `CLAUDE.md` and the script checks the path before pushing.

### Other lifecycle hooks

Full inventory (what is registered, what each one does, and which are invoked by skills rather
than by an event) lives in `scripts/hooks/README.md`; `settings.json.template` is the reference
copy of the actual registration. The load-bearing ones:

| Hook | Script | Purpose |
|---|---|---|
| `Stop` | `scripts/hooks/auto-compact-after-pre-compact.sh` | Fires `/compact` into the originating Terminal tab when `/pre-compact` armed it (per-session JSON sentinel under `~/.claude/progress/`). Mac/Terminal.app only. Triggered by `/pre-compact` — see [COMMANDS.md](COMMANDS.md) and `scripts/hooks/README.md`. |
| `SessionStart` (cleanup entry) | `scripts/progress/on-session-start-cleanup.sh` | Prunes stale progress files, stale auto-compact / pre-compact sentinels (>12h), and `codex-review.*` run dirs under `$TMPDIR` (>24h - they now outlive the skill so `/mission` can read `report-final.md`). Also sweeps abandoned parallelizer waves (>7d): dead wave-state files, plus orphaned `~/.claude/wave-worktrees/` dirs that no state file references - removing the tree, then `git worktree prune` + `branch -D` in the repo named by that dir's `.repo-root` breadcrumb. Finally runs `scripts/parallel-stats.py --replay` at most weekly (completion-marker throttled, 45s `pt_run` cap, 10 newest transcripts, tmp->mv) into `~/.claude/parallel-waves/replay-latest.txt`. `rework.log` and replay outputs are never swept. Every step is fail-open. |
| `SessionStart` (primer) | `scripts/hooks/post-compact-primer.sh` | Source-routing primer for `compact`/`resume`/`startup`/`clear`: resolves the pending SID-tagged handoff and emits session-start navigation. Followed by `stale-handoff-guard.sh`, which quarantines an un-tagged `CLAUDE.local.md` so an old handoff cannot be silently re-ingested. |
| `UserPromptSubmit` | `scripts/hooks/ctx-gate-on-prompt-submit.sh` | Three-tier context-budget nudge off the statusline's `~/.claude/progress/ctx-<sid>.txt` sidecar. `dotfiles-sync-pause-notice.sh` runs alongside it to surface a held or blocked auto-sync (the sync itself is async, so its stderr reaches nobody). |
| `PreCompact` (matcher `auto`) | `scripts/hooks/ctx-gate-precompact-safety.sh` | Last-resort net when native auto-compaction is about to fire without a handoff. |
| `PreToolUse` | `scripts/hooks/prod-coordination-gate.py` | Serializes prod-mutating ops across parallel Claude instances via `~/.claude/prod.lock`. |
| `SessionStart` + `PostToolUse` | `scripts/hooks/prod-ledger.py` (`inject` / `record`) | Shared ledger of prod-facing actions (push / deploy / migrate) so parallel agents know what is already live. |

Auto-compact is the `Stop` hook that crosses the Claude/Terminal boundary. (Statusline line 2 is now a manual `/line` label set per window — there are no progress-bar hooks; see [STATUSLINE.md](STATUSLINE.md).)

---

## What loads when

```
┌────────────────────────────────────────────────────────────────────┐
│  Claude Code session starts                                        │
└────────────────────────────────────────────────────────────────────┘
   │
   ├─▶ SessionStart hook: git pull dotfiles
   │
   ├─▶ Loads global rules:
   │     • ~/.claude/CLAUDE.md  (→ dotfiles CLAUDE.md)
   │     • ~/.claude-dotfiles/rules/*.md
   │
   ├─▶ Discovers slash commands from:
   │     • ~/.claude/commands/*.md           → /name
   │     • ~/.claude/commands/<ns>/*.md       → /<ns>:name
   │
   ├─▶ Discovers sub-agents from ~/.claude/agents/
   │
   ├─▶ Loads project memory:
   │     ~/.claude/projects/<project>/memory/MEMORY.md
   │
   └─▶ Resolves the SID-tagged handoff CLAUDE.local.<session_id>.md
       ← written by /pre-compact at the repo's canonical anchor; the primer
         probes cwd → show-toplevel → canonical anchor and accepts only a
         file whose END-OF-HANDOFF marker sid= matches this session (no @import)
```

---

## Skill routing

A command is invoked by typing `/name` (or `/<ns>:name` for a pack). Claude Code discovers them
from `~/.claude/commands/`, so a new `commands/foo.md` is live in the next session with no
registration step.

There is no central trigger table. Routing to a skill without an explicit `/` invocation is
driven by prose rules in `CLAUDE.md` - e.g. the Pre-Compaction Handoffs rule mandates
`/pre-compact`, the GUI Fallback rule mandates `/desktop`, the Credentials rule mandates
`/load-creds`. A skill that owns sub-commands (`/god-review`, `/database-audit`, `/ui-audit`)
triggers them internally from its own pack directory.

`docs/COMMANDS.md` is the human-facing catalog of what exists.

---

## Credential flow

```
┌─────────────────┐      catalog (op:// only,     ┌────────────────────────────────┐
│  1Password app  │ ───── no secret values) ─────▶ │ ~/.config/claude/              │
│  (vault)        │                                │   credentials.md               │
└────────┬────────┘                                │ (local-only, NEVER committed)  │
         │                                         └────────┬───────────────────────┘
         │ op inject -i .env.op -o .env                     │ /load-creds
         │ ◀────────────────────────────────────────────────┘ reads catalog
         ▼
┌───────────────────────────┐
│ project/.env (gitignored) │
└───────────────────────────┘
```

Rules:
- The catalog lives **outside this repo**, at `~/.config/claude/credentials.md`. It is local-only and never synced by git; `credentials.md` is gitignored here too. The committed artifact is `credentials.template.md` - copy it to `~/.config/claude/credentials.md` and edit.
- The catalog only ever holds `op://` references and env var names. A SessionStart hook scans it for provider key shapes (`sk-*`, `AIza*`, `ghp_*`, `AKIA*`, private-key headers, ...) and warns if a real value landed there.
- `/load-creds` is the canonical way to populate a project `.env`.
- New credentials shared in chat are treated as compromised: rotate, then store in 1Password and reference as `op://`. Never commit a raw secret to any repo.

Full rules: `CLAUDE.md` → "Credentials". The end-to-end secret chain is documented in [SECURITY-secret-chain.md](SECURITY-secret-chain.md).

---

## Session continuity (`/pre-compact` chain)

When Claude Code's context fills up and triggers compaction, you lose the live conversation. `/pre-compact` writes a structured handoff into a SID-tagged `CLAUDE.local.<session_id>.md` so the next session picks up cleanly.

```
Session 1 ─────┐
   work, work, │   writes CLAUDE.local.<sid>.md (Seq: 1)
   work, /pre- │   ← at the CANONICAL ANCHOR (dirname(git-common-dir)) —
   compact ────┤     identical from every worktree, so cwd-flip never relocates it
                │   resume: primer/step2 probe cwd → show-toplevel → canonical anchor,
                │     accept only if the file's marker sid= matches this session
   /pre-       │   writes CLAUDE.local.<sid>.md (Seq: 2, Parent: <ts of Seq:1>)
   compact ────┤   ← parent = the same-sid file at the anchor (marker-bound, never by mtime)
                │     "Since Last Compact" section diffs prior plan vs reality
Session 3 ─────┘   ...
```

**Parallel-track / concurrency safety:** the handoff filename carries the full session id and lives at
one deterministic per-repo location, so any number of agents — across worktrees, from any cwd — can run
`/pre-compact` concurrently and repeatedly without colliding. Parent selection is bound strictly by
`marker.sid == this session` (never mtime), so a foreign chain's handoff can never be adopted. Every
resolution failure degrades to "refuse / no-handoff," never a wrong-load. The `.gitignore` update is
guarded by an atomic `mkdir` lock under the shared git common dir plus an idempotent converge.

**Overnight autonomy — chain primitives:** each `/pre-compact` ALSO updates per-session chain state
at `~/.claude/chains/<session_id>.{json,log}`. The manifest (slim 9-field JSON, atomic `tmp+rename`)
holds the chain's `started_at`, `current_seq`, `north_star` (the immutable original goal cached
verbatim at chain birth), `last_heartbeat_at`, and `status`. The ledger is append-only TSV — one
line per `/pre-compact` invocation, never overwritten — and survives every compaction so a chain
can read its full forward-progress trail at any link. Every handoff opens with a `## Chain Status`
banner injected by Step 6A from the manifest + last 5 ledger entries (chain id, elapsed time, link
N, north star, current active task, recent progress). The SessionStart primer also prepends a
one-line chain banner to its `additionalContext` advisory. A **narrow** halt-advisory detector
runs over each link's transcript (5+ identical Bash failures with no progress, 2+ permission
denials, self-blocked patterns, repeated API errors) — when it trips, the next handoff opens with
a `## Halt Advisory` block; this is purely informational, the agent has full agency, and the halt
auto-clears on the next user-input turn. **Chain primitives never gate or refuse anything.** A
manifest write failure logs a warning and the skill continues; the SID-tagged handoff is the
load-bearing artifact, chain state is recovery aid. Corrupted manifests auto-rebuild from the
ledger (which carries `north_star_first_120` for goal recovery). See `commands/pre-compact.md` and
`scripts/hooks/lib/handoff-chain.sh` for the full design.

Each `/pre-compact` run mines the conversation at a calibrated depth (Quick / Deep / Chunked) based on size, captures every approach tried (with results and reasons), and validates the output hit a per-pass line floor before it claims done. See `commands/pre-compact.md` for the full skill spec.

---

## Adding things

| What | Where | Naming |
|---|---|---|
| Top-level command | `commands/foo.md` | `/foo` |
| Namespaced command | `commands/<ns>/foo.md` | `/<ns>:foo` |
| Sub-agent | `agents/foo.md` | `subagent_type: "foo"` |
| Global rule | `rules/foo.md` | Loaded on every session |
| Lifecycle hook | `scripts/hooks/foo.sh` + register in `settings.json.template` | See `scripts/hooks/README.md` |

The PostToolUse hook auto-pushes after the edit lands.

---

## Files you should know

| File | Purpose |
|---|---|
| `CLAUDE.md` | The global rules loaded into every session |
| `credentials.template.md` | Template for the local-only `op://` catalog |
| `settings.json.template` | Reference copy of `~/.claude/settings.json` (statusline + every hook registration) |
| `README.md` | Setup-on-a-new-machine guide |
| `docs/COMMANDS.md` | Full command reference (categorized) |
| `docs/ARCHITECTURE.md` | This file |
| `docs/SETUP.md` | Install / bootstrap detail |
| `docs/STATUSLINE.md` | Statusline rendering + the `ctx-<sid>` sidecar |
| `docs/SECURITY-secret-chain.md` | End-to-end secret handling |
| `docs/RATIONALE.md` | Why things are built the way they are |
| `docs/script-reference.md` | Per-script reference for `scripts/` |
| `docs/transcribe.md` | `/transcribe` setup details |
| `scripts/dotfiles-sync.sh` | Auto-push hook script |
| `scripts/hooks/README.md` | Lifecycle hook inventory + contracts |

---

## Push policy summary

| Repo | Policy |
|---|---|
| `~/.claude-dotfiles/` | Auto-push freely (this repo only) |
| Any other repo | NEVER push without explicit approval |

This split is enforced by `CLAUDE.md` and by `dotfiles-sync.sh` (path check before push).
