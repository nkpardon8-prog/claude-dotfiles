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
| `SessionStart` (peer address) | `scripts/hooks/line-reassert-identity.sh` | Re-applies this window's peer address from its `/line` caption on `startup\|resume\|clear\|compact`. The two names a window carries are keyed differently - the caption by `sessionId` (survives a resume), the address under the window's `pid` (re-derived by the harness) - so a resumed window silently reverted to an auto-generated handle. Async, fail-open, no-op when the address is already `nameSource: explicit`. Resolves its session id from the hook's **stdin JSON** like its siblings; each re-assert appends one line to `~/.claude/logs/line-reassert.log` so "it ran and had nothing to do" is distinguishable from "it never ran". |
| `UserPromptSubmit` | `scripts/hooks/ctx-gate-on-prompt-submit.sh` | Three-tier context-budget nudge off the statusline's `~/.claude/progress/ctx-<sid>.txt` sidecar. `dotfiles-sync-pause-notice.sh` runs alongside it to surface a held or blocked auto-sync (the sync itself is async, so its stderr reaches nobody). |
| `PreCompact` (matcher `auto`) | `scripts/hooks/ctx-gate-precompact-safety.sh` | Last-resort net when native auto-compaction is about to fire without a handoff. |
| `SessionStart` (peer replies) | `scripts/hooks/line-replies-notice.sh` | Says how many unread peer replies are waiting in `~/claude-agent-replies/` and how to read them. It exists because the dropbox was write-only in practice - `reply` prints "they have to look" and nothing ever looked, so a filed answer was never read and the sender believed it had communicated. Silent at zero (a hook that speaks every session becomes noise and gets ignored, which is what keeps the sync-pause notice credible). Never prints the reply's content, sender, or filename: hook stdout is injected raw, and peer-authored text may only enter a context through the framed `replies` output. Counts via the `replies-count` verb, which shares one `unread` definition with `replies` so the notice and the inbox cannot disagree. |
| `PreToolUse` | `scripts/hooks/prod-coordination-gate.py` | Serializes prod-mutating ops across parallel Claude instances via `~/.claude/prod.lock`. |
| `PreToolUse` (`Write\|Edit`) | `scripts/hooks/shared-path-overwrite-guard.sh` | Copies a file to `<name>.bak-<UTC minute>` before an agent overwrites it in `~/Downloads`, `~/Desktop`, or `~/Documents`. It is the machine behind `rules/destructive-actions.md`: an agent overwrote another agent's `~/Downloads` draft after two unanswered offers, and the original survived only because the acting agent still held the text in context - silent, and able to recur, which is the bar `rules/verify-by-mechanism.md` sets for machine-enforcing a rule. **Never blocks** - it makes the destruction reversible rather than policing intent, because it sits in front of every `Write` on a machine running ~18 windows. Exempts anything inside a git working tree (version control already keeps the prior version, and guarding there would litter `.bak` files through ordinary repo work), skips `.bak-*` targets so chains cannot form, and fails open on every error. Kill switch: `SHARED_PATH_GUARD_DISABLED=1`. Does NOT cover `Bash` destruction (`rm`, `mv`, `>` redirects) - that needs a different classifier and does not exist. |
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

### Mission continuation-owner invariant (`/mission` never silently stalls)

An autonomous `/mission` is a self-driving loop, so every turn has to leave SOMETHING that will
re-drive it. The **continuation-owner invariant** makes that a hard rule: a `/mission` turn must
not end unless (a) it just called `ScheduleWakeup(...)` as its last continuation-deciding call (only
the tick-lock release may follow) AND that call SUCCEEDED, or (b) it is at a genuine human-handback /
stop point. A **scheduled wake is the ONLY continuation
owner** - a tracked `run_in_background` job is NOT sufficient alone (its completion wake can be
lost), so a turn yielding with a job pending STILL schedules a long fallback heartbeat: the
completion is the fast signal, the heartbeat the backstop. Anything else is a "naked yield" and the
mission freezes. A failed schedule retries then STOPS LOUD (a `pending` + human AWAIT), never silent.

The two wake SIGNALS are both empirically proven: a tracked `run_in_background` Bash re-invokes the
idle agent when it exits, and `ScheduleWakeup` fires a timed re-entry (proven by `commands/afk.md`;
it only fires while Claude Code is OPEN, so cross-close recovery falls back to resume + the
`/pre-compact` chain). Background-completion, a `ScheduleWakeup` tick, and post-compact resume all
funnel into ONE idempotent wake routine: acquire `mkdir tick.lock` (released only if acquired; with
sleep-skew clamps), run the §8 resume-read, hash the current-gen state stream into a cursor (a
`corrupt`/empty cursor STOPS LOUD), select one transition, recompute the cursor before dispatch and
re-enter if it moved (bounded). The real dedup for queued wakes is the **tick-lock serializing +
each wake re-reading current state**; the cursor is the in-turn consistency check, and deterministic
idtags make any re-bank idempotent.

The state that lets a wake tell "work never launched" from "work launched, one lane returned" is
the **AWAIT bookmark** - one durable log line (`[mission] AWAIT … kind=<job|human> … need=<mask>
got=<mask>`) written via `mission-write.sh await` and read via `await-state`. Its identity is
(part,round,attempt,`kind`,`op`) so a job bit never satisfies a human `need` AND two distinct human
decisions (each pd's unique `<seq>-<slug>` op) never share a mask, while both review lanes share
`op=review-barrier` and still join; each lane writes ONLY its own bit and the reader OR-accumulates. When a barrier is short a lane and no tracked job is pending,
the wake routine REPLAYS only the missing lane (gated on a lane-timeout), so correctness never
depends on 100% wake delivery. A banked `phase=review` successor / `VOID` / `PART-DONE` supersedes
its AWAIT; a `kind=human` barrier is resolved by its own `got==need`.

The **no-detach invariant** is the machine backstop for the orphan road: a PreToolUse Bash gate
(`scripts/hooks/no-detach-gate.py`) blocks a shell-detach (`nohup`/trailing-`&`/`disown`/`setsid`)
wrapping a codex launch, because that wrapper exits in ~1s and leaves codex orphaned with no wake.
It FAILS OPEN on any parse error (the harm direction is a false positive wedging Bash) and
documents its known-open bypasses - it catches the common foot-gun, it does not remove discretion.

All of this reuses the existing mission bridge (`scripts/hooks/lib/mission-bridge.sh`) and §8/§H
recovery read rather than adding parallel machinery. The runtime contracts are pinned by the
hermetic `scripts/hooks/mission-continuity-assumptions/` suite. See `commands/mission.md` for the
full loop.

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
