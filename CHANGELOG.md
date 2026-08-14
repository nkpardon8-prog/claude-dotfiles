# Changelog

All notable changes to this Claude Code dotfiles repo. Most recent first.

## 2026-08-14 - /mission can now END a part, and its recorded questions actually get asked

Two overnight autonomous runs made deep but extremely narrow progress at very high cost - one burned
an entire weekly quota to reach part 2 of 9. Slice 0 (2026-08-13) fixed the freezing. This is the rest:
nothing in the playbook could ever decide a part was DONE ENOUGH, and nothing ever brought a recorded
question back to the human.

**The severity floor (§6.0).** BLOCKING is now defined by ENUMERATION - wrong behaviour reaching a
user or a record, data loss, a security or tenant-isolation breach, PHI exposure, a broken operator
path, or a test that can pass while the thing it guards is broken. Everything else is non-blocking.
The obvious tie-break ("if unsure, call it BLOCKING") was tried and abandoned: with seven reviewer
lanes that carry no severity vocabulary, nearly everything reads as unsure, so everything becomes
blocking and the exit stays exactly as unreachable as before.

The load-bearing sentence is one line: **`findings=` on a round line counts BLOCKING findings only.**
That needs no new machinery - the PART-DONE fold in `mission-write.sh` already keys on `findings=0`,
so a round that produced only non-blocking findings banks as dry. Every finding is still recorded
verbatim with its label; the floor changes what GATES a round, never what is written down.

**The cap now does something (§6.1).** "Hard cap 6" was stated three times with no behaviour attached,
which left `dry=2` as the only real exit. It is now **at most 6 rounds that PRODUCE blocking findings,
with the `dry=1 -> dry=2` pair exempt.** Both clauses matter: counting all rounds against 6 makes a
part whose first clean round is round 6 permanently unclosable, because the fold needs two ADJACENT
clean rounds and the cap would forbid the round 7 that finishes it. Hitting the cap PARKS the part
(`pending-stop` -> PushNotification -> `FAIL reason=cap-exhausted-blocking` -> `PART-RETIRED` ->
advance) and never STOPs the mission, which would freeze every part still owed. The `FAIL` carries a
REQUIRED `disposition=reverted|isolated|left-with-recorded-risk` for the defective code left in the
tree, because later parts build on that tree.

**The per-part spend brake (§12.1 step 4b).** 25 wake ticks OR 90 minutes since `PART-START`,
whichever trips first, takes the same park path under `reason=part-over-budget` - a second reason
slug, not a second mechanism. Both thresholds are named settings with defaults. This is the only rule
in the playbook that would have interrupted the eleven-hour single-part run; the review cap would not
have, because that run reached only three rounds.

**The frozen window (§6.2).** Non-blocking findings are never fixed in-part, and once `dry=1` banks,
no code change lands until `dry=2` + live-verify + PART-DONE have. Already machine-enforced - the fold
refuses `convergence-not-machine-clean` on any actionable event ordered after the dry=1 line - and now
pinned by four fixtures so a change to the fold cannot silently make the floor a rubber stamp.

**Alerting.** `PushNotification` on every path that ends or parks work: all four §10 STOP-LOUD paths,
both parks, and the stall detector. An autonomous run exists because the user is asleep; a stop that
only writes to a terminal nobody is watching is a mission that is silently dead until morning. The
`panel-unavailable-3x` message must distinguish quota exhaustion from a Codex outage - one run died of
the former and read as the latter, and they need opposite responses.

**The stall detector now reaches someone.** `mission-liveness.sh` has always sampled the cursor every
armed turn end, but a stalled mission books a wake every tick, so the hook's own check passes and it
stayed silent forever - the exact 11-hour shape. It now drops a `<sid>.stall-alert` marker; §12.1
step 4a reads it, alerts, and clears it. A `Stop` hook cannot reach the model without BLOCKING, which
is wrong for an advisory, so the hand-off is state.

**`mission-pending-reask.sh` (new `UserPromptSubmit` hook).** The away rule is "write the question
down and move on", but nothing implemented the other half. A question recorded at 3am was never
actually asked: the next morning's turn resumed mid-build and never opened the zone. This re-asks on
the one event that means a human is present. Resolves STRICTLY by sid (never cwd, never mtime -
siblings share repos), only for an `active`/`unknown` lifecycle, labels each question BLOCKING vs
non-blocking by cross-referencing the `AWAIT kind=human` marker (the zone line shape alone cannot tell
`pending` from `pending-stop`), frames injected text as untrusted recorded data with a byte cap, ships
the copy-runnable `resolve` command, and throttles to once per session per pd-id-set so an unanswered
question does not nag every prompt while a NEW one fires at once. Silent when there is nothing, and
ALWAYS exits 0 - a hook that can swallow a prompt is worse than a missed question.

**Fan-out is now a mechanism (§6.4)** - one assistant message, multiple Agent calls - because
"parallel, independent" was already written down and a run serialized the panel anyway.

**The contract core stayed at exactly 19500 chars** (its injection budget). Every addition was paid
for by compressing existing core text, including deleting a duplicated verb list that restated the §I
signature table - so the two can no longer drift.

New: `test-mission-doc-drift.sh` (16 checks). Its load-bearing assertions are DOC <-> CODE: where
mission.md claims `mission-write.sh` refuses something, the test greps the actual guard out of
`mission-write.sh`, so prose that quietly becomes a wish goes red. Also `test-mission-pending-reask.sh`
(21 checks, every silence case paired with a firing control) and four severity-floor fixtures in
`test-mission-bridge.sh` (79 -> 83).

**Proof, and what it did NOT prove.** Every new suite was mutation-tested rather than merely run
green. All six re-ask mutants (throttle, lifecycle gate, byte cap, blocking cross-reference, sid
isolation, untrusted framing) were each caught by exactly their intended assertion and nothing else.
All five doc-drift mutants were caught - one only after fixing the counter, which used `grep -c`
(matching LINES) and so let an inline duplicate of the BLOCKING rubric pass. Two findings recorded in
the test file itself rather than papered over: fixture 49b (a `note` between `dry=1` and `dry=2`) is a
STREAM-COMPOSITION guard, not a fold-logic one - a `note` does not enter the stream the fold reads at
all, so it cannot fail for fold reasons today; and fixture 49d is defended by two independent guards,
so only a DOUBLE mutant turns it red (it was run, and it does). Neither is a dead test, but neither
proves what its name alone suggests.

**FIRST REAL-MISSION EVIDENCE, same day.** The caveat above ("none of this has run in a real
mission") is now partly closed. A second live mission window (sid `a7aba834`, the perio-chart tab)
reported both hooks firing, and `~/.claude/logs/mission-liveness.log` corroborates it independently
rather than on that window's word:

```
06:39:54  sid=a7aba834…  NAKED-YIELD action=block life=unknown
06:41:26  sid=a7aba834…  already-blocked action=silent
06:46:09  sid=a7aba834…  wake-booked action=silent
```

Three things that were previously only argued are now observed: the guard blocks a genuine naked
yield in a real mission; the `prompt_id` loop bound stops the SAME prompt being blocked twice (the
unbounded-block-loop a reviewer reproduced 3/3 before the fix); and the mission resumes normally
afterwards. `life=unknown` is the detail that matters most - `unknown` IS the normal state of a
healthy active mission, and the earlier reading that treated it as "not active" would have made this
exact block impossible. Several `human-initiated-turn action=silent` entries in the same window also
confirm the turn-origin check does not fire on a human conversing. `mission-pending-reask.sh` printed
that window's 18 open PENDING DECISIONS on prompt submit, and its throttle marker exists on disk.

**Correction, from the same evidence:** the notice sent to the other windows said a session that
had not restarted would not have loaded the new `UserPromptSubmit` hook. That was WRONG. Two windows
predating the change reported it firing without any restart and without pulling the repo, so Claude
Code re-reads `~/.claude/settings.json` hooks for RUNNING sessions rather than binding them once at
session start. Worth knowing in both directions: a hook edit reaches live windows immediately, which
is convenient for a fix and a hazard for a half-written one. Also observed: a cross-session peer
message counts as a prompt submit, so it can trigger the re-ask.

Still unproven: the severity floor, the cap-park and the spend brake are conducting rules, not hooks -
nothing has yet driven a part to a cap or a budget park in a real run.

## 2026-08-13 (later) - The prod gate stopped confusing a sentence about a deploy with a deploy

`prod-coordination-gate.py` and `prod-ledger.py` classify a Bash command by matching patterns against
its raw TEXT. So a command that merely *carries* a dangerous phrase as data - a commit message, a
heredoc body, a `mission-write.sh` note - was treated as performing the operation.

That is not theoretical. Measured on this machine: **11 of 1344 prod-ledger rows are mission-bridge
note-writes filed as `push` or `migrate`**, across 6 sessions between 2026-06-08 and 2026-08-10, and
two of those note-writes took `~/.claude/prod.lock` - one held it for **2d17h**, during which every
other agent's genuine prod work was refused, because a stale lock is deliberately never auto-reclaimed
and needs a human to reconcile it. The audit trail was wrong in both directions at once: it recorded
prod events that never happened, and it blocked prod events that should have run.

The fix strips what the shell will never execute - quoted string literals and heredoc bodies - before
classification. It stays fail-closed at every edge, leaving the text intact and still scanned when:

- an interpreter-style token is present, where a quoted string genuinely IS code: `bash -c '...'`,
  `sh -lc "..."`, `ssh host '...'`, `psql -c 'ALTER ROLE ...'`, `... | sh`, `eval`, `xargs`,
  any `-c '` / `-e "` / `--command=`;
- the quoted run or heredoc body contains a command substitution (`$(` or a backtick), which executes
  regardless of the quoting;
- the quoting or the heredoc is unbalanced, so nothing can be parsed with confidence.

This does not lower the classifier's ceiling. Text matching was always blind to indirection - write a
script in one call, run it in the next - so the only operations this can newly miss were already
invisible to it.

`kind_of()` in the ledger reads the same stripped text, so a real deploy whose commit message mentions
a push is filed as `deploy` rather than `push`.

The addition sits inside the region the existing drift guard pins byte-identical across both hooks, so
the two copies cannot diverge silently. `test-prod-classifier-fixtures.py` grew from 59 to 86 checks.
Every new check was watched failing before it passed: the false-positive cases go red against the
pre-fix hooks, and the fail-closed carve-outs go red under two mutants that disable them. The exact
2026-08-10 command that held the lock for 2d17h was replayed end-to-end through both real hooks - it
now passes through, leaves the lock untouched, and files nothing.

Not done here, because it destroys history in a shared audit file and that is the owner's call: the 11
contaminated rows already in `~/.claude/prod-ledger/dentall.jsonl` are left in place, as is the second
spurious lock still open on another window's board (sid `3ea886c4`, 2026-08-03).

## 2026-08-13 - Subagent reasoning effort is pinned instead of silently inherited

The owner asked for this directly: *"I want your sub-agents to all be a non-minimum just high. And
then extra high on request."* None of the 14 definitions in `agents/` carried an `effort` field, and
the documented default is **"inherits from session"** - so every subagent quietly ran at whatever the
parent session happened to be set to. A window dropped to medium handed medium to fourteen agents and
said nothing about it. That silent inheritance was the accident being pointed at, not a preference.

**The key was verified before the edit, not inferred, and that mattered more than it sounds.** An
unrecognized frontmatter key is silently ignored - so a plausible-but-wrong guess (`reasoning_effort`,
`reasoningEffort`, `thinking`) would have produced fourteen files that LOOK configured, changed
nothing, and left the owner believing effort was raised. That is the label-versus-mechanism failure
this repo's own review rules exist to catch, and it would have been committed while citing them.
Authoritative sources: the "Supported frontmatter fields" table in the Claude Code sub-agents docs and
the `AgentDefinition` table in the Agent SDK docs. The key is `effort`; accepted values are
`low | medium | high | xhigh | max`, with availability depending on the model.

- **Set to `high`, not `xhigh`, deliberately.** `xhigh` is what the owner reserved for on-request
  escalation, and a per-call override still beats the definition, so pinning the ceiling in the file
  would have removed the distinction he asked for.
- **`criticer.md` keeps its prose instruction** to run one focused pass without excavating the whole
  codebase. That constrains SCOPE, which is a different axis from reasoning effort - raising the
  latter does not contradict the former.
- All 14 frontmatter blocks were re-parsed after the edit; `name`, `model` and `effort` present in
  every one, zero malformed.

**Footnote worth keeping, because it will happen again.** The commit carrying this reasoning lost a
ref-lock race with the auto-sync daemon (`cannot lock ref 'HEAD'`), which swept the staged files into
a generic `auto-sync:` commit and pushed that instead. The content landed correctly and in sync; only
the explanation was lost, which is why it is written here. In a repo with a background committer, a
commit message is not a durable place to put reasoning - the changelog is.

## 2026-08-12 (later) - Flag-shaped input is refused instead of becoming the window's name

Running `line-agent-communicator.py --help` did not print help. `main()` ended in a bare
`return dispatch_set(sid, args)`, so any argv that was not a known verb was treated as a name: the
command set the caption to `--help`, overwrote the window's peer address with `help`, and printed
`Caption set: --help` as though that had been the request. The previous address - the thing other
agents use to reach that window - was simply gone, and nothing said so. It happened to the window
that built this system, minutes after it shipped.

**The first fix was in the wrong place, and a review round caught it before anyone relied on it.**
It guarded `main()`, which only sees a DIRECT CLI call. The path users actually take is `/line`,
whose body is `... set "${ARGUMENTS:-}"` - so `/line --help` arrived as `["set", "--help"]`, sailed
past that guard, and still renamed the window. Four independent reviewers plus two analysis passes
found this and four other live bypasses; all of them were reproduced against the real script under a
throwaway `$HOME` before being fixed.

- **The guard lives in `dispatch_set()`**, which every rename funnels through, so it covers the
  bare-sentence path, the explicit `set` path, and any future caller. It refuses two shapes: a
  sentence that STARTS with a dash, and any unknown long option anywhere in it - `set "billing"
  --own "x"` (one keystroke from `--owns`) used to address the window as `billing-own-x`.
- **`--` is the escape**, so a caption that genuinely starts with a dash is still settable:
  `set -- "-v my caption"`. A single dash mid-sentence is left alone - "e-mail follow-ups" is prose.
- **An empty leading argv element no longer smuggles a flag through.** `lac "" --help` renamed the
  window, because `""` is neither a help verb nor dash-prefixed; any wrapper passing an unset
  variable positionally reopened the entire defect.
- **`help` is matched only as a lone argument.** Matching it anywhere would mean `lac usage notes
  window` silently prints usage instead of naming the window - the same class of bug (a request
  quietly becoming something else) this change exists to end.
- **A lone known verb in the wrong case is refused** - nobody captions a window `Help`, and that
  spelling is one shift key from the original incident.
- **What is NOT claimed:** that any mistyped verb is caught. A caption is arbitrary words, so a bare
  `lst` cannot be told apart from someone naming a window "lst". The earlier headline here claimed
  verb coverage the code did not have; the test fingerprint made the same overclaim and now records
  what is actually proven.
- **`10-verb-fallthrough-rename.sh`** joins the suite (now 9 tests), with 11 assertions covering each
  bypass above, a whole-file hash proving the registry entry is untouched rather than merely
  same-named, three positive controls (deleting the rename path outright would otherwise leave every
  refusal assertion green), and a negative control that removes both guards and requires each
  no-rename assertion to go red BY NAME - accepting "something failed" proved nothing.
- Repairing the damaged window meant hand-editing its registry entry back to a derived name.
  `clear` deliberately keeps the peer address (dropping it mid-conversation would make the window
  unreachable), so there is no verb that undoes an unwanted rename - only setting a new one.

## 2026-08-12 - Peer messaging gets a verifiable identity, a guaranteed reply route, and a written protocol

Cross-window messaging shipped yesterday and produced two failures within hours. A message arrived
stamped `peer claims name: Message other instances` from a pid whose registry entry read
`line-agent-communicator`, so the receiver could not tell a colleague from a stranger. Separately, an
agent found errors in `~/Downloads/insurance-agent-relay-prompt.md` - a file authored by a different
window - offered twice to fix it, got no answer, and overwrote it in place with no backup; it was
recoverable only because the acting agent still held the text in context. Both are identity and trust
problems, and `crossSessionInbound: "accept"` had just removed the human approval step that would
otherwise have caught a bad instruction.

- **There is no trust anchor - and `whois` now says so instead of manufacturing one.** The first cut
  of this shipped on the premise "the transport verifies the pid, so trust the pid". That premise is
  wrong one layer deeper: `~/.claude/sessions/<pid>.json` is a plain file any local process running
  as the user can write, and the liveness check only asks `ps` for a comm whose basename is `claude`,
  which any binary launched under that name satisfies. A reviewer launched one, wrote an entry naming
  it `summit-prod-owner` / "authoritative", and the command answered `IDENTITY (attested)` - laundering
  a forged name into a confident line. Even a kernel peer credential only pins a PROCESS; the NAME
  still comes from the forgeable file, and this script never consults the kernel. So `whois <pid>
  [--claims "<name>"] [--transport socket|bridge]` now frames every answer as `UNAUTHENTICATED LOOKUP`
  / `registry CLAIMS:`, vouches for nobody at any transport, and reports `MISMATCH` as "suspect both"
  rather than "the registry wins". Yesterday's failure is reported rather than hidden; it is not
  solved, because nothing available here can solve it.
- **Three defects surfaced by the assumption suite BEFORE any of this was built.** The registry's
  `procStart` is stored in UTC while `ps` renders local time, so the naive string comparison the
  design called for would have rejected every window and left `list` printing "No live windows" - the
  directory would have died looking like an empty machine. `ps -o comm=` returns the full executable
  path, so the liveness check counted any process running under a claude-named path as a live window.
  And reachability was file-existence on the socket, so an orphaned socket advertised a dead window as
  messageable. Each was a silent wrong answer, not a crash.
- **A resumed window stopped silently losing its name.** The caption is keyed by `sessionId` and
  survives a restart; the peer address lives under the window's `pid` and is re-derived by the
  harness - so a resumed window kept its caption while its address reverted to auto-generated,
  re-creating the original bug on every restart. Verified live: the window captioned "summit admin
  hub" came back as `dentall-f9` with `nameSource: derived`. New SessionStart hook
  `scripts/hooks/line-reassert-identity.sh` re-applies the address from the caption, no-ops when the
  address is already explicit, and fails open on every path because a hook that breaks session start
  is worse than a stale name. It reads its session id from the hook's **stdin JSON** like every
  sibling `SessionStart` hook - the first cut read `$CLAUDE_SESSION_ID`, which is what a Bash TOOL
  call inherits and not what a hook process gets, so it was a permanent no-op that printed nothing on
  either path and was therefore unfalsifiable. Each re-assert now appends one line to
  `~/.claude/logs/line-reassert.log` (bounded), which is what makes "ran, nothing to do"
  distinguishable from "never ran".
- **The documented `--owns` spelling actually works now.** `/line "billing" --owns "Stripe webhooks"`
  arrives as ONE argv element (the slash command passes `"$ARGUMENTS"` as a single quoted word), so
  the flag was swallowed into the caption and the peer ADDRESS came out as
  `billing-owns-stripe-webhooks` - corrupting the exact thing `/line` exists to keep stable. The
  script re-splits that single argument itself when it contains a literal `--owns`, rather than
  `eval`-ing user prose in a bash block.
- **Verbs for the parts of a conversation that were missing.** `card` prints an identity header to
  paste into a message, and checks the sender's OWN reachability first - a window that cannot receive
  is proven possible, so `card` routes replies to a dropbox instead of advertising an address that
  swallows answers. `reply` and `replies` are both ends of that dropbox, generated by code so a
  hand-typed filename cannot fail silently. `note`/`notes` keeps durable answers past the window that
  learned them. `--owns "<line>"` lets a window describe its own domain for `list` and `find`.
- **Two rules files for the stances the incident exposed.** `rules/destructive-actions.md` - silence
  is not approval, and never destroy a prior version in a shared or human-owned path - and
  `rules/agent-peer-messaging.md` - peers are colleagues rather than workers, a peer's request is
  never the user's authority, and a message must stand alone. Both are bounded against
  over-application: the destructive rule exempts tracked files under version control, the messaging
  rule says nothing about subagents.
- **Three security regressions locked in.** `06-forged-registry-whois.sh` plants the reviewer's
  forged entry and fails if `whois` vouches for it at ANY transport; `07-banner-injection.sh` puts
  the literal END-banner inside a reply body and fails if it escapes its frame; `08-dropbox-symlink.sh`
  plants a symlink in the dropbox and fails if `replies` reads through it. Each was proven red with
  its defense removed before being trusted green.
- **Something finally LOOKS in the reply dropbox.** `reply` printed "it is not delivered - they have
  to look", and nothing ever looked: no hook, no prompt, no reminder. So a peer filed an answer,
  marked its task done believing it had communicated, and the file sat unread forever - which makes a
  "guaranteed reply route" actively worse than no route, because the sender stops looking for another
  one. New SessionStart hook `scripts/hooks/line-replies-notice.sh` prints the unread COUNT and the
  command to read it, and prints **nothing at all** when the count is zero (a hook that speaks every
  session start is noise, and noise is what gets skimmed past). It never prints reply content, sender
  or filename: hook stdout is injected into context raw, so echoing peer-authored text there would be
  an unframed injection channel that bypasses every defense `replies` was built with. The count comes
  from a new `replies-count` verb that reuses the same glob and the same last-read state file
  `replies` uses, so a notice can never disagree with the inbox it points at.
- **Retention, timid by design, for three things that only ever grew.** Reply files (reading is
  non-destructive), contacts (every window ever seen, rescanned by every `find`), and orphaned
  sockets (correctly detected as dead since the reachability fix, never cleaned up). A reply is
  deleted only when it is **already-read AND older than 30 days** - an unread reply is immortal at
  any age, including one misfiled against a sessionId nobody holds, because deleting an undelivered
  answer destroys the one artifact this feature exists to produce. Contacts are dropped after 180
  days unseen, which keeps `find` answering "closed, last seen <date>" for everything within memory.
  Reaping runs at most once a day, gated on a stamp file, from `list`/`replies` AFTER their output,
  and is fail-soft everywhere - it may never be the reason a command fails. `reap [--dry-run]` runs
  it explicitly.
- **Orphaned sockets are reported, not silently deleted.** `/tmp/cc-socks` is a fixed path OUTSIDE
  `$HOME`, so every invocation on the machine shares it - including test fixtures running under a
  fake HOME - and unlinking a live window's socket would cut it off from all messaging with no error
  at either end. The payoff is a few zero-byte inodes the OS purges on reboot, which does not buy an
  automatic destructive write to a shared path. So `reap` lists candidates and unlinks only with an
  explicit `--sockets`, behind four gates: `<pid>.sock` we own, `ps` ANSWERED and that pid is gone,
  no live registry entry names the path, and nothing accepts a connection on it after 7 days.
- **`list` stopped forking `ps` twice per window, twice over.** It computed `identity_state` and then
  called `reachable`, which computed it again - and each `identity_state` was two `ps` forks (comm,
  then lstart). `reachable` now takes the already-computed state, both fields come back in ONE fork,
  and the probe is memoised per pid for the life of the run. Measured on the real machine with 18 live
  windows: **36 forks -> 18**, with byte-identical `list` output before and after.
- **A data-loss gate for the reaper.** `09-reply-retention.sh` files two ANCIENT replies whose only
  difference is whether the last-read mark covers them, and fails if the unread one is deleted;
  proven red with the unread guard removed. Its negative control moves the mark to now, which makes
  the same fixture legitimately reapable and must turn the assertion red - so a green cannot mean
  "the reaper never deletes anything". Suite is 8/8.
- **A safety review blocked the unattended ship, and found six things - four of them proven by
  execution.** (1) Two fingerprint files recorded `ps_comm_observed`, which embeds that run's
  `mktemp` path, so every suite run dirtied the checked-in files that the pre-commit hook watches:
  any `Write` in any window -> auto-sync `git add -A` -> hook matches -> suite runs -> re-dirties
  them, forever. All eight fingerprints now hold derived booleans only (02's `live_windows_listed`
  was the same class), proven by two runs with identical `md5` and a clean tree across three runs.
  (2) `run-all.sh` folded infra skips and the 124/142 timeout remap into the failure list, so 7
  passes plus one skip exited **1** - which makes `dotfiles-sync` write `.dotfiles-sync-paused` and
  stop syncing in every window until a human intervenes. Skips are now exit **3**, failures **1**,
  reported separately, with stubbed proof of all four cases. (3) **Real data loss:** `replies`
  displayed the newest 20 but marked read with the NEWEST mtime, and `maybe_reap()` then deleted all
  25 - the 5 it had just said it was not showing, with a later `reap` reporting "0 removed" so
  nothing ever surfaced it. "Read" now means *displayed* (recorded floor + only the newest 20 per
  window are ever eligible), the dry run shares the one implementation instead of a drifting copy,
  and `09` grew A4/A5, proven red against the old logic. (4) The overwrite guard followed symlinks:
  `~/Downloads/innocent.md -> a secret` produced a plaintext `.bak-` of that secret in a
  browser-facing, cloud-synced directory; it now skips symlinks like the sibling dropbox code does.
  (5) Its 256KB stdin cap truncated the JSON of any Write over ~256KB - no backup for exactly the
  largest overwrites, plus EPIPE for the writer; it now reads to EOF. (6) It had no `[ -t 0 ]` guard
  and hung on an idle stdin. Backups also age out after 14 days by the stamp in the name.
- **The suite now gates itself, locally.** "Protected by a suite someone has to remember to run" is
  not protection, so `pre-commit` step 2.5 runs it - but ONLY when `line-agent-communicator.py` or the
  suite itself is staged, so every other commit pays nothing. It reads the suite's own exit vocabulary
  rather than treating non-zero as failure: 1 (a defense broke) blocks; 2 (env gate unset) and 3
  (infrastructure - no live windows, a timeout) do not, because collapsing 3 into failure would strand
  every commit on a machine with no Claude windows open. Two prerequisites had to be fixed first, both
  found by review before this ran unattended: `run-all.sh` was returning 1 for infra/timeout, which
  would have written the sync-pause marker and halted dotfiles syncing machine-wide until a human
  cleared it; and two fingerprints recorded a per-run `mktemp` path, so every suite run dirtied the
  very files that trigger it - auto-sync would stage them, the hook would re-fire, and the run would
  re-dirty them, forever. Fingerprints now record derived booleans only, proven byte-identical across
  consecutive runs.
- **`dotfiles-sync` no longer halts syncing over a push that succeeded.** This hook is async and two
  invocations overlap routinely, so when they race the loser's `git push` returns non-zero for work
  the winner already pushed - and the marker it writes stops syncing repo-wide. It fired twice while
  shipping this change, both times with the remote provably already at our HEAD. The routine-failure
  branch now asks `ls-remote` before pausing. Placed in that branch ALONE, after the secret and
  unproven arms: a pre-push secret rejection must never be softened, and it cannot reach the check
  anyway, since a hook that rejects a secret rejects it for every racing run. Fails toward pausing
  when the remote is unreachable.
- **What is still unfixed:** CI does not run the assumption suite - the `harnesses` job is a
  two-script allowlist requiring proof-green with the checkout outside `$HOME`, and this suite depends
  on `ps` semantics that differ on a Linux runner, so the local pre-commit gate is the only automatic
  enforcement. The identity header remains a prose convention that nothing parses: an agent that skips
  `card` sends an anonymous message and no machine notices. The overwrite guard does not cover `Bash`
  (`rm`, `mv`, `>`) - that needs a shell-intent classifier, and a fragile one would block real work.
  And neither new hook protects a window that was already open when it landed: hooks bind at session
  start, so every currently-running window needs a restart to get them.

## 2026-08-11 - /line now sets the address, not just the caption (line agent communicator)

"Message my summit admin hub agent" could not work, and the reason was structural: a window carried
**two unrelated names**. `/line` wrote a caption to `~/.claude/session-status/<sid>.txt` (cosmetic,
read only by the statusline renderer), while the peer address `ListAgents` shows and `SendMessage`
resolves lived in `~/.claude/sessions/<pid>.json`. A window captioned "summit admin hub" was
addressable only as `dentall-ae`, and nothing on the machine could translate between the two.

- **`/line <sentence>` now writes both.** It derives a handle from the sentence
  (`patient retention` -> `patient-retention`) and sets it as the real peer address. The name you
  type IS the address. No second step, no `/rename`.
- **New `scripts/line-agent-communicator.py`.** `set` does the dual write; `list` (`--json`) is the
  directory - every live window with its address, its caption, and whether it can actually receive
  a message. Global `CLAUDE.md` now routes agents through `list` whenever the user names another
  window, because `ListAgents` alone shows auto-derived names and will never contain the user's word
  for it.
- **Writing `.name` is unsupported but verified.** The documented ways to name a session are
  `claude -n` at startup and `/rename` typed by a human; neither is drivable from a slash command.
  So the script edits the registry itself - locating its own entry by `sessionId` (never pid or
  mtime), preserving unowned fields, writing atomically. Confirmed on 2.1.227/2.1.228 that the
  harness re-saves that file on every status change and **preserves** a name marked
  `nameSource: "explicit"`. If that ever stops holding, `set` degrades to caption-only and says so,
  so discovery fails loud rather than silent.
- **Contacts, so a closed window is closed rather than nonexistent.** The live registry only knows
  running windows, which made "message my insurance agent" indistinguishable from a name that never
  existed once that window closed. `~/.claude/agent-contacts.json` remembers every window seen
  named, learned automatically from whatever is live (no `/line` required). New `find "<what the
  user said>"` ranks live windows first, then remembered ones, and prints the address to use —
  `find "my summit admin hub agent"` now returns `dentall-ae` with its exact unreachability reason,
  which is the request that failed and started this. Contacts are a cache, never an authority:
  reachability is always recomputed live, so a stale contact can misname a window but can never make
  a dead one look alive.
- **`crossSessionInbound: "accept"`** in user settings, so peer messages deliver without a manual
  approval step. Default behaviour holds a message whenever the sender's permission-mode class
  differs from the receiver's, which is what interrupted the first successful send. Applies to
  sessions started after the change.
- **Collisions are resolved, not inherited.** `dentall-4c` currently names two live windows, which
  is exactly what forces callers back to opaque refs. A handle already held by a *live* window gets
  a numeric suffix; dead windows never block a name.
- **The wall the naming fix does not move:** cross-session messaging arrived in **2.1.224** and the
  receiving socket binds at process start, so a window on an older build cannot be messaged until it
  is closed and reopened - upgrading alone does nothing. Measured at the time of writing: 16 live
  windows, **1** reachable. `list` reports the reason per window so no one sends into a void.

## 2026-08-04 - The review barrier catches two shipped CRITICALs, including one this repo introduced

Mission part 3, round 5-6. A 4-Codex + 2-Claude review panel over the part-3 diff. It found two
defects that had already been committed and auto-pushed to the public remote, and the honest
summary is that the previous round's "fix" caused one of them.

- **The `xargs` fix was a coverage regression.** Replacing `| xargs` with
  `< <(git ls-files -z)` traded a coverage guarantee for a diagnosis improvement:
  `set -euo pipefail` **cannot** observe a process substitution's exit status. Reproduced with a
  `git` emitting 2 of 3 paths then exiting 141 - the new form printed `clean (2 tracked files
  scanned)` and exited **0 with an unscanned secret in the tree**, where the form it replaced
  went red at 141. `secret-scan.sh` already documented this rule in its own comments. Found
  independently by two Codex lenses and the adversarial Claude lens. Enumeration now goes
  through a file with the producer status captured, plus a trailing-NUL check (a truncated
  stream silently loses its last record to `read -r -d ''` - also reproduced).
- **The new CI `harnesses` job had been red on every push since it landed** - 16 consecutive
  failures, verified via `gh run list`, not inferred. Six of seven harnesses resolved their
  target from `$HOME/.claude-dotfiles` (absent on a runner) or used BSD-only `stat -f` /
  `date -v`, and the `set -e` loop aborted at harness #1 - so `test-lint-skill-size.sh`, the
  centerpiece of this part, **had never once executed in CI**. Fixed by accumulating results so
  every harness reports, giving that harness a `BASH_SOURCE`-derived root, and cutting the list
  to the two proven green outside `$HOME`. The other five are recorded in-file as NOT YET
  PORTABLE with each exact cause. CI verified green afterward.
- **`chain_manifest_read`'s two halves disagreed.** Its recovery branch validated its output
  while its fast path trusted any parseable JSON - `jq -e .` returns 0 for `{}`, `[]`, `0` and a
  bare string, so the primer rendered a chain banner of default fields. And "recovery failed"
  shared rc=1 with "genuinely first run", which makes `pre-compact` set `IS_FIRST_RUN=1` /
  `NEW_SEQ=1`: a live chain with an intact ledger would have **restarted at seq 1 and
  overwritten its own manifest**. Fast path now shape-checks; recovery failure returns rc=2; and
  the caller was taught the difference rather than just the contract being documented.
- **The `lint-skill-size` ROOT guard proved a directory existed, not that its targets did** -
  `--all` (exactly what CI runs) returned 0 having measured nothing when the guarded files were
  renamed. It also fired in `--staged`, where its own adjacent comment says ROOT is unused,
  which had forced a fixture to `mkdir` an empty `commands/` to get past it. Both fixed; the new
  check immediately caught that the test fixture had only ever created three of the five
  guarded files.
- **Three tests I wrote in this round were themselves vacuous** and only caught by mutating
  them: two asserted `rc==1` where the lint reaches 1 by other routes, and one was masked by a
  prior case leaving a file oversize. All now assert the specific failure *reason* and are
  mutation-verified in both directions. Guards were also widened (action pinning now covers
  every workflow, not just one) and loosened where they produced false positives on correct
  edits, because a guard that breaks valid work gets deleted.

Suites: `test-secret-scan` 199/0, `test-lint-skill-size` 13/0, `test-chain-primitives` 18/0
(both portable ones also green in a relocated-checkout fixture).

## 2026-08-03 - CI tells you WHICH failure it found; the last unwired lint gets wired

Mission part 3 ("guard-integrity"), slice D - the three remaining `ci-1`/`lint-1` findings from the
2026-08-03 `/god-report`. Each was reproduced by execution before any fix was written, per the
mission's standing rule that findings are not a source of truth.

- **CI could not distinguish "a secret is in the tree" from "the scan proved nothing."**
  `git ls-files -z | xargs -0 bash scripts/secret-scan.sh --` discarded the scanner's exit code:
  `xargs` reports its **own** status for any non-zero child (BSD 1, GNU 123), so rc=2 (rotate a
  live credential now) and rc=3 (the scanner is broken, go fix it) both arrived as one
  indistinguishable red. MEASURED both directions on BSD xargs before fixing. Scope stated
  honestly: xargs runs every batch even after one fails (also measured), so **no file was ever
  skipped and the job was red in both cases** - this was a diagnosis defect, not a coverage one.
  Replaced with enumeration into an array + a direct call, batched at 500 against ARG_MAX, with
  precedence 3 > 2 > 0 and a distinct message per outcome. An empty enumeration is now treated as
  a broken enumeration (rc=3), never as a clean tree.
- **The gitleaks action was pinned to `v2`, a tag its publisher can re-point at will**, while
  holding `secrets.GITHUB_TOKEN` - third-party code execution in our CI with no diff on our side
  to review. Resolved `refs/tags/v2` to commit `ff98106` (identical to v2.3.9; the project has
  since shipped v3.0.0, so `v2` is a stale floating pointer) and pinned the SHA with the version
  in a trailing comment, which is now the only human-readable record of which release it is.
- **`lint-testplan.sh` ran nowhere.** Its header asserted "There is NO aggregate test runner / CI /
  husky in ~/.claude-dotfiles" - false on both counts, and self-fulfilling: it read as a reason not
  to look for a wiring point, and this was in fact the only one of the three lints that no
  automated path invoked (not CI, not the generated pre-commit hook, which runs only the two lints
  with a `--staged` mode). Wired into `lint-commands.yml` with the explicit ROOT argument CI needs,
  and the header corrected. Verified green (26/0) and verified to fail **closed** (exit 2) on a
  wrong ROOT before wiring.
- **Four machine-guards shipped WITH the fixes**, not as follow-ups, because both bad shapes are
  silent (a red job either way; a moved tag produces no diff) and both are the obvious way to
  write the code, so they can recur at any time: CI passes `--`, CI does not pipe through `xargs`,
  CI refuses to report clean on an empty enumeration, and no non-`actions/` third-party action is
  pinned to a mutable `@vN` tag. Each was mutation-tested in both directions - reintroduce the
  defect and watch the guard go red. The `xargs` guard strips comment lines first: the workflow's
  own rationale names `| xargs -0`, and a guard that matches its own explanation can never fail.
  `test-secret-scan.sh`: 191 -> 195 cases, 0 failures.

## 2026-08-03 - Missions never silently stall: continuation-owner invariant + AWAIT bookmark + no-detach gate

An autonomous `/mission` used to freeze when a turn ended with nothing to wake it back up. Two
roads: **road 1** a review launched shell-detached (`nohup codex ... &`) - the wrapper exits in
~1s, the harness tracks the launcher not codex, codex finishes orphaned, no wake (`f71c8667`,
idle 3h38m); **road 2** the agent banks a log line and just stops - no pending job, no scheduled
wake, no compaction (5 of 6 stalled missions were road 2). The fix is built ONLY on the two
empirically-proven wake mechanisms (a tracked `run_in_background` Bash re-invoking the idle agent
on exit; `ScheduleWakeup` called directly by a skill, proven by `commands/afk.md`) and REUSES the
mission loop's existing §8/§H recovery read instead of adding parallel machinery. The disputed
`asyncRewake` and `/goal` mechanisms were dropped as non-establishable.

- **The continuation-owner invariant (road 2).** A `/mission` turn MUST NOT end unless it just called
  `ScheduleWakeup(...)` as its last action AND that call SUCCEEDED, OR it is at a genuine human-handback
  / stop point. A **scheduled wake is the ONLY continuation owner** - a tracked `run_in_background` job
  is NOT sufficient alone (its completion wake can be lost), so a turn yielding with a job pending STILL
  schedules a long fallback heartbeat. Stated as a HARD return invariant in the contract core; a failed
  schedule retries then STOPS LOUD (never a silent naked yield). The invariant covers EVERY turn-end (the
  four named epilogue seams are examples, not the whole set).
- **The AWAIT bookmark (one new durable marker).** `[mission] AWAIT part=N phase=P round=K
  kind=<job|human> op=<slug> attempt=A need=<mask> got=<mask>` rides the existing log via the new
  `mission-write.sh await` / `await-state` verbs (in `lib/mission-bridge.sh`). It distinguishes
  "work never launched" from "work launched, one lane returned", so the wake routine replays ONLY
  the missing lane. Barrier identity is (part,round,attempt,`kind`) - a job bit never satisfies a human
  `need`; each lane writes ONLY its own bit and `await-state` OR-accumulates. The §8 `ready=0 + NO tracked
  job -> replay` row (gated on a lane-timeout) is the safety net: correctness does NOT depend on 100% wake
  delivery. A banked `phase=review round=K` successor / `VOID` / `PART-DONE` SUPERSEDES a job AWAIT (a
  join-ready `ready=1` barrier stays outstanding until then, so the bank is reachable); a `kind=human`
  barrier is resolved by its own `got==need`. `await-state` emits `none` | `corrupt` | the `await …` token.
- **The single idempotent wake routine.** Background-completion, a `ScheduleWakeup` tick, and
  post-compact resume all funnel into ONE routine: `mkdir tick.lock` (atomic, sleep-skew +
  backward-clock clamps) -> §8 resume-read -> `cursor_before` = sha256 of the current-generation
  state stream (`mission-write.sh cursor-hash`, rotation-invariant via `_gen_sliced_stream`) ->
  one transition -> recompute the cursor immediately before dispatch, re-enter (bounded) if it
  moved. The dedup for queued wakes is the tick-lock SERIALIZING + each wake re-reading current
  state; the cursor is the in-turn consistency check, and deterministic idtags make any re-bank an
  idempotent no-op (the cursor alone does NOT make two queued wakes advance exactly once).
- **No-detach gate (road 1 backstop).** `scripts/hooks/no-detach-gate.py` (PreToolUse Bash,
  registered in both settings files) `exit 2`-blocks a shell-detach (`nohup`/trailing-`&`/`disown`/
  `setsid`) wrapping a codex launch, and FAILS OPEN on any parse/classifier error (the harm
  direction is a false positive wedging Bash). `&&` is allowed via `(?<!&)`; `& wait` is allowed
  (it blocks). Known-open bypasses (`bash -c '...'`, `$CODEX_BIN`, quoted subshells) are ACCEPTED
  and documented - it backstops the common literal foot-gun, it does not remove discretion. A
  shared fixture table (`fixtures/no-detach-cases.tsv`) + `test-no-detach-fixtures.py` pin it.
- **Timeout raises + god-review bounding.** `codex-review.md` raises `CODEX_TIMEOUT_SECS`
  540->3600 and the collection ceiling in lockstep (fast per-lens 120000 values left alone).
  `god-review.md` §2c switches to a serial-FIFO bounded `run_in_background` launch (concurrency on
  the shared `~/.codex` flock was a wake-storm), and `codex-invoke.sh` gets a whole-wrapper
  deadline (~3300s covering profile fallback + flock + spin + codex) with a `set -e`-safe rc
  capture and atomic `.status` sidecar, so a timed-out partial is never counted as a reviewer.
- **Hermetic proof + recovery reporter.** `scripts/hooks/mission-continuity-assumptions/` (4
  cases, 22 assertions, `MISSIONCONT_SMOKE_ALLOW_DEV=true`): gate parity, AWAIT lifecycle,
  lost-wake replay, idempotent cursor - each watched failing first, all green. Throwaway `mktemp`
  mission roots, no DB/OD/network/PHI. `scripts/mission-recovery-scan.py` is a MINIMAL read-only
  reporter (not durable machinery): it surveys the frozen chains and prints a table (heuristic
  dead-gap, status, outstanding-AWAIT, PENDING-DECISIONS parked flag, and a PINNED manual
  `/mission resume` command per mission) - it executes NOTHING.
- **Deferred follow-ups (NOT built).** (1) An out-of-session mission-supervisor daemon for
  autonomy that survives Claude being fully closed (`ScheduleWakeup` only fires while the app is
  open; today's cross-close recovery is resume-within-7-days + the post-compact chain). (2) A
  `prod.lock` ownership-lease (heartbeat + CAS) plus a fix for its false line-21 comment - do NOT
  force-clear the live `f71c8667` lock. (3) v2's `wait-open`/`wait-close` verbs,
  `mission-waiting-reconcile.py`, and the `_mw_validate_log` WAITING edits were never built; the
  single AWAIT marker + the ScheduleWakeup epilogue + the existing §8 recovery read replace them.

## 2026-08-02 - Parallelizer v1: parallelism made binding, measured, and machine-checked

**Closeout addendum (post-implementation review, same day):** the Task-8 LIVE smoke is done and
green - the registered `parallelizer` agent (registry picked it up in-session) emitted a real
FAN_OUT wave_plan for a 2-item envelope and `verify-parallel-wave.mjs --validate-plan` accepted
it (exit 0; the first live validate-plan event is in rework.log). Task-0 gate baselines recorded
in the dentall suite README (all three unrelated suites: exit 2 env-gate REFUSED). Three phantom
dry-run events purged from rework.log (the Shared Fixture repo_root escaped the fixtures-drop
predicate - broadening it is follow-up hygiene). Weekly-replay project-dir selection switched
from dir-mtime to top-level transcript VOLUME (a near-empty dir had won and burned the throttle;
throttle re-armed, empty artifact deleted). Review verdicts: implementation-reviewer - all
quality gates green, 26/26 assumption cases, "genuinely fail-closed rather than
fail-closed-by-naming"; criticer items on mission-surface successor work and a wave-retirement
threshold are folded into the follow-ups below.

Parallel execution is now the DEFAULT across the playbook layer, and it is enforced by text the
orchestrator is bound by plus checks that fail closed - not by advice. Read-only fan-out registers
ship on every run; the write-wave machinery ships fail-closed with serial as the universal
fallback everywhere. Built through /discussion -> /plan (5 review rounds: 10 plan-reviewers, 5
criticers, 3 Codex passes) -> /implement, on a plan whose own headline numbers were re-measured
and CORRECTED before implementation started (below).

- **Commands rewritten.** `codex-review.md`: one binding **Launch schedule** block above Step 3 -
  "EXACTLY 6 tool calls in ONE message" (4 Codex lens passes with `run_in_background: true` + 2
  Agent calls), and Step 4 split into **4a** (Architecture + Integration, launched early in that
  same message) and **4b** ("EXACTLY 1 Agent call" - Adversarial + FP-filter, spawned late because
  its FP half consumes the merged Codex findings, which do not exist until 3d). Non-code targets
  get their own "EXACTLY 3 Agent calls" branch. The old "Spawn ALL FOUR Bash calls in a SINGLE
  message" wording is GONE, and its absence is machine-asserted. `plan.md` Step 1 retitled to a
  mandated **research fan-out** ("CRITICAL - research is a parallel fan-out, not orchestrator
  reading: spawn ALL research agents in a SINGLE message") with exactly two named skip exceptions.
  `implement.md` gained a chunk table, a **bounded chunk-parallel register** (chunks whose file
  sets are determinable, pairwise disjoint and hazard-free MUST be spawned in one message; anything
  indeterminable or hazardous is sequential) plus a **post-batch overlap check** that HALTs with the
  batch jointly implicated, and a WAVE GATE + WAVE MODE section below `CONTRACT-CORE-END` - the
  rewrite forced that 20k split, so a post-compaction truncation degrades cleanly to serial.
- **Machinery added.** `agents/parallelizer.md` - advisory-only scheduling subagent (returns a wave
  plan or SERIAL_CORRECT; never implements, never spawns). `docs/wave-plan-schema.md` freezes BOTH
  schemas (wave plan + wave state) as the sole authority. `scripts/parallel-stats.py` (transcript
  instrumentation + `--replay` counterfactuals), `scripts/verify-parallel-wave.mjs` (fail-closed
  checker, 3 modes, one capped machine event per invocation), `scripts/merge-wave.sh` (incremental
  resumable merges recording `merge_sha` per chunk). 26 new hermetic assumption cases across 3
  suites (verify-parallel-wave 15, lint-commands 6, parallel-stats 5), each watched fail first.
- **Guards.** `lint-skill-contract.sh` now carries the register literals for all three commands, a
  `req_before` helper (a register must sit BEFORE `CONTRACT-CORE-END` by first-occurrence CHAR
  offset; fails closed if either is absent), and the ABSENCE check for the retired codex-review
  sentence - and it is **wired into pre-commit** with a new `--staged` mode (ROOT split: file
  locations from `BASH_SOURCE`, staged-set query from `git rev-parse --show-toplevel`, so a linked
  worktree's index is actually visible). `lint-skill-size.sh` Rule-2 + WARN-skip lists extended to
  both rewritten commands. `on-session-start-cleanup.sh` sweeps stale wave worktrees (>7 days,
  breadcrumb-guided `worktree prune` first) and runs a bounded weekly `--replay` (`timeout 45`,
  tmp->mv on success only, completion-marker throttle - a killed run does not suppress the next).
- **Measurement corrections - the headline numbers changed.** Baseline measured over the 10 newest
  top-level transcripts (`tmp/briefs/parallelizer-research/baseline-2026-08-02.txt` in dentall).
  Spawn turns: **47.2% solo** measured vs 54% hand-mined - ACCEPTED (same direction, 6.8pp, inside
  the 10pp band). Codex turns: the hand-mined **91% is retired** - it was a per-JSONL-RECORD
  measurement artifact. The harness writes each tool_use block to its own record, so per-record
  grouping reports 100.0% solo BY CONSTRUCTION (843/843); grouping by `message.id` gives **68.4%
  raw solo (409/598)**, and netting out 210 dependency-flagged report-chained calls that could
  never have been batched gives **34.9% avoidably solo**. Quote 68.4 / 34.9; quote 91 only as the
  corrected artifact. 31.6% of codex turns were ALREADY batched. Wave-gate eligibility: an UPPER
  BOUND of 15 of 31 /implement phases (48.4%) - two conditions (repo_root cleanliness, stale-wave)
  are not recorded in transcripts at all and are credited open, and both only subtract.
- **Thesis checkpoint - v1 addresses a MINORITY of the codex waste, on purpose.** The plan's flagged
  condition was "register-bearing surfaces dominate solo-codex". They do not: **/mission does, at
  62-75%** under both attribution rules tested, while codex-review + master-review account for
  15.2-26.4% (master-review: zero). mission.md surface is explicitly OUT OF SCOPE for v1
  (Divergence 3), so v1's read-only rewrites buy the spawn-side win in full - codex-review is the
  WORST surface for solo spawn turns at 56.5%, above the 47.2% average - plus that minority codex
  slice. The majority remains on a surface v1 deliberately does not touch. Stated, not buried.
- **Probe evidence (it changed the design).** `scripts/parallelizer-assumptions/PROBES.md` in
  dentall: foreground Bash calls issued in ONE message **SERIALIZE** - measured, leg B started
  0.09s after leg A ended (shared shell). Same-message batching alone does NOT parallelize the
  codex passes, which FALSIFIED the Layer-1 premise as originally worded and restored the
  backgrounding decision (Divergence 1): lens passes run `run_in_background: true`, collection is a
  bounded wait on the `.status` sidecars (poll ~20s, ceiling 600s; absent at ceiling = not-usable),
  and `codex-exec.sh`'s own `CODEX_TIMEOUT_SECS=540` graceful self-timeout now matters MORE, since
  the harness timeout's applicability to backgrounded tasks is unproven. A second probe: a subagent
  wrote and committed inside `~/.claude/wave-worktrees/` with ZERO permission prompts, so that
  location is used as planned and no `settings.json` allowlist line is needed from the user.
- **Dry run + dogfood.** The Task-9 wave dry-run drove 2 real chunks through the REAL machinery on
  a throwaway fixture repo and PASSED end to end: worktree adds, two implementer subagents, checker
  green, incremental merge with `merge_sha` recorded per chunk, the fixture's post-integration gate,
  non-force teardown, live events in `~/.claude/parallel-waves/rework.log`, zero permission prompts.
  The SID block resolved the live broker file. Dogfood: this plan's own late tasks were dispatched
  as parallel chunks under the new `implement.md` register - observed, not yet machine-asserted;
  follow-up (2) is that assertion and must run in a FRESH session (symlink liveness is next-session).
- **Codex-surface survey - recorded, NOT applied.** `master-review.md` + `prepare-pr.md` came back
  already compliant (all 5 master-review codex sites are bound by their phase's single-message
  register; prepare-pr's is serial by a real review->fix->re-review data dependency). Zero sites
  qualify for the pattern and lack it, so nothing was changed. Three findings are recorded for a
  later pass: **F1** `master-review.md:256` still reads "Launch ALL 6 simultaneously" while its
  Phase-1 register at `:182` binds 14 - an orchestrator reading the nearer heading could under-batch
  and drop 6 lens agents plus 2 reviewers (minimal fix: retitle to 14; out of this plan's file set).
  **F2** those 5 sites are FOREGROUND Bash, so they are message-batched but do not overlap in wall
  clock - do not read master-review's low solo-codex count as "already fast"; converting them is not
  zero-risk (their inline `codex_invoke` has no `.status` sidecar or self-timeout). **F3** their
  `CODEX_BIN`/`CODEX_HOME_*` vars are derived in a SEPARATE bash fence from the consumers, and Bash
  calls are fresh shells - so those lanes may be silently short-circuiting to `[unavailable]` in ~0s
  (inferred from file structure, NOT from a live run; confirming needs one live master-review).
  Treat any codex turns attributed to master-review as nominal until then.
- **Not touched (decisions):** frontmatter `expected_subagents` left inert everywhere (Divergence
  11); Layer-2 ambient nudge INJECTION stays deferred (Divergence 2 - replay says a nudger at these
  thresholds would have spoken ~250 times across 10 sessions); no `settings.json` edits; no
  mission.md surface; no wave machinery under `--no-review`.
- **NAMED FOLLOW-UPS (not done - these are the honest remainder).**
  1. **Fresh-session effect check** for the codex-review rewrite. Run one real `/codex-review` in
     branch mode in a FRESH session, then: structural check with
     `python3 ~/.claude-dotfiles/scripts/parallel-stats.py <newest transcript>` - the 6 calls must
     share ONE `message.id`; wall-clock check of Step 3 -> Step 5 against the baseline; quality
     check by DIFFING FINDING SETS against the same target run through the pre-change command. A
     DIFF-UNREADABLE or structural failure is fixed first, not accepted. Named revert remedy if a
     real regression shows: `git checkout 80ece6b~1 -- commands/codex-review.md`.
  2. **Fresh-session serial regression** for the `implement.md` register: a 3-chunk
     `/implement --no-review` against the throwaway fixture (cwd = fixture root), asserting
     same-message chunk spawning MACHINE-SIDE via parallel-stats (shared `message.id`), plus the
     gates and the Step 7 shape. Must be a fresh session - never nested inside the run that edited
     the file.
  3. **Weekly replay read-out.** The cleanup hook now accrues this by mechanism; read the first
     auto-written `~/.claude/parallel-waves/replay-latest.txt`, make the Layer-2 enable/discard
     decision from it, and re-confirm Divergence 2 with the user.
  (Also accruing, no action needed: compliance RATE across later unprimed sessions - the lint proves
  the text is present, only repeated sessions prove the behavior.)

## 2026-08-01 - Production cleanup: dead packs removed, contract-first skill restructure, anti-drift additions

Full production defluff of the repo, verified by a 9-agent audit (3 Claude auditors, 6 Codex
transcript verifiers) over the complete retained transcript corpus (4,585 jsonl / 4.4 GB / 19
project dirs). Every removal was zero-usage AND zero-inbound-reference verified. User-approved
keep list honored (afk, claudemd, commit, share-fix, skill-improve, investigate, research-web,
database-audit, checkpoint, master-review - all health-checked, all clean).

- **Removed** (commands/): hybrid/LM-Studio pack (5, hard-broken - target dir absent), minicrew/
  (empty), patterns/ (empty + dead live symlink), fraim, molecular pack (admet/dock/screen/
  optimize/prep-target/dashboard), crm, plan2bid (19), parsa (27), skillset, buildskill,
  architect, learn, tdd, renderdeploy, netlifydeploy, supabase-audit (deprecated alias),
  ui-ux-pro-max (7). All inbound references swept in the same commits (codex-review FRAIM
  excision across 6 regions; generate-codex-layer + skill-improve + docs examples).
- **Archived** (unlisted, kept): gemini/ (broken since 5/30), antigravity.md (built on the
  absent hybrid-control tree), PRECOMPACT-STARTUP-HANG-FIX.md -> `archive/`.
- **Contract-first restructure** of the three compaction-critical skills. Empirical finding:
  invoked-skill bodies are re-injected after EVERY compaction HEAD-TRUNCATED to the first
  20,000 CHARACTERS - mission.md and pre-compact.md were losing their operating contract at
  every boundary. post-compact-resume.md slimmed 25,592 -> 19,997 chars (fits whole);
  mission.md + pre-compact.md gained a self-sufficient CONTRACT CORE ending at a
  `<!-- CONTRACT-CORE-END -->` marker (<=19.5k), full detail below. Cold-read tests (fresh
  agent, 20k slice only): 8/10 both, correct bridge-write line emitted.
- **New guards** (fail-closed): `lint-skill-size.sh` (20k ceiling, chained into pre-commit
  BEFORE the terminal secret-scan exec; 6 fixture tests) + `lint-skill-contract.sh` (durable
  required-literal inventories: 25 allowlisted mission-write invocation lines, banned ~/$HOME
  variants, log grammars, all STATE tokens, all 24 pre-compact step headings).
  `dotfiles-sync.sh` commit failures now LOUD + fail-closed (was silently pushing stale HEAD).
- **Anti-drift additions** (from the openai/codex CLI study): a 4-rule continuation contract
  rendered in every mission banner AND the post-compact primer message (keep the full
  objective; worktree over memory; completion unproven until evidenced; blocked only after 3
  repeats); ctx-gate FORCE message now names the durable surfaces; `handoff-smoke-check.sh`
  (advisory) verifies handoff-referenced paths exist, warning into the handoff itself.
- **Instruction layer:** settings.json.template synced HOOKS-ONLY from live (template
  permission list stays intentionally stricter - note reworded to say so); global CLAUDE.md
  ship-per-tab example + statusline tombstone cleaned; OpenWhip crumb removed from
  settings.local.json. dentall CLAUDE.md/AGENTS.md trailer fix deferred to a patch (repo was
  mid-merge).
- **Purged:** .handoff-archive/, reference/settings.local.snapshot.json, .DS_Store (+
  gitignored). `~/.claude/` junk (9 settings backups, commands.bak/, rules.bak, tmp-codex-r2)
  quarantined to `~/.claude/.trash-20260801/` (NOT deleted); 25 verified-orphan memory
  sidecars moved to `memory/orphans-archive/`.
- **Registry:** docs/COMMANDS.md regenerated from the live command set; Codex mirror
  refreshed via install-codex.sh (88 skills, zero dead names).

## 2026-07-14 — New `/testplan` skill: capability-discovery test-plan generator

Added `/testplan` (`commands/testplan.md`) — a domain-agnostic skill that writes an exhaustive,
production-realistic TEST PLAN for any target (feature / API / CLI / library / worker). It comprehends the
program's role, discovers what it can test with (read-only, deny-by-default — never mutates while planning),
scales coverage to the target's archetype + risk (a small target collapses to a core; a money / PHI /
external-write target gets the full machinery), designs real user journeys + every-order-that-matters
end-to-end, and emits a risk-tiered plan with honest BLOCKED rows and a READY/NOT-READY verdict. It PLANS;
it never executes. Built via `/discussion` → `/plan` → a 2-Claude + 3-Codex-xhigh review round → `/implement`.

- **New:** `commands/testplan.md` — the playbook, with embedded worked micro-examples.
- **New:** `scripts/lint-commands/lint-testplan.sh` — manual pre-commit structural lint (frontmatter, all
  five phases, the tiered self-lint contract, and a domain-agnostic deny-list of project-specific literals).
- **Registry:** `docs/COMMANDS.md` — `/testplan` added under Planning & implementation.

## 2026-07-02 — Codex reasoning-effort floor raised to `high`; heavy audits at `xhigh`

Standardized every Codex (OpenAI Codex CLI, `gpt-5.5`) invocation across the dotfiles on a `high`
reasoning-effort floor, with the heaviest audits escalated to `xhigh`. The model was already
`gpt-5.5` everywhere via `~/.codex/config.toml`; stale "GPT-5.4" labels in skill descriptions/README
were scrubbed to 5.5 (documentation drift, no behavior change).

- **Global default** (`~/.codex/config.toml`): `model_reasoning_effort` `medium` → `high`.
- **`/codex-review`**: `EFFORT` default `medium` → `high` (enforced floor). Escalation to `xhigh` is now
  **dynamic**: an explicit `--effort` from the caller wins (a convergence loop pins `--effort high`), but when
  invoked with no flag the orchestrator self-assesses and reaches for `xhigh` only on genuinely critical,
  one-shot targets (auth, payments, migrations, irreversible / prod, untrusted-input parsing). Values below
  the floor are ignored. `/mission` documents the same escalation option for critical parts of its review loop.
- **`/prepare-pr`**: inline `codex exec` review call now pins `model_reasoning_effort=high`.
- **`/god-review` + `/god-report`**: shared `god-review/lib/codex-invoke.sh` `high` → `xhigh`.
- **`/master-review`**: all Phase 1 + Phase 3 `codex_invoke` calls now pin `model_reasoning_effort=xhigh`.
- **`/ui-audit`** and **`/mission`**: unchanged (stay at `high`).
- Verified `xhigh` is accepted at runtime by Codex v0.142.5 on `gpt-5.5` (smoke test).

## 2026-05-31 — Statusline line 2: live-activity label (fix the perpetual "working" spinner)

After the single-bar rework, line 2 in real sessions sat on a generic spinner + the literal `working`
forever (`15:25  ▱▱▱▰▰▰▱▱  working`). Root cause (verified, not a render bug): the v2 renderer + hooks work,
but agents rarely call TodoWrite (0 calls in recent dentall transcripts), so `overall` never becomes
determinate → spinner + `working`. The to-do list is not a reliable signal in practice.

Fix — drive the line-2 **label** from the live tool stream, decoupled from the bar:
- New `scripts/progress/on-tool-activity.sh` (PostToolUse, most tools) writes a short label —
  `Edit migration.sql`, `Bash: run tests`, `Read foo.ts`, `Grep "pat"`, `Task: reviewer`, MCP last-segment —
  to a **separate sidecar** `~/.claude/progress/<sid>.activity.json` = `{ts,label}`.
- **Separate sidecar (not a shared-JSON RMW)** — like the beacon `<sid>.current.json` — so the async hook
  can't clobber `overall`/`current` or race `on-todo-write`/`on-task-spawn`/`on-stop`. (Plan reviewers'
  central finding; resolved by design rather than locking.)
- Renderer label priority (decoupled from bar): `beacon → live activity → todo activeForm → "working"`. The
  bar still fills from determinate beacon → determinate todos → spinner. Activity is ts-gated
  (`ts >= prompt_started_at`) so a stale sidecar can't bleed into the next turn.
- Matcher **anchored** `^(Edit|MultiEdit|Write|NotebookEdit|Read|Bash|Grep|Glob|WebFetch|WebSearch|Task|mcp__.*)$`
  so `Write` can't substring-match `TodoWrite` under unanchored-regex semantics. `TodoWrite` excluded (ugly
  label, owned by `on-todo-write.sh`); `Task` included (sidecar removes the race).
- Single `python3`, zero `jq`, in the hook (env-var stdin); Bash labels prefer `description` and fall back to
  the command's first token only (no secret leak); `active` is NOT written by the activity hook (no post-Stop
  resurrection). `on-stop.sh` removes both sidecars.
- Both `statusline.sh` copies kept byte-identical. **Requires a Claude Code reload** for the new
  settings.json PostToolUse hook to register (the renderer change is live immediately).
- Reviewed by 2 parallel plan-reviewers; the sidecar redesign came directly from their concurrency findings.
  All render/label gates pass (Edit/Bash-secret-safe/MCP/Task labels, activity-over-spinner, todo-bar+activity
  decoupling, stale-sidecar-ignored, on-stop-removes-sidecar). Docs: PROGRESS-BARS.md, STATUSLINE.md,
  ARCHITECTURE.md updated.

## 2026-05-31 — /mission hardening: drive to a clean cross-model codex-review (8 review rounds)

Closed the confirmed findings from the multi-Codex review of `/mission`, driven through the user's
own methodology: `/script` (5 new assumption tests) → `/implement` → 8 rounds of `/codex-review`
(4 Codex + Claude lenses) with 7 fix rounds, looping to convergence. All CRITICALs resolved by round 2;
rounds 5-8 were the asymptotic self-referential tail on one secondary guard, closed with root-cause fixes.

**New assumption tests** (`scripts/hooks/mission-bridge-assumptions/` 09-13, all green; suite now 13/13):
09 rebaseline reactivates a cleared mission (RED→GREEN proof of CRITICAL #1) · 10 FAIL idtag must be
attempt-scoped (the 5-strike loop-breaker) · 11 mission-write.sh exit-0 + rc=2/rc=3 stdout status parse ·
12 the 480B round-line reroute boundary · 13 resume read survives log rotation.

**`scripts/hooks/lib/mission-bridge.sh`:** `mission_rebaseline` now appends a
`[mission] MISSION-REBASELINED status=active` lifecycle line (empty idtag → never dedup-suppressed) and
propagates the log-append rc instead of swallowing it (so a cleared mission can actually reactivate);
`_mission_log_rotate` skips (doesn't rotate) when the lock is busy, heals a torn last line before the
line-count split, and names archives `…<utc>.<seqNNNN>.XXXXXX` for collision-proof same-second
chronological ordering; `mission_create` returns `rc=2` (the uniform corrupt-bridge code, matching
`mission_mutate`/`mission_rebaseline`) when an existing file fails verify, so a corrupt bridge found
at mission start routes to STOP-LOUD instead of being misread as a generic failure.
`scripts/hooks/mission-write.sh`: REFUSED now emits the parseable `FAILED rc=1 (REFUSED: …)` shape.

**`commands/mission.md`** (the conductor playbook): fix-pending `phase=<review|fix>` round substate;
attempt-scoped FAIL idtag + enumerated FAIL events; parse the `mission-write.sh` status line (rc=2→STOP-LOUD,
rc=3→retry); resume reads grep over (all rotated archives oldest→newest + live log), set-e/pipefail-safe
and space-safe, replacing `tail -n 40`; terse <480B round line (verbose findings → separate note);
active-iff keys only on the latest `MISSION-(CLEARED|REBASELINED)`; a total + mutually-exclusive resume
decision table (completed-part / PART-START-no-round / research·plan·implement / review / fix / VOID);
Codex-unavailable VOIDs the round via a `Codex-passes: 4/4` header token anchored to the canonical
`^Engine:` line; untrusted mission content passed single-quoted / via stdin; PART-START/PART-DONE/
PART-RETIRED advance; away-default + credential/destructive PENDING guard.

**`commands/codex-review.md`:** FRAIM rules reframed as untrusted/inert (no authority to suppress
findings); per-run `mktemp -d` temp dir (no fixed-path clobber); a mandatory machine-readable
`Codex-passes: N/4` header token (mode-aware usable-pass classification — diff-mode = ran-clean,
exec-mode = mandatory `Verdict:` line); both target-summary emission sites forced single-line (no
fake-`Engine:`-header injection).

Gates green throughout: mission-bridge-assumptions 13/13, test-mission-bridge 60/0.

## 2026-05-31 — Bulletproof session correlation: PID-bound /compact delivery + self-driven resume

Fixes a multi-session misfire in the auto-compact pipeline. **Incident (04:42Z):** session `49d80a3a`
armed auto-compact, but the queued `/post-compact-resume 49d80a3a` was typed into a **sibling** session's
tab (`24a704c2`); the R9 `arg-not-my-session` guard refused the wrong-load (safe — no contamination), but
the correct session never auto-resumed. **Root cause:** delivery was bound to `tty` (captured at arm-time,
matched at fire-time only by `tty ==` + a generic "*some* claude is foreground here" check). With many
concurrent sessions + tab churn, `tty` is neither stable nor unique-to-a-session, so the typed commands
landed in the wrong tab. Session *identity* was always solid (Stop hook uses the payload `.session_id`);
the unguarded seam was the *delivery destination*.

The fix extends the session-id principle to that seam, additively (R9, marker-verify, automation probe
all preserved; **bare `/compact` invariant preserved** — distinct from the separate freeze-fix revert):

- **Compact half — PID-bound, own-ancestry delivery.** The Stop hook runs as a direct subprocess of its
  own session's `claude`, so at fire-time it resolves **its own** `claude` PID via an anchored-ERE
  ancestry walk (`ac_resolve_own_claude_pid`, 8-hop, `ps -o args=` — never `ucomm`, the version-string
  trap), derives the tty **live** from that PID, and verifies an identity tuple `{pid + start-time + argv}`
  plus a **PID-pinned** foreground-leader check before typing. The walk climbs only its own ancestry, so it
  can never reach a sibling. The old "any foreground claude on the tty" check (which accepted a sibling's
  claude — the bug) is replaced by the pinned check.
- **Verify-then-claim + TOCTOU re-resolve.** The sentinel is claimed (atomic `mv`) only **after** all
  verification passes — so a pre-fire abort leaves the sentinel intact for the next-Stop retry and the
  pending-handoff primer. The tty/identity is re-resolved immediately before the AppleScript `do script`;
  if it churned (sleep/wake, tab close), the hook restores the sentinel and aborts. Every failure aborts
  **without typing** — never misfire. macOS pid-reuse is defeated by the start-time component.
- **Resume half — self-driven (authoritative) + idempotent.** The SessionStart primer (`source=compact`)
  now makes self-resume the imperative FIRST action: the resumed session — which authoritatively knows it
  is itself — runs `/post-compact-resume <own-sid>` directly, independent of cross-tab delivery. The typed
  cross-tab command is now a redundant backstop. A one-shot `(sid, handoff-nonce)` marker (checked in
  `post-compact-resume-step2.sh` → `STATE=already-resumed`; written by the skill after a real resume) makes
  the self-invoke + backstop double-fire a clean no-op.
- **Proof.** `/script` suite `scripts/hooks/session-correlation-assumptions/` (6/6 PASS) proves the
  load-bearing contracts against the live machine — including the **incident-shape negative** (a sibling
  session's claude PID is rejected on this tty) and AppleScript↔`ps` tty **format parity**. Re-run as the
  regression gate. `test-auto-compact.sh` 78/0, ctx-gate 137/0, mission-bridge 60/0 — no regressions.

Files: `lib/auto-compact-sentinel.sh` (5 new helpers, no schema bump), `auto-compact-after-pre-compact.sh`
(fire-time delivery), `post-compact-primer.sh` (self-resume directive), `post-compact-resume-step2.sh` +
`commands/post-compact-resume.md` (idempotency marker), `test-auto-compact.sh` (units),
`scripts/hooks/session-correlation-assumptions/` (new).

Review-round fixes (impl-reviewer + cross-model Codex, looped to a clean "ship"):
- **Restore-on-fire-failure (codex CRITICAL):** after the sentinel is claimed, a non-`fired*` osascript
  result (no-matching-tab / not-running / error) now restores the sentinel (`mv` claim back) so the
  next Stop retries — previously it was consumed without compacting. `fired+queue-failed` does NOT
  restore (/compact did fire).
- **Test no-fire seam (safety):** the fire path resolves the caller's OWN live claude tty, which made
  the test harness fire `/compact` into the live session. New `AUTO_COMPACT_TEST_NO_FIRE` env (set by
  `test-auto-compact.sh`) runs the full resolve→verify→claim path but skips the osascript — no
  keystrokes. Can only suppress a fire, never cause a wrong-target one.
- **Identity hardening:** `PID_START` must be non-empty (fail-closed); the pre-fire recheck re-runs the
  argv-is-claude predicate alongside tty + start-time + foreground-leader.
- **Idempotency timing:** the one-shot resume marker is written FIRST (before `## Next Action`), and the
  `STATE=ok` matrix entry + Step 4 were reconciled to say so consistently.
- **ctx-gate G5-rev false-positive (unmasked latent test bug):** `[mission]` is the structured
  LOG-line *prefix* written as data via the `log` verb (not a logger/CLI verb), so it has no emit
  site by design; G5-rev now skips it like the other non-verb rows. (Its bare token is a regex
  char-class and BSD `grep -qv` mis-reports exit status on it — the generic probe was unreliable.)
- Gates after fixes: `test-auto-compact.sh` 83/0, ctx-gate 137/0, mission-bridge 60/0, /script 6/6.

## 2026-05-31 — /mission: autonomous long-build conductor (playbook over the bridge)

A new `/mission` conductor that drives a multi-part build to completion across compactions with minimal
human babysitting. It is a **playbook, not an engine**: one new `commands/mission.md` plus a few opt-in
flags — no new state machine, no new daemon. It rides the already-shipped mission-bridge spine
(`mission-write.sh` + `MISSION.<sid>.{md,log,banner}`) and the existing `/pre-compact` → auto-resume path.

- **Playbook, not engine.** Behavior lives in the command prompt; the only code touched is additive flags
  on existing commands. No bespoke orchestration runtime.
- **Two modes.** *Explicit build* (you point `/mission` at a goal/plan) and *ambient adopt* (`/mission`
  latches onto an in-flight build already in progress).
- **Adopt-stickiness via the PLAN, not new state.** Adoption is recorded as an immutable
  `MISSION MODE:` directive inside the PLAN zone. Post-compact-resume already treats the PLAN as binding,
  so the adopted-mission contract survives a compaction with **zero new state code**.
- **Loop-state resume via the bridge LOG.** The conductor reconstructs the exact part/phase/round from the
  `[mission]` LOG lines, leaning on the **idtag-with-`d<D>` anchored idempotency** so a resumed agent lands
  on the precise part/phase/round/dry-count rather than re-running or skipping work.
- **Parallel-but-INDEPENDENT reviewers (barrier-then-merge).** Reviewers run in parallel but judge
  independently; results are merged at a barrier. The impl-reviewer runs ∥ `codex-review`, enabled by the
  new additive **`/implement --no-review`** flag (so the conductor owns review fan-out; default unchanged).
- **Codex-at-high.** New additive **`/codex-review --effort high`** arg for the convergence passes; the
  default effort is unchanged.
- **2-dry convergence judged by INDEPENDENT reviewers, with VOID-on-dead-reviewer.** Two consecutive dry
  rounds close a part — but a hung or empty Codex pass is VOIDed, never banked as a dry round.
- **Durable FAIL guard.** 5 identical `[mission] FAIL …` lines (durable across compactions) → stop loud
  instead of looping.
- **Codex NEVER writes the bridge.** All Codex `-s` invocations are read-only; only the conductor writes
  via `mission-write.sh`.
- **Batched-questions DEFAULT-AWAY in autonomous mode.** The conductor never hangs on a modal; open
  decisions are parked as PENDING DECISIONS for a batched answer next session.
- **Opt-in / heavy** by design.
- Plan-reviewed by 2 independent Claude plan-reviewers (+ a Codex plan-reviewer); ~25 findings folded
  into v2.

## 2026-05-30 — Statusline: line-1 weekly-reset field + line-2 single always-present bar

Two changes, both copies of `statusline.sh` (deployed `~/.claude/` + dotfiles SoT) kept byte-identical.

**Line 1.** Strip the `(1M context)` parenthetical from the model display (the 1M window is assumed) and
add a `wk→<day> <time>` weekly-reset field in the slot it vacated — e.g. `wk→6th 4pm`, derived from the
`anthropic-ratelimit-unified-7d-reset` epoch (`seven_d_reset`) via `date -r` + a pure-bash ordinal suffix.
The `% wk` percentage stays. printf widened from 6 to 7 fields.

**Line 2 — collapse the flaky two-bar renderer into one always-present bar.** Root causes of the old
"random" behavior: (a) a 5-min `last_tick` `sys.exit` failsafe blanked the bars mid-task → flipped to the
old session label; (b) `on-stop.sh` deleted the state file 5s after each prompt → no bar between prompts;
(c) `on-prompt-submit.sh` set the bar label by regex-scraping the first `/…` token from the prompt, which
captured typed **file paths** (e.g. `/migrations/…`) — the "inaccurate" label. Fixes:
- Single bar, source by specificity: determinate beacon → determinate to-dos → indeterminate beacon →
  honest spinner. A bare beacon (emit-beacon defaults total=0) no longer shadows a real to-do bar.
- **Never blank**: renderer prints the session label or `idle` when not active; a hard bash fallback prints
  `idle` even on a python crash / absent file. Line 2 is present in every session/repo from open.
- 5-min failsafe removed → replaced by a 30-min demote-to-idle guard (catches a misfired Stop hook without
  the mid-task vanish or a runaway timer).
- `on-stop.sh` now marks the file `active:false` (atomic `os.replace`) instead of deleting it → no flicker.
- State schema v2 (`active` flag); renderer treats missing `active` (v1 files) as active when
  `prompt_started_at` is fresh, so live sessions don't blink across the upgrade.
- `on-prompt-submit.sh`: dropped the slash-scrape + `outer_command`/`current`/`task_spawns`.
- `on-task-spawn.sh`: stripped to beacon-claim + `last_tick`; removed the spawn-count bar and the
  `expected_subagents` frontmatter glob (that field is now inert — not swept from command frontmatter).
- `on-todo-write.sh`: sets `active:true` defensively. `on-session-start-cleanup.sh` unchanged (no seed —
  the renderer's own `idle` fallback guarantees presence).
- Reviewed by 2 parallel plan-reviewers + meta-pass; 7 render gates pass (line-1 strip+`wk→6th 4pm`,
  active todos, beacon, indeterminate-beacon-doesn't-shadow, idle→label, never-blank→`idle`, stale→idle).
- Docs: `STATUSLINE.md`, `PROGRESS-BARS.md` (rewritten), `ARCHITECTURE.md` hook table updated.

## 2026-05-31 — REVERT: native /compact focus instruction (auto-resume freeze)

Same-day revert of the Task-8b "complementary channels" change from the mission-bridge ship below.
**Incident:** dentall session `fca8c4ab`, the first compaction after the change auto-synced (7:07 PM PDT
/ 02:07Z). The Stop hook fired `/compact <focus instruction>` and typed the queued
`/post-compact-resume` (`fired+queued-resume`, osa_exit=0); compaction finished at 7:09 PM — but the
queued resume **never auto-submitted**, leaving the session frozen on unsubmitted draft text for **27
minutes** until the user re-ran it by hand (7:36 PM, `step2_terminal state=ok`).

**Root cause:** the resume is typed *during* compaction with only a 0.3s `PTY_DELAY` and relies on the
TUI buffering it as next-turn input. Adding a long trailing argument to `/compact` shifts the timing
enough that the resume's Enter intermittently fails to register as a submit. It's a *race the longer
command widens*, not a guaranteed break (session `49d80a3a` fired the same instruction once and resumed
fine) — which is exactly why it slipped past review: **no test asserts the `/compact` do-script text**,
and the Task-14 live pre-flight ("prove the build accepts `/compact <arg>` with the queued resume") was
never run. This freeze WAS that pre-flight, failing.

- **Revert:** `auto-compact-after-pre-compact.sh` fires bare `do script "/compact"` again. Bare /compact
  has resumed cleanly across every logged run. The auto-resume queue is the load-bearing
  overnight-autonomy mechanism and outranks the (nice-to-have) complementary-channels instruction.
- **Guard:** an inline comment forbids re-adding a `/compact` argument without first proving, repeatedly
  in the live build, that the queued resume still auto-submits after it.
- **Not changed:** `PTY_DELAY` stays 0.3s (bare /compact has never frozen; no evidence a bump is needed).
  Tunable via `CTX_GATE_PTY_DELAY_SEC` if a future race appears.
- **Test coverage:** `test-auto-compact.sh` 71/0 (the harness uses a synthetic TTY and does not assert
  the command text — flagged as a coverage gap; the behavior is PTY-timing-dependent and not unit-testable).

## 2026-05-30 — mission-bridge: zero-information-loss durable cross-compaction "mission" spine

The chain primitives (2026-05-27) made compactions near-lossless for the *handoff narrative*, but an
overnight agent still had no durable, append-only place to carry the **standing PLAN, durable notes,
plan-challenges, and pending decisions** verbatim across 5–15 compactions — those lived only in the
volatile handoff prose and degraded with each squash. mission-bridge adds a durable on-disk spine at
the canonical anchor (`dirname(git-common-dir)`, co-located with `CLAUDE.local`): a human-editable
`MISSION.<sid>.md` (fenced PLAN / DURABLE NOTES / PLAN CHALLENGES / PENDING DECISIONS zones), an
append-only `MISSION.<sid>.log` sidecar, and a precomputed `MISSION.<sid>.banner`. It **auto-activates
at chain link >= 2** (the point at which a session has survived its first compaction and continuity
actually matters), is mutated by exactly one allowlisted CLI, and is surfaced to the next session by
the SessionStart primer. #1 priority is ZERO INFORMATION LOSS + fail-LOUD; the feature must NEVER
interrupt the autonomous `/pre-compact` workflow (no permission prompts, no hangs, never abort).

- **The spine.** `lib/mission-bridge.sh` owns the format; `mission-write.sh` is the sole allowlisted
  mutator (byte-locked invocation prefix matched by a `Bash(bash …/mission-write.sh:*)` allow rule, so
  it runs prompt-free under `defaultMode:auto`). Main file carries nonce-qualified zone fences
  (`<!-- MZONE:PLAN n=<nonce8> -->`) and a LOCKED last-line marker
  (`<!-- MISSION schema=v1 sid=<sid> nonce=<uuid> plan_hash=<hex16> -->`) parsed from the LAST match.
  Per-mutation backups land in `.mission-backups/` (pruned to newest 25 + an immutable
  `MISSION.<sid>.birth.md` the prune never deletes).
- **PIVOT A — precompute the banner at WRITE time; the primer does near-zero work.** The original
  design had the SessionStart primer verify+read+cap the mission file, but that hook has a hard **5s
  timeout** and a SIGKILL there emits NOTHING = fail-SILENT (the worst outcome for an info bridge), and
  folding the banner into `BANNER_PREFIX` never reached the no-handoff / rc=1 / cwd-exit paths that emit
  no JSON at all. **Now:** `/pre-compact` (write side, no timeout) renders a tiny bounded
  `MISSION.<sid>.banner` (PLAN slice <= 4000 bytes, line-snapped, + last-5 log lines, pre-capped and
  pre-verified); on a verify failure it writes a LOUD banner, never a silent one. The primer ONLY `cat`s
  that small file and emits it via an explicit `jq -n` on **every** exit path (including the bare
  `exit 0`s — the rc=2 no-sentinel sub-branch, the symlink exit, and the oversize exit). Near-zero primer
  work removes the timeout risk; explicit emit removes the silent-path risk.
- **PIVOT B — LOG sidecar: byte-capped, anchored-idempotent, torn-line-healed, lifecycle-coupled,
  rotating.** The append-only `O_APPEND` log is the hot path and is the zero-loss guarantee (`>>` can
  never lose prior entries the way a read-modify-rewrite of the main file could). But it is hardened:
  each entry is **byte-capped** (not char-capped) to `< 480` bytes (well under PIPE_BUF, with `iconv -c`
  UTF-8 repair) so a concurrent compaction can never tear a record; an oversize entry is rerouted to the
  locked main file rather than risk a torn `> PIPE_BUF` append; idempotency is keyed on a **leading
  anchored** `^<tag>\t` field (not a free `grep -qF`, which a body-quoted id could falsely suppress); the
  log wrapper ensures the main file + manifest pointer exist FIRST (no orphan log); a non-newline last
  byte is healed before append (records never fuse); and the log **rotates** at 256KB into
  `.mission-backups/…log.<utc>.gz` (zero-loss archive, never truncation).
- **Hash is detection-only, not tamper-proof.** `plan_hash` exists to DETECT drift/corruption, not to
  resist a motivated editor. The stream hasher prefers `shasum -a 256`, falls back to `sha256sum`, and
  **fails LOUD if neither exists** (refuses to hash rather than emit something unverifiable); a selftest
  rejects a machine-dependent mismatch. It deliberately **never falls back to `cksum`** (CRC is not a
  cryptographic digest and would give false confidence).
- **"Hand-editing the handoff/mission file is NOT running the skill."** The mission file is
  human-editable, but only the `/pre-compact` skill mines context, appends the ledger, renders the
  banner, and arms auto-compact. The ctx-gate SOFT/IMPORTANT/FORCE nudges now state this explicitly so an
  agent never substitutes a manual edit for the skill run.
- **fail-LOUD is the deliberate exception to ctx-gate's fail-open posture.** Everywhere else in the hook
  system, an unreadable sidecar fails OPEN (stay silent rather than deadlock the agent). For mission-bridge
  the inverse is correct: silent information loss is catastrophic for a continuity bridge, so corruption,
  a missing hash tool, a pointer-set-but-file-missing condition, and a banner verify failure all surface
  LOUDLY (stderr + a CRITICAL banner the primer emits). The CLI still `exit 0`s so the caller is never
  aborted — loudness is in the *content*, not the exit code.
- **Native `/compact` focus instruction (complementary channel) — SHIPPED THEN REVERTED 2026-05-31.**
  Briefly fired `/compact <instruction>` so the model-side summary and disk-side mission spine wouldn't
  duplicate. Reverted same day after a field freeze (see the 2026-05-31 entry above): the trailing
  argument intermittently broke the queued `/post-compact-resume`. Native `/compact` is bare again.
- **Test coverage.** New `test-mission-bridge.sh` (>= 30 tests: marker read from the LAST line; a PLAN
  containing `<!-- MISSION… -->` / `<!-- /MZONE:PLAN -->` / `## ` round-trips nonce-fence-safe; body
  pseudo-marker → loud corruption; multibyte LOG byte-cap `< 512`; anchored idempotency where a
  body-quoted id does NOT suppress a real entry; rotation archives rather than deletes; orphan-lock
  reclaim after a simulated dead pid; merge preserves `mission_path` across a seq bump; recovery
  re-derives it; banner emitted on the no-handoff primer path; pointer-set-file-missing → loud; birth
  backup exists and survives prune). Plus the 8-test `scripts/hooks/mission-bridge-assumptions/` suite
  (`01`–`08`) proving the OS/shell **zero-loss contract** at the substrate level: sub-PIPE_BUF concurrent
  `>>` appends never interleave/tear, marker+zone parse survives adversarial content, lock reclaim after a
  dead holder, mutate atomicity, manifest mission_path write rules, primer emit on every path, append
  after a torn last line, and write-failure surfacing.
- **Rollback.** The feature is purely additive. It only activates at chain link >= 2, so it is inert for
  any single-session (never-compacted) run. To disable entirely: remove `lib/mission-bridge.sh` +
  `mission-write.sh` + the `mission-bridge-assumptions/` suite, and revert the additive
  `.gitignore`-converge and primer-emit hooks (the `MISSION.*` gitignore lines and the guarded
  `MISSION_PREFIX` emit blocks in `post-compact-primer.sh`). No existing behavior changes when the spine
  is absent.

## 2026-05-28 — ctx-gate follow-ups: seam-opportunistic SOFT + stale-broker-after-compact fix + statusline SoT sync

Two field-reported failures from the threshold tuning earlier today, plus a latent landmine found
while debugging the second. All three are coupled: the SOFT fix makes the agent checkpoint more
readily on seam signals, which *amplifies* the harm of a stale-high context reading — so the
broker fix had to ship in the same commit, not after.

- **Part A — seam-opportunistic SOFT (regression fix).** The morning's tuning added an absolute
  "Act only on IMPORTANT or FORCE" clause to the SOFT message (`ctx-gate-on-prompt-submit.sh:111`)
  and the interpretation rule (`commands/pre-compact.md` Rules). It contradicted the same message's
  own seam guidance and, being absolute, won — so an agent at a perfect seam in the SOFT band
  (clean tree, merged PR, about to start heavy work) did NOT checkpoint and pushed into heavy work,
  guaranteeing a forced checkpoint mid-task past FORCE. Root cause: we over-corrected the *repetition*
  complaint (correctly fixed by the 5% rate-limit) with a clause that also killed legitimate
  seam-checkpointing. New SOFT message + interpretation rule are **seam-opportunistic**: don't
  interrupt mid-task, don't surface ctx% as chatter, but checkpoint NOW if at a natural seam —
  including *about to start a large context-heavy task* (the strongest seam: starting heavy work in
  SOFT guarantees crossing FORCE mid-run). Thresholds, rate-limit, FORCE/IMPORTANT messages unchanged.
- **Part B — stale context% after compaction (URGENT, wasted real work).** The ctx broker sidecar
  `~/.claude/progress/ctx-<sid>.txt` is written by the statusline from the harness context-used %,
  and the writer preserves last-known-good on transient empty reads. `/compact` preserves the
  session_id, so post-compaction the same-named sidecar holds the PRE-compaction value until the
  statusline's next render — and the first post-compact `UserPromptSubmit` reads it DETERMINISTICALLY,
  firing a false IMPORTANT/FORCE nudge. Field agent at ~14% real context saw "69% — IMPORTANT",
  trusted it, and prematurely ran `/pre-compact` again with most of the budget free. **Fix:**
  `post-compact-primer.sh` (the SessionStart hook) now deletes the sidecar on `source=compact|clear`
  (the two boundaries where context drops sharply while the sidecar persists), so the reader fails
  open (silent) until a fresh value is written. Deletion — not an mtime-staleness skip — because the
  staleness is **semantic, not temporal**: a fast compact yields a young-but-stale sidecar an mtime
  check would miss; deletion is age-independent. `resume`/`startup` are NOT invalidated (their sidecar
  reflects real current context, or the SID is new). New log verb `handoff:ctx_broker_invalidated`
  registered in `LOG_VERBS.md`. Agent-facing prior added to `templates/CLAUDE.md`: a missing sidecar
  means "context unknown," not high — distrust any high reading on the first post-compact turn.
- **Part C — statusline source-of-truth sync (latent landmine).** Found while debugging Part B: the
  deployed `~/.claude/statusline.sh` contains the ctx-gate broker-write block (added 2026-05-23) but
  the dotfiles source-of-truth `scripts/statusline.sh` was never back-ported (0 `CTX_BROKER` refs vs
  the deployed 8). The repo's source-of-truth was missing the writer the entire ctx-gate system
  depends on — a future manual re-deploy from dotfiles would have silently killed ctx-gate. Block
  back-ported verbatim; `grep -c CTX_BROKER scripts/statusline.sh` now returns 8. Deployed file left
  untouched (it's the working artifact). NOTE: the two statusline files are hand-maintained with no
  automated sync, so this divergence can recur — a deploy/diff-check step is a worthwhile follow-up.
- **Test coverage:** `test-ctx-gate.sh` 135 → 137. New `3d-1` (source=compact deletes stale sidecar →
  subsequent submit silent) and `3d-2` (source=resume PRESERVES sidecar). Test `3c-10` strengthened
  with a regression lock: the SOFT message must contain "act at the next seam" and must NOT contain
  "Act only on" (catches a future revert of Part A). All four harnesses green: **137 / 4 / 71 / 10 = 222/0.**
- **Rollback:** covered by the existing `ctx-thresholds-pre-tuning-2026-05-28` tag (reverts the whole
  2026-05-28 ctx-gate line); `git revert <sha>` for a surgical undo of just this combined ship.

## 2026-05-28 — ctx-gate threshold tuning (50 SOFT / 65 IMPORTANT / 75 FORCE) + 5% bucket rate-limit

LLM accuracy degrades meaningfully past ~70% ctx, but the original 75/85 thresholds put the most
critical wrap-up work in the worst-quality zone of every chain. The chain primitives shipped on
2026-05-27 (`lib/handoff-chain.sh` + per-session ledger + cross-link Decisions/Footguns/What-We-Tried
propagation) made compactions near-lossless, so the cost/quality trade-off shifted in favor of
compacting earlier. This tunes the thresholds and also fixes the cadence problem (one nudge per
user turn was noisy — 30+ identical SOFT pings in a long 50-64% stretch).

- **Threshold tune (50/65/75):** defaults in `scripts/hooks/lib/ctx-gate-config.sh` updated. SOFT
  unchanged at 50%; IMPORTANT 75→65; FORCE 85→75. Override env vars (`CTX_*_PCT_OVERRIDE`) still
  work for tests + manual experimentation.
- **Zone-bucket rate-limit (5%):** `scripts/hooks/ctx-gate-on-prompt-submit.sh` fires SOFT and
  IMPORTANT only when the 5% bucket changes (50/55/60 for SOFT; 65/70 for IMPORTANT). FORCE
  always fires every turn (action-required — persistent reminder is correct). Per-session marker
  at `~/.claude/progress/.ctx-zone-bucket-<sid>`, GC'd by the existing 720-min cleanup glob.
  Handles both forward progress (climbing ctx) and post-compaction reset (silent-zone visit leaves
  marker stale, then lower bucket re-fires).
- **SOFT wording extended:** added self-restraint clauses ("Do NOT interrupt active work; do not
  surface ctx % to the user; do not start /pre-compact in response. Act only on IMPORTANT or
  FORCE.") — codifies the interpretation rule into the message body itself.
- **Interpretation rule:** new paragraph in `commands/pre-compact.md` Rules section locks the
  SOFT-as-FYI semantic across every agent invoking `/pre-compact`. SOFT is observational only;
  IMPORTANT is "at the next natural seam"; FORCE is "immediately, before anything else."
- **Stale-reference sweep:** updated 3 doc rows in `scripts/hooks/LOG_VERBS.md` (PCT-range cells),
  and stale "85%" comments at `ctx-gate-precompact-safety.sh:76`, `lib/handoff-config.sh:29`, and
  the parenthetical comment at `ctx-gate-on-prompt-submit.sh:42`. The `test-ctx-gate.sh` file-header
  comment and the `§2.5 step 6` / `step 1` / `step 7` inline comments were updated to match the new
  threshold model.
- **Measurement next-step:** the chain ledger's `ctx_pct=<%>` field records ctx at every
  `/pre-compact` firing — read `~/.claude/chains/<sid>.log` over the next few sessions to see
  actual firing distribution and decide whether to tighten further (FORCE 75 → 70) or relax.
- **Rollback:** `git reset --hard ctx-thresholds-pre-tuning-2026-05-28` (tag at SHA `a965592`,
  set BEFORE any threshold edits).
- **Test coverage:** `test-ctx-gate.sh` boundary tests `3c-2/3/4` updated (ctx=74→IMPORTANT,
  ctx=75/84→FORCE); existing `3c-8` and `§2.5 step 6` labels corrected ("SOFT suppressed" → "IMPORTANT
  suppressed" since ctx=65 is now IMPORTANT). 5 new bucket-rate-limit regression tests added:
  `3c-9` (bucket-skip-same SOFT), `3c-10` (bucket-fire-on-transition SOFT, asserts full message
  body), `3c-11` (bucket-fire-on-transition IMPORTANT), `3c-12` (FORCE-bypass strengthened: three
  same-bucket invocations all FORCE + marker file MUST NOT exist), `3c-13` (bucket-reset-after-silent-exit:
  asserts marker stays at 14 across a ctx=35 silent visit, then lower bucket=10 re-fires).
- **All harnesses green:** `test-ctx-gate.sh PASS: 135 FAIL: 0` (was 130, +5 new tests),
  `verify-test-integrity.sh PASS: 4 FAIL: 0`, `test-auto-compact.sh PASS: 71 FAIL: 0`,
  `test-chain-primitives.sh PASS: 10 FAIL: 0`. Total **220/0** across all four harnesses.

## 2026-05-27 — `/pre-compact` overnight-autonomy primitives (chain manifest, ledger, banner, halt-advisory)

Layered on top of the same-day canonical-anchor work to give an agent the continuity primitives it
needs to run **overnight** (8+ hours, 5–15 compactions) on a heavy dev workload without losing the
thread. **All primitives are observational** — they surface information, they never gate or refuse
anything the agent/user wants to do. No new sub-commands.

- **New `lib/handoff-chain.sh`** with 4 primitives: `chain_manifest_path`, `chain_manifest_read`
  (validates with `jq -e .`; auto-rebuilds from the ledger on corruption with
  `recovered_from_ledger:true`), `chain_manifest_write` (atomic `tmp+rename`), and
  `chain_ledger_append` (pure `>>`, 9 locked TSV fields, real-tab delimiter via ANSI-C `$'\t'`).
  SID sanitized defensively inside the lib; bash 3.2.57 compatible; no `ctx_gate_log` dependency.
- **Chain state at `~/.claude/chains/<session_id>.{json,log}`** (mode 700). Manifest is slim (9
  fields: chain_id, started_at, north_star, north_star_source, current_seq, last_handoff_path,
  last_heartbeat_at, status, host) — no history arrays (YAGNI). Ledger is append-only TSV, never
  overwritten, includes `north_star_first_120` so the goal survives manifest corruption.
- **`/pre-compact` Step 3.B** resolves the chain manifest (or creates it on first run) inside a
  tolerant subshell (`set +e`) so chain failures never abort the skill. North-star resolution is
  3-tier: `$ARGUMENTS` (minus pass flags) → most-recent fresh brief at
  `$CANONICAL_ROOT/tmp/briefs/` with `## Direction` (falls through on multi-brief near-tie within
  6h to avoid guessing) → agent-supplied from the in-flight `## Active Task` extraction. Verbatim
  string cached at chain birth (no `<pending…>` placeholder ever).
- **`/pre-compact` Step 4.G** runs a narrow halt-advisory detector over the visible transcript
  (window-scoped to turns dated > `last_heartbeat_at`, excluding sub-agent tool outputs and the
  skill's own bash). Trips only on: same-cmd+same-error 5× with no commit AND no file edit; 2+
  permission denials on the same tool; self-emitted "I cannot proceed" + 3 unresolved turns; or
  3+ consecutive same-class API errors. **Never trips on iterative debugging** (any file edit
  between failures = healthy work). Output is two env vars the Step 3.B block reads; the next
  handoff opens with a `## Halt Advisory` block (informational, agent has full agency).
- **Halt auto-clear, locked semantics**: clears iff the visible transcript has a turn with
  `role:user` AND timestamp > halt timestamp AND body is NOT the bare `/pre-compact` invocation.
  Agent self-talk never clears halt.
- **`/pre-compact` Step 6A** prepends `## Chain Status` to every handoff (chain id 8-char prefix,
  started_at, elapsed, link N, north star verbatim, current active task, last 5 ledger entries —
  so drift between original goal and current direction is always visible). When halt is set,
  `## Halt Advisory` goes above it. Decisions + Footguns propagate cross-link additively (caps 40
  / 30, drop oldest low-confidence/oldest first); What We Tried bounded at 20 with asymmetric
  retention (preserve all `abandoned because <reason>` and footgun entries; drop oldest `kept`).
  Propagation marker `<!-- propagation-boundary v1 -->` in the template delimits parent-carried
  from this-session entries.
- **SessionStart primer** sources the chain lib and prepends a one-line banner
  (`Chain <id8> | Link <N> | Elapsed <Hh Mm> | Goal: <80c> | Status: <s>`) to ALL three
  `additionalContext` emissions (the rc=2 missing-file warning, rc=3 hardlink warning, and main
  case). Heartbeat staleness >90min appends a "verify a resume wasn't missed" advisory. Bash-side
  `date` arithmetic (BSD-first, GNU fallback) so the elapsed math doesn't depend on jq's
  `fromdateiso8601`; negative elapsed clamped at 0; `HEARTBEAT_AGE` sanitized to int.
- **What was deliberately NOT built**: no `/pre-compact unhalt` or `/pre-compact set-goal`
  sub-commands (overconstraint per user); no code-enforced north_star immutability (soft, doc-only);
  no sub-agent context detection (the `[ -t 0 ]` heuristic is non-functional in the Bash-tool
  subprocess, and sub-agents share session_id so an extra manifest update would be a benign noop
  anyway); no cross-platform resume (Mac/Terminal.app workflow unchanged); no predictive 75%-ctx
  auto-fire (the existing PreCompact safety-net is the trigger).
- All three existing test harnesses still pass with 0 FAIL (test-ctx-gate 130, integrity 4,
  auto-compact 71); chain primitives smoke (round-trip, ledger append, corrupt-recover, tab
  delimiter, sanitization) all green.

## 2026-05-27 — `/pre-compact` canonical-anchor, concurrency-safe, cwd-invariant handoff resolution

Fixed a real **wrong-load**: `/pre-compact` could adopt a *foreign chain's* handoff as its parent
when the SID-tagged file lived in a different worktree than cwd and an mtime fallback then grabbed the
newest `CLAUDE.local.*.md`. Hardened the whole writer/reader location + identity model so any agent,
in any worktree/cwd, can run `/pre-compact` concurrently and repeatedly — "it just works."

- **Canonical anchor** (`lib/handoff-locate.sh`, new): the handoff always lives at
  `dirname(git-common-dir)` — the repo's main working root, identical from every worktree — resolved
  with a common-dir identity round-trip cross-check (→ `show-toplevel` → `pwd` fallback). `CANONICAL_ROOT`
  is resolved once in Step 3.B and persisted in the SID scratch; Steps 6A/6D/8, the `.prev` snapshot,
  and the paste/migration prose READ it back (no per-subprocess re-derivation → no drift).
- **Parent = marker-sid only:** Step 3.B accepts a parent ONLY when the canonical-anchor
  `CLAUDE.local.<MY_SID>.md` carries an END-OF-HANDOFF marker whose `sid=` equals this session.
  **The mtime fallback is deleted** — mtime never selects a parent. No match → seq 1.
- **Reader (`lib/handoff-resolve.sh`):** probes cwd → show-toplevel → canonical anchor (deduped by
  physical path), marker-bound and fail-closed per candidate; rc=3 (hardlink) only when the
  *marker-matching* candidate is hardlinked. No worktree enumeration (the anchor subsumes it). The
  SID-unknown legacy alias path is deliberately NOT broadened.
- **Single marker-SID extractor** (`_resolver_extract_marker_sid`) moved to `handoff-locate.sh` and
  shared by the reader, `writer-verify.sh`, and the writer's Step 3.B (no duplicate, first-occurrence
  anchored).
- **Concurrent `.gitignore`:** atomic `mkdir` lock under the shared git-common-dir + idempotent
  re-grep converge (the converge is the correctness guarantee; `flock` avoided — absent on macOS).
- Resolution failures degrade to refuse / `no-handoff`, never wrong-load. All three test harnesses
  green (ctx-gate 130, integrity 4, auto-compact 71); canonical-root agreement proven across a linked
  worktree end-to-end.

## 2026-05-26 — Assumption tests (`/script` overhaul) + always-on `/plan` assessment

Reworked `/script` and wired it into `/plan` as an always-considered (but never forced) step.

- **`/plan` Step 5** now ALWAYS emits a visible assumption-test assessment line in one of three states — candidates surfaced (→ run `/script`), zero surfaced (explicit skip + reason), or unavailable (degraded reviewer path). The decision is now a reviewable artifact, not a silent omission. It never auto-generates tests.
- **`plan-reviewer`** now ALWAYS emits the `## Assumption-Test Candidates` section (was gated on ≥3 findings); emits `_None surfaced_` when empty. Parallel reviewers' sections are unioned in the merge step.
- **Rename:** "smoke scripts" → **assumption tests** throughout (`/script`, `plan.md`, `plan-reviewer.md`); tag `[SMOKE-CANDIDATE]` → `[ASSUMPTION-TEST]`; output dir `scripts/<feature>-smoke/` → `scripts/<feature>-assumptions/`. These are kept *learning tests*, not broad-and-shallow "smoke tests" and not disposable "spikes". (Safety env-gate var names keep `_SMOKE_ALLOW_` deliberately — they mirror real per-project conventions.)
- **New trust discipline in `/script`:** rule 9 **negative control** (prove each test goes RED when the assumption is false; synthetic-injection escape for infra-fixed contracts); rule 10 scoped **environment fingerprint** for drift detection; **startup orphan-reaper** (stable namespace marker + age) alongside per-run-UUID cleanup; softened the cleanup STOP rule to allow un-rollback-able side effects via tag-and-reap + disposability check; `run-all.sh` hardened with `set -uo pipefail` + `timeout 60` + 124→3 remap; read-only default for FOUNDATION probes.
- **Always-on adversarial catalog review** (Step 3.5) before writing tests — runs in parallel with directory/run-all/README scaffolding; uses a self-contained prompt. `expected_subagents` bumped to 2.
- **Expanded risk lenses:** added TIME/ORDERING, SECURITY/ISOLATION, MIGRATION/CONSISTENCY, VALUE-DOMAIN/ENCODING, and split out production OBSERVABILITY; reframed as a generative checklist, not a partition. Optional single thin-integration test for composition coverage.
- **Split:** the risk-lens catalog, A3 worked example, and anti-patterns moved out of the command into new `docs/script-reference.md` to keep `/script` lean. `/script` now documented in `docs/COMMANDS.md` (was absent).

## 2026-05-13 — Auto-compact after `/pre-compact`

Added a Stop hook (`scripts/hooks/auto-compact-after-pre-compact.sh`) that fires
`/compact` into the originating Terminal.app tab after `/pre-compact` finishes,
so the user can run `/pre-compact`, walk away, and return to a compacted session.

- **Arming** lives in `scripts/hooks/arm-auto-compact.sh`, called from `/pre-compact`
  Step 9.0. Writes a per-session JSON sentinel at `~/.claude/progress/auto-compact-<sid>.json`
  containing `schema_version`, `target_tty`, `originating_command`. Filesystem mtime
  is the source of truth for arming-time (used by the >12h prune).
- **Firing** uses AppleScript `do script "/compact" in foundTab` — writes to the tab's
  PTY input, not a System Events keystroke. No focus race, no Accessibility requirement,
  only Terminal Automation permission (auto-prompted on first use).
- **Hardening:** anchored TTY regex; argv-passed osascript (no string interpolation);
  symlink-rejected, size-bounded, schema-validated sentinels; atomic `mv` claim
  prevents double-fire; foreground-process check (`ucomm`-based) refuses to type if
  `claude` isn't in the foreground process group of the target TTY; jq-based settings
  registration check guards against post-uninstall orphan sentinels; perl-alarm timeout
  on the first-run Automation probe so /pre-compact never hangs.
- **Platform guard:** refuses to arm on non-Darwin, non-Terminal.app, tmux, screen.
- **Opt-out:** `no-auto-compact` / `--no-auto-compact` / `no auto compact` skips arming
  and disarms any prior sentinel from the same session.
- **Dry-run:** `--dry-run` resolves the full pipeline (TTY + session id + guards) and
  reports what WOULD be armed, without writing a sentinel.
- **Diagnostics:** `~/.claude/logs/auto-compact.log` (mode 600, bounded ring at ~64KB).
- **Uninstall:** `scripts/hooks/uninstall-auto-compact.sh`.
- **Tests:** `scripts/hooks/test-auto-compact.sh` covers AppleScript injection,
  symlink, schema, double-fire, oversized payload, jq operator-precedence regression,
  ERE-grep regression, opt-out matchers, tmux/non-Apple_Terminal refusals, concurrent
  claim race, idempotent lib source guard, log file mode 600, multi-word `comm`
  brittleness, and the skill-prose invocation contract.
- Shared lib at `scripts/hooks/lib/auto-compact-sentinel.sh` — single source of truth for
  sentinel paths, schema, validation.

## 2026-05-06 — Per-Session Statusline Label

Added a dimmed second line to the statusline (`scripts/statusline.sh`) sourced
from `~/.claude/session-status/<session_id>.txt`. Lets the user tell apart
5–10 simultaneous Claude Code windows by `Client › Project › current work` at
a glance.

### Added
- **`scripts/statusline.sh` § 7**: optional line 2 reads the per-session label
  file, sanitizes session_id with `tr -cd 'A-Za-z0-9_-'` (path-traversal safe),
  and truncates to 100 code points via Python (Unicode-aware, so multi-byte
  chevrons survive). Line 2 is omitted entirely when the file is missing.
- **`CLAUDE.md` § Per-Session Status Label**: behavioral rule telling Claude
  when and how to write the label file. Discovers session_id via the most
  recently modified `~/.claude/projects/<encoded-pwd>/*.jsonl` (the
  `$CLAUDE_SESSION_ID` env var is documented as not reliably exposed to the
  Bash tool).
- **`~/.claude/session-status/`**: new local directory (mode 700) that holds
  one `<session_id>.txt` file per active window. Not tracked in this repo —
  contents are session-scoped and may include client names.

### Format
```
Client › Project › what's happening right now
```
Chevron `›` separator, single space each side, ≤ 100 chars. Use `Internal`
for self/team work, `Self` for personal, repo name when no codename exists.

### Plan archive
See `tmp/done-plans/2026-05-05-per-session-statusline-label.md` (in the
TOOLS workspace, not this repo) for the full design + 13-finding review trail.

## 2026-04-30 — Master Rebuild

A 7-phase rebuild that decontaminated the repo of project-specific assumptions
("estim8r" lock-in, hardcoded `/Users/nickpardon/` paths, foreign-codebase
references) while preserving every team-built skill verbatim. Validated against
4 plan-reviewer passes (41 recommendations all incorporated).

### Removed (project lock-in)

- **`~/.claude/settings.json`**: stripped 50+ estim8r-specific entries
  (`/Users/omidzahrai/Desktop/CODE/estim8 recent/` paths, `backend.*` module
  allowlist for trade_extraction/material_pricing/etc., hardcoded ports
  `localhost:5174/8000/3001`, `/tmp/estim8r_jobs.json` job ID). Replaced with
  minimal generic permissions.
- **`commands/master-review.md`**: replaced 6 hardcoded
  `/Users/nickpardon/claude-hybrid-control/` paths with
  `${CLAUDE_HYBRID_CONTROL_HOME:-$HOME/claude-hybrid-control}` env var.
  Replaced 5 inline Codex CLI calls with portable `codex_invoke()` wrappers
  that auto-rotate `CODEX_HOME` profiles. Replaced `localhost:8080` page-list
  with project dev-server discovery.
- **`commands/antigravity.md`**: replaced 7 hardcoded `/Users/nickpardon/`
  paths with the same `CLAUDE_HYBRID_CONTROL_HOME` env var.
- **`commands/renderdeploy.md`**: replaced 4 `estim8r-api`/`estim8r-app`
  example references with generic `myapp-api`/`myapp-web`.
- **`agents/{codebase-explorer,implementer,implementation-reviewer,plan-reviewer,researcher}.md`**:
  REPLACED wholesale with `dcouple/Pane` upstream versions to eliminate
  estim8r-flavored review prompts (e.g. `plan-reviewer.md:31` previously read
  *"Are all 14 trades handled? (electrical, plumbing, hvac, ...)"* — now reads
  *"Completeness — Are there gaps? Missing error handling, edge cases..."*).
  Git history confirmed the user had not modified these files; the content
  was inherited estim8r-flavored from the original fork.
- **`commands/parsa/cl/*` (7 files)**: deleted. These were HumanLayer
  foreign-codebase prompts not actually used by the team.
- **`commands/parsa/review/principles/architecture-backend.md`** + **`all.md`** +
  **`documentation.md`**: generalized `authenticatedHandler`/`BaseService`/
  `ApiError` from hardcoded pattern names to project-specific patterns the
  reviewer must discover before flagging violations.
- **`CLAUDE.md` routing table**: removed 7 `parsa:cl:*` phantom skill entries.

### Added (Pane upstream gems + new lens agents)

- **`agents/research-dossier-writer.md`**: imported from Pane. PRP-style
  research dossier sub-agent used by the new `/plan` 3-artifact pipeline.
- **`commands/share-fix.md`**: imported from Pane. After shipping a fix, draft
  human-sounding GitHub issue comments for ecosystem reach-out.
- **`commands/plan_base.md`**: replaced with Pane's evidence-contract template
  (Verified Repo Truths with `Fact:`/`Evidence:`/`Implication:` shape).
- **`settings.json.template`**: NEW teammate-shareable baseline at
  `~/.claude-dotfiles/settings.json.template`. (`~/.claude/settings.json` is
  per-machine and not tracked in this repo, so the template is the
  shareable baseline for fresh setups.)
- **`agents/lens-{single-pattern,circular-deps,tanstack-query,architecture-frontend,architecture-backend,self-contained}.md`**:
  6 new specialized review lens agents wired into `master-review.md`.
  - `lens-single-pattern` and `lens-circular-deps` are **always-on** (run in
    Phase 1 + every Phase 3 verification round).
  - The other 4 are **stack-gated** (run in Phase 1 only when the matching
    `HAS_TANSTACK_QUERY`/`HAS_APP_ROUTER`/`HAS_AUTHED_HANDLER`/`HAS_UI_PROJECT`
    detection signal is non-empty). Each lens self-gates in its own prompt
    and returns `(skipped — pattern not detected)` when the signal is empty.

### Changed (skill MERGEs with Pane upstream patterns)

For each, the team's additions were enumerated first, then synthesized onto
Pane's structure:

- **`commands/plan.md`**: adopted Pane's 6-step pipeline (Mandatory Repo Audit
  → Clarify → External Research → Draft 3 artifacts → Reconcile → Save → Review
  with dual Claude+Codex lanes → Return). Preserved team's Step 0 discussion-
  brief loading from `./tmp/briefs/`.
- **`commands/simple-plan.md`**: adopted Pane's primary-implementer rule and
  dual-lane review with Codex fallback.
- **`commands/implement.md`**: adopted Pane's executor resolution
  (Claude/Codex), parallel review gates (Claude `implementation-reviewer` plus
  two direct `codex exec -s read-only --ephemeral` calls — one straight review,
  one adversarial — when `command -v codex` succeeds; the project-wide
  `/codex-review` skill remains the user-facing entry point), and Step 5.5
  schema migration handling. Replaced Drizzle-specific `npm run db:diff:dev`
  and `npx nx build` with stack-detection language.
- **`commands/prepare-pr.md`**: added Pane's Step 2.5 (production schema
  migration SQL with stack-detection) and Pre-Merge Testing + Schema Changes
  PR template sections. Made the Codex review loop conditional on
  `command -v codex`. Kept team's existing stack-detection build commands.
- **`commands/commit.md`**: left untouched in this rebuild — the team's
  confirmation step is a deliberate divergence from Pane's autonomous
  behavior, so `commit.md` is unchanged in `pre-rebuild-2026-04-30..HEAD`.

### Master review pipeline

- **Phase 0c** now sets stack detection vars (`HAS_TANSTACK_QUERY`,
  `HAS_APP_ROUTER`, `HAS_AUTHED_HANDLER`, `HAS_UI_PROJECT`) for downstream
  lens agents. Detection vars are re-set inline in Phase 3b because
  markdown bash fences don't share scope.
- **Phase 1** now spawns up to 14 agents in parallel: 3 Claude Opus + 3
  Codex + 2 Antigravity reviewers + 6 lens agents (2 always-on + 4
  stack-gated). Each lens spawn is unconditional; gated lenses self-skip
  in their own prompt body.
- **Phase 2** (synthesis) collects lens-agent return values via
  `$LENS_FINDINGS` and tags each merged finding with the originating agents.
  Cross-source matches (reviewer + lens) automatically promote confidence.
- **Phase 3** (verification loop) spawns the 6 reviewer agents + 2
  always-on lens agents per round.

### Preservation guarantees (verified byte-equivalent vs `pre-rebuild-2026-04-30` snapshot)

- `commands/plan2bid/` (16 files) — construction estimation suite, used in
  another repo
- `commands/ui-ux-pro-max/` — UI/UX design suite (50+ styles, 161 palettes,
  shadcn/ui MCP integration)
- `commands/macmini/` — Chrome Remote Desktop control via chrome-devtools MCP
- `commands/dock.md`, `screen.md`, `admet.md`, `optimize.md`, `prep-target.md`,
  `dashboard.md` — MoleCopilot drug discovery suite
- All `fraim → ...` job entries
- MoleCopilot, FRAIM, and Next.js sections in `CLAUDE.md` (left untouched per
  user direction)

### Snapshot tag for rollback

`pre-rebuild-2026-04-30` — the pre-rebuild HEAD. Use
`git reset --hard pre-rebuild-2026-04-30` to revert if needed.

### Branch strategy

Work landed on `dotfiles-rebuild`. The `~/.claude/` PostToolUse auto-sync hook
was disabled for the rebuild duration via `~/.claude/.rebuild-sentinel`.
Re-enable the hook + clear the sentinel after squash-merging to `main`.

---
