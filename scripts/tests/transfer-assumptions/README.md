# transfer-assumptions tests

Pre-implementation gate and post-ship regression net for `/transfer` + `resumework`
(`~/.claude-dotfiles/scripts/transfer/*`) - the pair of commands that move a live Claude Code or
Codex chat, its handoff, and its git worktree between two Macs through one encrypted file in
iCloud Drive.

Every test drives the REAL scripts (`transfer-send.sh`, `resumework`) as subprocesses against a
throwaway sandbox `$HOME` and `TX_DROP_DIR`. None of them reimplement the scripts' rules in bash -
a bash reimplementation would stay green after the real defense was deleted, which is the failure
mode this suite exists to prevent.

## Run it

```sh
TRANSFER_TESTS_ALLOW_DEV=true bash ~/.claude-dotfiles/scripts/tests/transfer-assumptions/run-all.sh
```

One test at a time:

```sh
TRANSFER_TESTS_ALLOW_DEV=true bash ~/.claude-dotfiles/scripts/tests/transfer-assumptions/03-git-state-roundtrip.sh
```

Against another checkout (a linked worktree, a scratch copy) - every test reads the scripts from
`$TX_REPO`, default `~/.claude-dotfiles`:

```sh
TRANSFER_TESTS_ALLOW_DEV=true TX_REPO=~/.claude-dotfiles-wt-x bash ~/.claude-dotfiles-wt-x/scripts/tests/transfer-assumptions/run-all.sh
```

The one test NOT in `run-all.sh` (it costs a real model call, and is never run by an agent on its
own initiative):

```sh
TRANSFER_LIVE_CLAUDE=1 bash ~/.claude-dotfiles/scripts/tests/transfer-assumptions/99-resume-keeps-sid.sh
```

## Exit-code vocabulary

| code | meaning |
| --- | --- |
| 0 | PASS - every assertion held |
| 1 | FAIL - an assertion about behavior was violated |
| 2 | REFUSED - `TRANSFER_TESTS_ALLOW_DEV=true` was not set |
| 3 | INFRA / SKIP - the situation could not be built (missing tool, a fixture that would not start). Not a verdict about the code. |

`run-all.sh` maps a hang (GNU `timeout` 124, perl SIGALRM 142) to 3, so a wedged test reads as
infrastructure, never as a pass, and never as the kind of failure that can trip
`dotfiles-sync.sh`'s "commit failed, pause everything" branch.

## The one $HOME plays both Macs

CWD/ROOT/WT are absolute paths that the real design requires to be **identical** on both Macs
anyway (repo files are placed at the same absolute path; only Claude/Codex state is re-homed under
the receiver's own `$HOME`). The exceptions are `07` and `15`, which are exactly about two
DIFFERENT usernames joined by a home alias. So most tests reuse ONE sandbox `$HOME` sequentially as both "Mac A"
(running `transfer-send.sh`) and "Mac B" (running `resumework`) - the same same-machine proxy the
plan itself uses for assumption A1 (`10-resume-keeps-sid` in the plan, `99-resume-keeps-sid.sh`
here). Originals are always deleted, moved aside, or otherwise put into a genuinely different
state BEFORE the receive step, so a passing assertion proves the round trip actually happened
rather than "the file was already there."

## What each test proves

### 01-claude-roundtrip.sh
A fake Claude session (transcript, `/line` caption, memory file) round-trips byte-identical with
mtimes preserved, and `resumework` leaves a `transfer-arrived-<sid>` marker (mode 600) behind for
the primer. Also proves the exec line: `--dangerously-skip-permissions` is added by default and
deduped against a launch that already recorded it, `--safe` omits it, and `-n <handle>` carries
the peer HANDLE `/line` derives from the restored caption (a caption sentence like
`Argv > Caption  Check!` arrives as `argv-caption-check`; the sentence itself never reaches argv),
because the Remote Control display name IS the handle - all via a `TX_CLAUDE_BIN` stub that records
its argv instead of a real launch. It also proves `resumework` removes its decrypted staging copy
from `$TMPDIR` before it `exec`s the chat (an EXIT trap does not fire across `exec`).

### 02-codex-roundtrip.sh
A Codex rollout plus its `history_base` PARENT round-trip to the same dated path under a sandboxed
`CODEX_HOME`.

### 03-git-state-roundtrip.sh
Five git shapes, each its own repo: (A) an unpushed commit plus staged, unstaged and untracked
changes restores with matching HEAD, diff hash and untracked content - this is also the `cwd ==
ROOT` case, since every test here uses a plain repo with no separate worktree. (B) a B clone that
has not fetched A's last push cannot satisfy the bundle's prerequisite commit until it fetches -
proven with a direct `git bundle verify` negative control against the still-stale clone before a
real `resumework` run (which fetches) succeeds. (C) nothing unpushed - no bundle is written
(checked in the manifest), and HEAD/diff/untracked still restore correctly. (D) a detached HEAD
survives the round trip. (F) `transfer-send.sh` refuses while a merge is in progress (`MERGE_HEAD`
present) and writes nothing.

### 04-exclusions-negative-control.sh
What travels and what never does, under the owner's 2026-09-26 "move everything" policy: secrets
travel inside the encrypted bundle; machine-bound state and rebuildable heavy dirs never do. Part 1
(defaults): machine-bound state - an auto-compact sentinel, a mission-liveness file, a
`tick.<sid>.lock`-shaped lock, `prod.lock`, a pid file, a keychain file and a live unix socket - and
heavy dirs (`node_modules` at the top and nested, `dist`, `.next`, `coverage`) are all absent from
the bundle and absent on B after a real restore. Everything else untracked or ignored DOES travel
and lands byte-identical on B: `.env`, `tmp/od-test/creds.local.env`, `tmp/telnyx/x-dev.env`, a
30-day-old ignored `tmp/` file (mtime kept), an ignored file outside `tmp/`, an untracked
`yarn.lock` (package-manager lockfiles are content, not runtime locks). The secret-named files are
listed in the dry-run and in the manifest's `secret_named_files_moved`, `excluded_secret_names` is
empty, and B's TRANSFER notes list them as FYI. Another chat's sid-keyed handoff/TRANSFER files
(`other-chat-state`) and a nested repo stay behind. Part 2: under the dev-only
`TX_TEST_DISABLE_EXCLUDES=1` knob the SAME machine-bound + heavy set DOES travel - watched failing,
so the guard is proven real rather than vacuous. Part 3: symlinks inside the repo that point
outside it (a file and a directory) are never followed and are recorded as skipped (`symlink`),
while the ordinary `tmp/` file beside them ships. Part 4: memory notes NAMED like secrets
(`reference_od_test_creds.md`) travel; secret-shaped CONTENT in a memory note and in a repo file no
longer refuses - the send succeeds, the manifest records each hit as file + rule
(`secret_scan_hits`, status `hits`) and never the matched text, both files travel as-is, and
`resumework` lists the hits in `TRANSFER.<sid>.md` as FYI. Part 5: the sanity caps - a file over the
per-file cap (`TX_TEST_FILE_CAP_BYTES`) is left out and listed by the dry-run, `--force` takes it; a
total over the cap (`TX_TEST_TOTAL_CAP_BYTES`) refuses, `--force` sends.

### 05-public-repo-guard.sh
Nothing transfer-related may ever land under the public dotfiles repo: `transfer-send.sh` refuses
a cwd inside `$HOME/.claude-dotfiles`; `tx_guard_path` refuses a path inside the REAL dotfiles
checkout directly (independent of whatever `$HOME` a caller uses); `tx_drop_dir` refuses a
`TX_DROP_DIR` under a fake `$HOME/.claude-dotfiles` and under the real checkout.

### 06-wrong-code-and-tamper.sh
`tx_decrypt` with the wrong code returns rc 3 and leaves no output file (unit-level). `resumework`
with a mistyped (different-locator) code reports not-found and leaves the real bundle byte-for-byte
untouched. A single flipped ciphertext byte is caught by the sha256 sidecar before decryption is
even attempted. A correctly re-encrypted bundle whose ONE inner payload file was altered is caught
by the manifest's per-file sha256 - all four refuse and place nothing on B.

### 07-identity-and-path-refusal.sh
The real two-username setup, MacBook to Mac mini, under the placement rule (Claude/Codex state is
re-homed under the receiver's real `$HOME`; repo files keep their absolute path, which must resolve
under the receiver's `$HOME` or a VERIFIED home alias). (A1) A's home does not exist on B: refused
with the exact fix (`sudo ~/.claude-dotfiles/scripts/transfer/make-home-alias.sh <user>`), bundle
kept, nothing created. (A1b) the path exists and holds B's clone, but its `.home-alias-of` names
another account: still refused, clone untouched. (A2) verified alias: accepted - transcript and
caption land under B's real `$HOME` (nothing under the alias path's `.claude`), and the ROOT
handoff, TRANSFER notes, an untracked file and `tmp/` context land at the same absolute path, with
HEAD, the `git diff HEAD` hash and the untracked set matching A. Alias homes are simulated with
`TX_TEST_ALIAS_HOMES_BASE` (below) standing in for `/Users`; `make-home-alias.sh` itself needs
`sudo` and a real account, so it is validated by `bash -n` and review, not by this sandboxed suite.

### 08-memory-merge.sh
When B already has its OWN, DIFFERENT memory file at the same path, B's file is never overwritten;
the incoming version lands beside it as `<name>.from-<host>` and is listed in both the printed
checklist and the `TRANSFER.<sid>.md` notes.

### 09-handoff-refusal.sh
`transfer-send.sh` refuses a claude chat with no handoff, a 40-minute-old handoff (limit 30), or a
fresh handoff whose END-OF-HANDOFF marker names a different sid - each with a specific reason. A
positive control (fresh, correctly-marked handoff) still sends, so A1-A3 are not vacuously true of
a script that always refuses. (A5) under `--dry-run` the missing-handoff refusal becomes an
informational "A real run would refuse: ..." line, and the file list and sizes still print (exit 0,
nothing written) - `/transfer --dry-run` skips the handoff step, so this is its normal shape.

### 10-expiry-sweep.sh
`tx_expire_sweep` deletes an 8-day-old bundle, sidecar, and `.tx.failed` marker, keeps a 1-day-old
bundle, and logs what it removed.

### 11-reverse-transfer.sh
The departure-state stash. In the real flow, A's own `transferred-<sid>` marker (written by A's
original send) sits untouched on A's disk while the chat lives on B, and is only cleared when
`resumework` runs on A again - so when B eventually sends the chat back, A's worktree may still be
dirty exactly as A left it. (A1) when the destination's actual dirty state exactly matches its own
recorded departure, `resumework` stashes it as `transfer-backup-<ts>`, applies the incoming content
on top, and clears the marker - and the stash is proven to actually hold the departed content, not
just exist. (A2, negative control) when the recorded departure does NOT match the destination's
actual dirty state (drift), `resumework` refuses and leaves the destination completely untouched -
no stash, no overwrite.

### 12-sealer-fake-pid.sh
`--seal-after-exit` validates and prints the code immediately; `TX_SEAL_PID` (dev-only) substitutes
a short-lived real process for "the claude process this chat is running in". No bundle exists while
that process is alive; once it exits, the detached sealer packages within a bounded wait, and the
restored `TRANSFER.<sid>.md` records that A closed before sealing (the `sealed_after_exit_at`
proof).

### 13-separate-worktree.sh
The normal dentall layout: the chat works in a separate worktree (WT != ROOT) while its handoff and
TRANSFER notes live at ROOT. (G) B has only a plain clone; `resumework` re-creates the worktree at
the same path on the same branch with HEAD, diff hash, untracked set and `tmp/` context matching,
and the handoff/TRANSFER notes land at ROOT (not in the worktree). (H) the chat's branch is already
checked out in ANOTHER worktree on B: refused with that worktree's path, and nothing changes (no
worktree created, branch unmoved, no `refs/transfer/<sid>` left, bundle kept).

### 14-git-backout.sh
A git restore that fails part-way backs out. (I1) a `post-checkout` hook in B's clone (the failure
injector) dirties the freshly created worktree, so the final diff proof fails after `worktree add`
and `branch`: exit 1, the error names what was undone, the created worktree and branch are gone,
the ref is cleaned up, the bundle is kept, and a re-run without the injector succeeds. (I2) an
existing checkout with this Mac's own departure edits (stashed) is fast-forwarded, then the patch
cannot apply (B has its own untracked file where the patch creates one): HEAD and the branch are
back where they were, the departure edits are popped back, B's file is untouched.

### 15-alias-reverse.sh
The reverse of `07`: sending FROM the Mac mini, whose chat works under the alias path, back to the
MacBook where that path is the real home, with a separate worktree. The sender refuses the same cwd
when no verified alias covers it (no alias base; a marker naming another account), then accepts it
through a verified alias and records `home` (real) and `repo_home` (alias) in the manifest. The
MacBook restores Claude state under its real `$HOME`, the worktree (HEAD, diff, untracked, `tmp/`)
and the handoff/TRANSFER notes at the same absolute paths.

### 16-install-app-marker.sh
`install-transfer.sh` builds `~/Desktop/Resume Chat.app` with an ownership marker
(`Contents/Resources/.built-by-install-transfer`), rebuilds only an app carrying that marker, and
leaves a foreign app of the same name byte-for-byte untouched (with a warning) - run against a
sandbox `$HOME`.

### 17-codex-seal-after-exit.sh
`--seal-after-exit` for `--tool codex` (the Codex transfer skill's send), against a sandboxed
`CODEX_HOME`. (A) `--source-pid` points at a throwaway `sleep`: the code prints at once, no bundle
while it lives, and a turn appended to the rollout AFTER the send started is in the restored rollout
with the TRANSFER notes. (B) a python process holding `thread-writer-locks/<id>.lock` open stands in
for Codex's chat lock: an immediate send refuses; the sealer does not pack when the pid dies but the
lock is held, and does once it is released (the leftover unheld lock file does not block). (C) no
codex process above the shell (the send runs detached) and no `--source-pid` -> refused;
`--source-pid` without `--seal-after-exit` -> refused. (D) the send runs under a fake
`codex ... app-server` (a symlink named codex): refused when the lock is not held; with it held, no
process is watched and the bundle waits for the lock. The post-close grace is 2 s here
(`TX_TEST_CLOSE_GRACE`), so a sealer that stopped watching the lock fails B and D.

### 18-newer-local-kept.sh
A ride-along file (ignored repo context) is never rolled back. (N) B's copy is newer than the
incoming one: it stays in place, the incoming version lands beside it as `<name>.from-<host>`, and
the dry-run's "would replace" list omits it. (O) negative control: B's copy is older - replaced, old
copy kept as `.bak-<ts>`. Found live 2026-09-26 when a reverse transfer would have reverted another
agent's newer plan; goes red with the mtime check disabled.

### 19-codex-skill-and-no-mission.sh
On a throwaway copy of the repo, `generate-codex-layer.py` emits `command-transfer/SKILL.md`
byte-identical to `codex/overrides/command-transfer/SKILL.md` (other commands still ported; an
override with no matching command fails the generator), and `install-codex.sh` delivers it to a
sandboxed `$CODEX_HOME/skills/claude-dotfiles/`. Then `/pre-compact`'s `no-mission` token: documented,
stripped from the north star (both forms), read by the `NO_MISSION` switch (not fooled by
`no-missionary`), gating `mission-write.sh create`, and passed by `/transfer`.

### 20-delta-second-send.sh
Delta sends, sender side. (A) the first send from a repo is full ("no record yet"), and resumework
then writes `~/.claude/transfer-state/<hash>.json` (dir 700, file 600, role=receive) with each
ride-along file's sha256. (B) the second send leaves unchanged ignored, untracked and `.env` files
out of the bundle and lists them under `assumed_present` (sha256 + size), ships a changed and a new
file, reports "N ride-along file(s) ... were not re-sent" in the send summary, and rewrites the state
(role=send, this locator); the receiver counts all of them verified identical. (C) a send after an
uncollected one (its bundle still in the drop folder) is full and says why.

### 21-assumed-present-report.sh
Delta sends, receiver side. Between the send and resumework, "B" deletes one assumed file, edits
another and replaces a third with a symlink. resumework still exits 0, touches none of them (no
recreate, no .bak/.from, the symlink target untouched), counts the one identical file, and names the
missing/differing ones in the dry run, the checklist and TRANSFER.<sid>.md under "Not re-sent (the
other Mac assumed you already had it) - differs/missing here". The receiver state records the
SENDER's sha256 for every assumed file.

### 22-delta-full-and-corrupt-state.sh
Fail-safe toward sending more. (A) `--full` ignores a valid state: every ride-along file ships and
the state is still rewritten. (B) a non-JSON state, a state for another repo root, one with a
malformed entry, and an unreadable (mode 000) one each give a full send with a reason. (C) the expiry
sweep removing an uncollected bundle also removes the state that send wrote. (D) resumework refuses
format-3 and format-5 bundles with the "update the dotfiles on both Macs" message, changing nothing.

### 23-delta-never-skips-chat-files.sh
A forged state claiming exact copies of the handoff (+ .prev), MISSION, TRANSFER notes, transcript,
the project memory file (no sid in its path - only the kind rule protects it) and a sid-named ignored
file: all still ship, as does the git worktree patch; only the ordinary ignored file is assumed
present. Goes red with the kind rule or the sid rule removed.

### 24-icloud-nudge.sh
A stub `brctl` on PATH (records pid + argv, then sleeps like the real monitor). With the drop folder
under `$HOME/Library/Mobile Documents/`: started as `brctl monitor com.apple.CloudDocs` while
resumework waits, and dead after a give-up, a TERM mid-wait, a `kill -9` mid-wait (the watchdog) and
a normal restore. With a drop folder outside iCloud it is never started.

### 25-unmerged-refused-early.sh
Files left half-merged by a conflicting `git stash pop` (unmerged index entries, no MERGE_HEAD) are
refused at SEND time, naming the file, with no bundle published - a patch cannot carry git's
conflict stages, and live on 2026-09-27 the receiving Mac backed out only after a full upload.
Negative control: resolved (git add), the same chat sends. Red with the check disabled.

### 99-resume-keeps-sid.sh (assumption A1, gated, NOT in run-all.sh)
`claude --resume <sid>`, run against a copy of a real transcript placed under a fresh project dir,
keeps the SAME session id and continues the transcript - for a cleanly-ended shape, one cut off at
an unanswered tool call, and one cut at a half-written last line (the actual shapes `/transfer`
captures mid-turn). Costs a real model call, so it only runs with `TRANSFER_LIVE_CLAUDE=1`, set by
a human. If this ever fails: stop and re-plan - the whole design rests on it.

## Dev-only test hooks (honored ONLY under `TRANSFER_TESTS_ALLOW_DEV=true`)

- `TX_TEST_DISABLE_EXCLUDES=1` - `transfer-send.sh` skips its machine-bound-state and heavy-dir
  filters (and walks heavy dirs), for test 04's negative control.
- `TX_SEAL_PID=<pid>` - `--seal-after-exit` waits on this pid instead of the sender's own
  registered claude process, for test 12.
- `TX_TEST_SEAL_TIMEOUT`, `TX_TEST_TOTAL_CAP_BYTES`, `TX_TEST_FILE_CAP_BYTES` - override the sealer
  timeout / the total untracked+ignored size cap (5 GB) / the per-file cap (1 GB), for faster or
  more targeted tests.
- `TX_TEST_ALIAS_HOMES_BASE=<dir>` - `tx_alias_homes` (transfer-lib.sh) looks for verified home
  aliases in `<dir>/*` instead of `/Users`, for tests 07 and 15 (tests cannot write `/Users`).

None of these are reachable without the dev gate, so a stray environment variable can never make a
real transfer carry machine-bound state or heavy dirs, change its caps, seal against the wrong
process, or treat an arbitrary directory as a verified home alias.

## Hermetic-fixture conventions

- Sandbox `$HOME` is a `mktemp -d` under `$TMPDIR` named `tx-atest-<suffix>-<uuid12>-XXXXXX`. Each
  test reaps orphans older than 60 minutes at startup (a `trap`/`finally` does not survive
  SIGKILL).
- Git fixtures use a local bare "origin" (`git init --bare`) plus a clone - no network, no GitHub.
- `git identity` is pinned to `tx-test <tx-test@example.invalid>` for the whole suite (see
  `_common.sh`), so a commit never depends on the machine's own git config.
- `_common.sh` is a shared helper library, not a test itself - `run-all.sh` only picks up
  `NN-*.sh`, so it is never invoked directly.
- Every test cleans up its own sandbox via a `trap ... EXIT`.
- Every `GIT_*` variable is cleared first (`run-all.sh` and `_common.sh`). The dotfiles pre-commit
  hook runs this suite, and git exports `GIT_INDEX_FILE` (plus `GIT_PREFIX`, `GIT_AUTHOR_DATE`, ...)
  into hooks; inherited, it pointed every sandbox `git` call at the committing repo's index, so tests
  13-15 could not build their fixtures and the hook always reported "could not run (exit 3)".

## Why CI does not run this suite

Same reasons as the sibling `line-agent-assumptions` suite: it is `$HOME`-dependent by design (it
locates the scripts under `$HOME/.claude-dotfiles`), it depends on BSD tool semantics (`stat -f`,
`ls -lO` dataless-flag detection, BSD `git`/`tar`), and some paths assume macOS behavior
(code-signature enforcement on renamed binaries, iCloud placeholder files) that a Linux runner does
not have. Run it locally, by hand, before and after touching `scripts/transfer/`.
