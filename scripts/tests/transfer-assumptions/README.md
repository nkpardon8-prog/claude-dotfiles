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
Auto-compact sentinels, mission-liveness files, `*.lock` (including a `tick.<sid>.lock`-shaped
name), `prod.lock`, `node_modules`, `.env`, and two `tmp/` secret files
(`tmp/od-test/creds.local.env`, `tmp/telnyx/x-dev.env`) are all absent from the bundle and absent
on B after a real restore; the `.env`-shaped names are surfaced in the dry-run's "left behind"
list. Then, under the dev-only `TX_TEST_DISABLE_EXCLUDES=1` knob, the SAME planted non-secret
files (auto-compact/mission-liveness/lock/node_modules) DO travel - watched failing once, so the
guard is proven real rather than vacuous. (The secret-named files are not re-tested with excludes
disabled: the independent `secret-scan.sh` step would refuse that send outright, which is
defense-in-depth, not this test's subject.) Part 3: a context reference with a `..` component
(`tmp/../../outside-3.txt`, which climbs out of the repo) is never followed and is recorded in the
manifest as `unsafe-reference`, while the ordinary `tmp/` file beside it still ships. Part 4: memory
notes NAMED like secrets (`reference_od_test_creds.md`) are Claude state and travel - the name
filter covers repo files only - but their CONTENT is still scanned: a secret-shaped line in one
refuses the send, naming the file and never echoing the secret.

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

### 99-resume-keeps-sid.sh (assumption A1, gated, NOT in run-all.sh)
`claude --resume <sid>`, run against a copy of a real transcript placed under a fresh project dir,
keeps the SAME session id and continues the transcript - for a cleanly-ended shape, one cut off at
an unanswered tool call, and one cut at a half-written last line (the actual shapes `/transfer`
captures mid-turn). Costs a real model call, so it only runs with `TRANSFER_LIVE_CLAUDE=1`, set by
a human. If this ever fails: stop and re-plan - the whole design rests on it.

## Dev-only test hooks (honored ONLY under `TRANSFER_TESTS_ALLOW_DEV=true`)

- `TX_TEST_DISABLE_EXCLUDES=1` - `transfer-send.sh` skips its never-copy/heavy-dir/secret-name
  filters, for test 04's negative control.
- `TX_SEAL_PID=<pid>` - `--seal-after-exit` waits on this pid instead of the sender's own
  registered claude process, for test 12.
- `TX_TEST_SEAL_TIMEOUT`, `TX_TEST_TOTAL_CAP_BYTES` - override the sealer timeout / the
  untracked+context size cap for faster or more targeted tests.
- `TX_TEST_ALIAS_HOMES_BASE=<dir>` - `tx_alias_homes` (transfer-lib.sh) looks for verified home
  aliases in `<dir>/*` instead of `/Users`, for tests 07 and 15 (tests cannot write `/Users`).

None of these are reachable without the dev gate, so a stray environment variable can never make a
real transfer carry secrets, skip machine-bound-state exclusion, seal against the wrong process, or
treat an arbitrary directory as a verified home alias.

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

## Why CI does not run this suite

Same reasons as the sibling `line-agent-assumptions` suite: it is `$HOME`-dependent by design (it
locates the scripts under `$HOME/.claude-dotfiles`), it depends on BSD tool semantics (`stat -f`,
`ls -lO` dataless-flag detection, BSD `git`/`tar`), and some paths assume macOS behavior
(code-signature enforcement on renamed binaries, iCloud placeholder files) that a Linux runner does
not have. Run it locally, by hand, before and after touching `scripts/transfer/`.
