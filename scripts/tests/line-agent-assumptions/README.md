# line-agent assumption tests

Pre-implementation gate and post-ship regression net for
`~/.claude-dotfiles/scripts/line-agent-communicator.py` - the script that gives every Claude Code
window one name (statusline caption + peer address) and publishes a directory of live, messageable
windows.

These tests never reimplement the script's rules in bash. Each one builds a situation and then asks
the REAL script, as a subprocess, what it thinks. A bash reimplementation would stay green after the
real defense was deleted, which is the failure mode this suite exists to prevent.

## Run it

```sh
LINE_AGENT_TESTS_ALLOW_DEV=true bash ~/.claude-dotfiles/scripts/tests/line-agent-assumptions/run-all.sh
```

One test at a time:

```sh
LINE_AGENT_TESTS_ALLOW_DEV=true bash ~/.claude-dotfiles/scripts/tests/line-agent-assumptions/04-stale-socket-reachability.sh
```

## Exit-code vocabulary

| code | meaning |
| --- | --- |
| 0 | PASS - every assertion held |
| 1 | FAIL - an assertion about behavior was violated |
| 2 | REFUSED - the `LINE_AGENT_TESTS_ALLOW_DEV=true` gate was not set |
| 3 | INFRA / SKIP - the situation could not be built (no python3, no live window, socket path too long). Not a verdict about the code. |

`run-all.sh` maps a hang (GNU `timeout` 124, perl SIGALRM 142) to 3 so a wedged test reads as
infrastructure, never as a pass.

## What each test proves

### 02-starttime-comparison.sh - is start-time a sound identity key?

Reads the user's REAL registry at `~/.claude/sessions/*.json`, **read only**, for every pid that is a
live claude process, and compares the stored `procStart` / `startedAt` against live `ps` output.

- **A1** stored `procStart` equals live `ps -o lstart=` (whitespace squeezed), and that verdict is
  identical under `TZ=UTC`, `TZ=America/Los_Angeles`, `LC_TIME=C` and `LC_TIME=en_US.UTF-8`. A field
  whose verdict moves with the caller's environment is not an identity key.
- **A2** `startedAt / 1000` is within 2s of the epoch encoded in `procStart` (lstart has no
  sub-second field). This is what would make epoch-ms a locale-free PRIMARY key with `procStart` only
  corroborating.
- **A3** discrimination: a `procStart` perturbed by one minute must compare NOT equal, so a
  comparator that always returns true cannot sail through A1.

Exits 3 if there is not at least one live claude window to compare against.

### 03-fake-home-fixture.sh - can a hermetic fixture satisfy the real liveness check?

The load-bearing test for the whole suite: it proves that a synthetic window under a throwaway `$HOME`
is judged ALIVE by the real script. If it were not, every other fixture-based assertion would
silently exercise only the failure branch and be vacuously green.

### 04-stale-socket-reachability.sh - is "CAN RECEIVE: YES" reachability, or file existence?

- **A1** with a real unix-socket listener bound, the script reports the window reachable.
- **A2** kill the listener but leave the socket inode on disk; the script must report NOT reachable.

### 05-comm-overmatch.sh - does the liveness check over-match on a path substring?

- **A1** `/bin/sleep` symlinked to `zzsleep`, run from a `$HOME` placed under a directory literally
  named `claude-decoy`, must NOT be reported as a live window.

### 06-forged-registry-whois.sh - does `whois` vouch for an entry that was simply made up?

The security regression for the highest-severity finding in this change set. `~/.claude/sessions/
<pid>.json` is a plain file any local process running as the user can write, and the liveness check
only requires `ps -o comm=` to have basename `claude` - satisfied by launching any binary under that
name. A reviewer minted an entry naming a renamed `/bin/sleep` as `summit-prod-owner` / caption
"authoritative", and the command answered `IDENTITY (attested)` under `--transport socket`.

- **A1/A2/A3** the same forgery, looked up at all three transports (none / `bridge` / `socket`),
  must print `UNAUTHENTICATED LOOKUP` + `registry CLAIMS:` and must NOT print `IDENTITY (attested)`
  or `POSSIBLE IDENTITY`. `socket` is the load-bearing one: a kernel peer credential pins the
  *process* and does not *name* it, so it must not upgrade a forgeable name.
- **A4** positive control - the pid and the claimed name are still printed, so "stopped vouching" is
  distinguishable from "command broken".

### 07-banner-injection.sh - can a reply body close the frame that contains it?

- **A1** a reply whose body carries the literal `----- END UNTRUSTED DATA -----` is printed with that
  banner neutralised.
- **A2** exactly 2 END banners appear for 2 items - a third means the peer drew one and closed a frame.
- **A3** exactly 2 BEGIN banners: per-item framing holds, so the *second* file is still framed after
  the first one attacked.
- **A4** positive control - both files' contents are still delivered. A defense that drops the message
  is not a defense.

### 08-dropbox-symlink.sh - is a symlink planted in the dropbox read?

`~/claude-agent-replies/` is writable by any local process by design, and `Path.is_file()` /
`read_bytes()` both follow links - so a link named `<victim-sid>--from-x.md` pointed at a secret
prints that secret into the reading agent's context, with no error.

- **A1** the link target's contents never appear in `replies` output.
- **A2** the link is *named* in the output, not silently skipped - a silent skip hides an attack.
- **A3** `_capped()`'s `O_NOFOLLOW` is exercised directly, so the defense does not rest on the
  listing filter alone and a refactor of one cannot silently remove both.
- **A4** positive control - a legitimate reply in the same dropbox is still read.

## Why 04 and 05 are expected red before the implementation

They encode the two defects the fix is for. Both are **silent wrong answers** - the directory looks
healthy while handing an agent an address that cannot receive.

- **04** - `reachable()` ends at `Path(sock).exists()`. A unix socket file outlives the process that
  bound it; nothing unlinks it on SIGKILL or power loss. An orphaned inode advertises a dead window as
  messageable. Observed today: `reachable=true` with the listener dead. The test prints
  `KNOWN DEFECT (pre-fix): reachable() is file-existence, not reachability - orphaned socket
  advertises a dead window as messageable` and still exits 1.
- **05** - `pid_alive()` is `"claude" in ps_output.lower()` against `ps -o comm=`, which on macOS is
  the **full exec path**, not the basename. Any process running from anywhere under a
  claude-containing path passes as a live Claude window. Observed today: the decoy is listed. The test
  prints `KNOWN DEFECT (pre-fix): substring match on full ps path - any process under a
  claude-containing path is judged a live window` and still exits 1.

They exit 1 rather than 3 on purpose: a skip is not a gate. `run-all.sh` carries them in an
`EXPECTED_RED` list so they are reported separately and do not mask a real regression in 02 or 03.
**When the fix lands, empty that list** - from then on 04 and 05 gate like everything else, and they
become the regression catchers that stop either defect from re-growing.

## Negative-control routes

Every test names how it was proven able to go RED, and gives an env-var route to watch it happen.

```sh
LINE_AGENT_TESTS_ALLOW_DEV=true LINE_AGENT_NEG_CONTROL=true bash <test>.sh
```

| test | control | what it proves |
| --- | --- | --- |
| 02 | A3 is built in; `LINE_AGENT_NEG_CONTROL=true` inverts it and demands the perturbed value compare EQUAL | the comparator is actually comparing, not returning a constant |
| 03 | names the fixture binary `zzsleep` instead of `claude` | the liveness assertion is observing the binary name |
| 04 | A1 and A2 are each other's control (only the listener differs); the env route binds nothing and unlinks the socket, so A1 must go RED | A1 is observing the socket, not returning a constant |
| 05 | places the identical binary and registry entry under `decoy-only` instead of `claude-decoy` and requires the script to agree it is not a window | the listed-vs-not-listed probe can tell the two apart, so A1's failure is the script's behavior |
| 06 | copies the script and restores the vouching header (`IDENTITY (attested)`) verbatim as it shipped | observed RED, 6 of 6 no-vouch assertions failing across all three transports |
| 07 | copies the script and makes `defang()` the identity function | observed RED: A1 (banner not neutralised) and A2 (3 END banners - the peer drew one) |
| 08 | copies the script, drops `O_NOFOLLOW` and lets the listing classify a symlink as a file | observed RED: A1 (target printed) and A3 (`_capped()` followed the link) |

06-08 patch a **copy** of the real script rather than a flag inside it: a defense you can switch off
at runtime is a defense an attacker can switch off. Each patch is anchored on an exact source line
and the test exits 3 (infrastructure) if that anchor has moved, so a silently-not-applied control can
never report a false `NEG-CONTROL OK`. The control run also prints WHICH assertions went red - a
control that only says "something failed" does not prove the right thing failed.

A control run prints `NEG-CONTROL OK` and exits 0 when the test correctly went red, or
`NEG-CONTROL BROKEN` and exits 1 when it stayed green - i.e. when it proves nothing.

## Hermetic-fixture conventions

- Fixture `$HOME` is a `mktemp -d` under `$TMPDIR` named `lac-atest-<uuid12>-XXXXXX`. Each test reaps
  orphans older than 60 minutes at startup, because a `trap`/`finally` does not survive SIGKILL.
- The fixture process is `ln -s /bin/sleep "$FAKE_HOME/claude"`, then run. A **copy** of a system
  binary is SIGKILLed on exec by macOS code signing ("Killed: 9"); the symlink keeps the signed inode
  while presenting our name on the exec path.
- Registry entry: `$FAKE_HOME/.claude/sessions/<pid>.json` (compact JSON, written by a python3
  heredoc) plus the caption at `$FAKE_HOME/.claude/session-status/<sid>.txt`. `version` must be
  >= 2.1.224 or `reachable()` short-circuits on the version gate before it ever looks at the socket.
- Only 02 touches the user's real `~/.claude`, and only to READ.
- Every test writes `<NN>-<name>.fingerprint.json` on PASS, holding only the facts the assumption
  turns on.

## Bash 3.2 note

macOS ships GNU bash 3.2.57, where `${#arr[@]}` on an **empty** array under `set -u` aborts with
"unbound variable" - and the empty case is exactly the all-assertions-passed path. Every test
therefore accumulates failures with a `FAIL_N` counter plus a `FAIL_MSGS` string, never an array, and
`run-all.sh`'s bounded-run prefix is never an empty array (it falls back to a `perl -e 'alarm ...'`
prefix, in the spirit of the `TO=(env)` no-op idiom the sibling runners use).

## CI does NOT run this suite

The `harnesses` job in `.github/workflows/lint-commands.yml` (lines 146-148) is a deliberate
**two-entry allowlist** - `scripts/hooks/test-chain-primitives.sh` and
`scripts/hooks/test-lint-skill-size.sh`. Enrolling a harness there requires first proving it green
with the checkout **outside `$HOME`** and with Linux-safe tooling; harnesses that hard-code
`"$HOME/.claude-dotfiles/..."` or use BSD-only `stat -f` / `date -v` exited 127 on a runner, which is
the "listed, not run" failure that job exists to prevent.

This suite cannot satisfy either requirement:

- it is **`$HOME`-dependent by design** - it locates the script under `$HOME/.claude-dotfiles`, and 02
  reads the user's real `~/.claude/sessions` registry;
- it depends on **BSD `ps` semantics** - `ps -o comm=` returning a full path (05) and `ps -o lstart=`
  formatting (02, 03, 04) are exactly what it asserts about, and Linux `ps` answers differently;
- it needs **live Claude Code windows on the machine** (02 exits 3 without them), which a runner has
  none of.

Run it locally, by hand, before and after touching `line-agent-communicator.py`.
