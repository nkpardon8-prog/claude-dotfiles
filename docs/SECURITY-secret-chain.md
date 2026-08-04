# The secret-protection chain — what it defends, and what it does not

This repo auto-commits and auto-pushes to a **public** GitHub remote on every edit (a
`PostToolUse` hook runs `scripts/dotfiles-sync.sh`). The secret gate is therefore
load-bearing. This document states exactly what that gate is and is not, so nobody -
human or agent - builds false confidence on top of it, and so the known gaps are recorded
rather than rediscovered.

Audited and repaired 2026-08-01. Every claim below was established by direct probe.

## The layers

| Layer | Where | Fires on | Blocks? |
|---|---|---|---|
| pre-commit | `.git/hooks/pre-commit` (generated) | `git commit` | Yes — scans **index blobs** (after two staged-scoped command lints: `lint-skill-size.sh`, then `lint-skill-contract.sh`) |
| pre-push | `.git/hooks/pre-push` (generated) | `git push` | Yes — scans the commit range, blobs **and** messages |
| auto-sync | `scripts/dotfiles-sync.sh` | any dotfile edit | Yes — scans the working tree before staging |
| CI | `.github/workflows/secret-scan.yml` | push / PR | **No — detection only** |
| SessionStart | `settings.json.template` `credentials.md` scan | session start | **No — warns only** |
| god-review 2.4 | `commands/god-review/principles/secret-leak.md` | audit run | **No — reports only** |
| **`.gitignore`** | `.gitignore` | `git add` / `git add -A` | Yes — the path never becomes stageable |

Every *scanner* layer above calls `scripts/secret-scan.sh` (exit `0` clean / `2` secret /
`3` could-not-prove-clean; precedence `3 > 2 > 0`; hits to stderr, stdout stays empty).

**`.gitignore` is a control, not merely defence in depth — and for some files it is the
only control that can work.** The ignore layer and the scanner are frequently **mutually
exclusive** rather
than stacked: once a path is ignored, `--working` (which enumerates via `git ls-files
--others --exclude-standard`) never sees it, so the scanner *cannot* be the backstop.
That division is deliberate, and it matters most where no pattern can help:

- `.envrc` holds an arbitrary `export DB_PASSWORD=<opaque>`. No regex can match an
  arbitrary value, so ignoring the path is the *only* possible control.
- `.aws/config`, `.docker/config.json`, `.git-credentials` likewise carry values
  (base64 `auth` blobs, plaintext `https://user:password@host`) that no lane matches.
- Verified 2026-08-03: with `.gitignore` emptied, a `--working` scan of a tree containing
  all nine fixtures caught **only** the two `.npmrc` files. The other seven are invisible
  to the scanner by construction.

Every pattern for these files is intentionally **slash-free or `**/`-prefixed**: a pattern
containing a slash is root-anchored, so `.aws/credentials` would not match
`sub/.aws/credentials`. That defect was live until 2026-08-03.

**A caveat the ignore layer cannot escape:** ignoring a path does not protect one that is
*already tracked*, nor one added with `git add -f`. For those the scanner is the only
remaining gate, and for opaque-value files it will not fire. Do not add such a file to the
index in the first place.

Local hooks live in `.git/hooks/`, which is **not tracked**. They exist only after someone
runs `scripts/install-git-hooks.sh`. A fresh clone has **no local gate at all** until then.

## IN SCOPE — what this actually defends against

A secret reaching the public remote because a human or an agent **did not notice it**:
through the auto-sync path, or through ordinary manual `git commit` / `git push`.

That is the real threat here. The repo is edited constantly by agents, and the auto-sync
hook is `async: true`, so a failure has no natural way to reach anyone.

## OUT OF SCOPE — deliberate circumvention

A local git hook executes under the control of the person pushing. It cannot bind that
person. All of the following defeat the entire local tier and are **not** defended against:

- `git commit --no-verify` / `git push --no-verify`
- `git config core.hooksPath <empty dir>` (including a worktree-scoped one via
  `extensions.worktreeConfig`)
- `BASH_ENV=<file with exit 0>` for non-interactive bash hooks
- a hostile `PATH` shim for `git`, `grep`, or `find`
- editing the unstaged `scripts/secret-scan.sh` to `exit 0`
- cloning elsewhere and pushing without ever installing the hooks
- creating commits via `git rebase` / `cherry-pick` / `am` / `commit-tree`, which do not
  run the pre-commit hook at all - so neither its two command lints nor the secret scan
  chained behind them ever sees the result

Do **not** try to close these with more hook code. The correct control for a hostile
pusher is server-side (branch protection / push rules), which this remote does not
provide. If that threat matters, make the repository private instead — that removes the
exposure class outright.

## OUT OF SCOPE — detection blind spots

The scanner is a **regex over content**. It does not detect:

- base64-, gzip-, or otherwise encoded secrets; binary key exports (PGP, P12)
- literals split across lines, variables, or files
- generic `KEY=value` shapes with no recognized provider prefix, and generic high-entropy
  strings (no entropy rule exists, deliberately — see "Why no JWT/DSN patterns")
- secrets in **filenames**, **directory names**, **branch names**, or **tag names** — tree
  paths and ref names are published, but only blob and message *content* is scanned
- secrets in **author / committer identity** headers
- **annotated tag messages**, and blobs reachable only from a tag pointing directly at a
  blob (`git update-ref refs/tags/x <blob>`) — `rev-list` yields no commits for those
- **Git LFS** objects (only the pointer is local) and **submodule** contents
- Tag-only pushes do not trigger CI at all (`push.branches` only)

### How the pre-push range is chosen

- **Existing branch:** `<remote_sha>..<local_sha>`. Git negotiated `remote_sha` with the
  destination, so this is authoritative and uses no heuristic. It can RE-scan commits that
  reached the remote through another ref (an ordinary merge), which may block a push over an
  already-public secret. That false positive is accepted deliberately: a blocked push is
  visible and diagnosable, a missed secret is permanent.
- **New branch:** `<local_sha> --not --remotes=<name>`. No authoritative answer exists
  locally, so this trusts that remote's tracking refs. A stale or forged tracking ref can
  exclude commits the destination will actually receive.

**Out-of-scope configurations** for the new-branch case: a remote with a `pushurl`, several
`remote.<name>.url` entries, `url.*.pushInsteadOf`, or a push to a raw URL. In all of those
the tracking refs describe a *different* repository than the one receiving the objects.
Earlier revisions tried to detect each case; every partial heuristic produced a new hole and
none can be made complete, so the limitation is stated here instead of half-checked in code.
This repository has a single remote with no URL rewriting.

### The PIN lane and composite text

The CRD PIN pattern is normally path-aware: `crd_path_allowed` exempts docs that discuss the
format in the abstract. Pre-push scans **composite text** (concatenated patch hunks plus
commit messages) where original paths no longer exist, so the allowlist cannot be consulted —
and must not be, or a `TMPDIR` under an allowlisted directory would silently disable the
lane. Consequence: a PIN-shaped value inside an allowlisted document **will block a push**
once it enters a pushed range. Placeholder values (`000000`, `123456`) stay exempt
and are what those documents should use. Measured 2026-08-01: zero PIN-pattern matches across
this repository's entire history.

## CI is detection, not a gate

On a `push` event the workflow runs **after** the objects are already on GitHub. It cannot
prevent exposure; it tells you exposure happened. Treat a CI secret failure as an incident:
**rotate the credential at the provider first**, then clean history. Removing the commit
does not un-publish it.

## Why the JWT and connection-string patterns are narrowly anchored

**Corrected 2026-08-03.** This section previously read "Why there are **no** JWT or
connection-string patterns" and was false: `RX_JWT` and `RX_CONN` are defined at
`scripts/secret-scan.sh` (grep for `RX_JWT=` / `RX_CONN=`; they are folded into `RX` on the
line immediately after). Line numbers are deliberately NOT cited: the first version of this
correction named `:105-107`, and the same commit added comment lines above them, so the
reference was stale before it was even pushed. Verified by execution — a
three-segment `eyJ…` token and a postgres DSN carrying inline credentials each return rc=2.
(Both example shapes are described in prose rather than written literally: this file is
tracked, and the repo's own full-tree scan would match a real one. Writing that example out
turned the tree scan red while this very section was being corrected.) The lanes
were added after this section was written and the section was never updated, so the document
understated the scanner's coverage. The historical measurement below is why they are shaped
the way they are, not evidence that they are absent.

Measured on this repo when the DSN lane was first considered: it produced **0** true
positives across 302 tracked files and **1** confirmed false positive, and needed two
hand-tuned placeholder filter tables. A greedy `eyJ`-prefix or `scheme://user:pass@host`
rule matches ordinary documentation. Hence both lanes require full structure — three
dot-separated base64url segments; an explicit scheme with a non-empty user *and* password —
rather than a bare prefix.

**Still deliberately absent:** a lane for plain HTTP(S) credential URLs
(`https://user:pass@host`), which is why `.git-credentials` is covered by `.gitignore`
instead.

The failure mode is asymmetric and severe: a false positive jams **every** commit in this
repo *and* blocks the async auto-push. It is no longer *silent* - the pause marker records a
machine-readable `kind:`. The UserPromptSubmit notice surfaces it on every prompt;
stale-handoff-guard also surfaces it at session start, but only when the session's cwd is
inside a git repository - it exits early otherwise, so it is a second channel, not a guarantee - but the machine still stops syncing until a human acts. A missed exotic
secret is one exposure; a false positive is a dead toolchain.
Patterns here stay **anchored to provider-specific prefixes**.

## If you change the regex

`scripts/hooks/test-secret-scan.sh` includes a full-tree false-positive gate: the scanner
must exit `0` over every tracked file. That gate is the regression net for regex edits —
if it goes red, the change is unusable regardless of what it catches.

## Verifying the chain

```bash
bash scripts/hooks/test-secret-scan.sh     # exit 0 = scanner + generated hooks behave
bash scripts/install-git-hooks.sh          # required after every clone
cat .git/hooks/pre-push                    # confirm the installed hook on disk
```

**What the suite covers, precisely:** `scripts/secret-scan.sh`, the `pre-commit` / `pre-push`
hooks generated by `install-git-hooks.sh` (exercised against a throwaway repo and a local bare
remote), the installer's contention behavior (a matching stamp is a real no-op; an
unverifiable one must exit 4, never 0), and pause-marker **routing** for all three `kind:`
values. Since 2026-08-03 it also makes **static** assertions about the CI workflows. The count is deliberately NOT stated here:
this paragraph said "four", then "nine", and was wrong within a day both times. Count them in
`scripts/hooks/test-secret-scan.sh` if you need the number. They cover: that the workflow
file exists at all (a missing one is a stated failure, not a silent skip); that the scanner is
invoked with `--`; that enumeration does **not** go through `xargs` (which collapses rc=2 and
rc=3 into one indistinguishable red, since xargs reports its own status — BSD 1, GNU 123) and
**not** through process substitution (whose producer exit status is structurally unobservable,
so a `git ls-files` that dies mid-stream would be scanned as a complete tree); that the
enumerator's status is checked and a truncated, non NUL-terminated stream is rejected; that an
empty enumeration refuses to report clean; and that every non-`actions/` third-party action in
**every** workflow is pinned to a commit SHA rather than a publisher-movable tag.

These are text assertions over the YAML, not an execution of the job: they prove the shape has
not regressed, not that the workflow runs. `dotfiles-sync.sh`'s push path end-to-end, and the
CI jobs' actual execution, are still verified by hand. A green suite is not a statement about
the whole chain — demonstrated on 2026-08-04, when the `harnesses` job in `lint-commands.yml`
was red on 16 consecutive pushes while every local suite reported green.

Every assertion is expected to be **mutation-verified**: delete the code a case names, and
that case must go red. Three assertions were found to be decorative in round 5 and one more in
round 6 — each passed no matter what the code did. If you add a case, break the fix on purpose
and watch it fail before trusting it.

Fixture credentials in the test suite are assembled at **runtime** from fragments — a
literal token in a tracked file would make the repo's own full-tree scan red forever.

## Known residual issues

These survived nine review rounds and are recorded deliberately rather than fixed, because in
each case the fix costs more machinery than the risk justifies - or, in one case, cannot work
at all from inside this repository. **Most** need contrived timing or hand-built git
configuration; the older-branch item below is the exception and is reachable with ordinary
commands, which is exactly why it is stated first-class rather than buried. They are listed so nobody has to
rediscover them, and so a future change does not quietly assume they are handled.

- **The generator fingerprint hashes a pathname, not the executing bytes.**
  `install-git-hooks.sh` computes `shasum "$0"`, but bash has already opened and is reading the
  old bytes. If the file is atomically replaced in the window between bash's read and the hash,
  the stamp can describe a generator that did not produce the hooks on disk. Narrowed by
  re-hashing at the end and withholding the stamp (plus `exit 4`) when it moved, which turns the
  dangerous case into a self-correcting reinstall. Closing it completely is not possible from
  inside the script. Requires a `git pull` or editor save landing inside a sub-second window.

- **An orphaned install lock requires a manual `rm`.** Age-based reclaim was implemented in
  round 5 and **deleted** in round 6 after three independent reviewers showed it could steal a
  live lock from a stalled owner, whose cleanup would then delete the new owner's lock. Correct
  reclaim needs pid ownership, liveness checks and atomic compare-and-delete. Instead an
  orphaned lock now makes the installer `exit 4`, which surfaces as a pause marker. That marker
  carries a GENERIC reason (see the next item); run the installer by hand to see which lock.
  Loud and manual beats silent and racy.

- **The pause marker is one file, so a `secret` record can be lost.** In `dotfiles-sync.sh`
  non-secret writes use `set -C` (O_EXCL) and can never clobber an existing marker; only a
  confirmed secret may overwrite. **The SessionStart writer is weaker**: it is a one-line shell
  fragment in `settings.json`, so it uses `[ -f ] || printf`, a check-then-write with a
  millisecond race. It is the low-frequency writer (once per session start, and only when the
  installer fails), so the exposure is small — but it is not O_EXCL and this doc should not
  claim otherwise. Nothing stops a human or script deleting the marker outright either. It is a
  notification channel, not an audit log.

- **The orphan-lock pause does not carry its specific reason.** `install-git-hooks.sh` prints
  which lock to remove and the exact `rm -rf`, but both automatic callers redirect its stderr
  to `/dev/null`, so the marker records only a generic "could not refresh the git hooks". To
  see the real cause, run `bash ~/.claude-dotfiles/scripts/install-git-hooks.sh` by hand.

- **Checking out an older branch installs that branch's hooks — and the stamp still looks
  valid.** SessionStart runs `install-git-hooks.sh` *from the working tree*. Check out a branch
  that predates this repair (`dotfiles-rebuild` and `macmini-strip` both do) and the old
  generator installs the old, fail-open pre-push and stamps its own fingerprint — which
  matches, so nothing reports staleness. Pushing from that branch runs the old gate.
  **This is not fixable from inside the repository.** Any checker added to detect it would
  itself be checked out at the old revision and therefore also old. Returning to `main` heals
  it on the next SessionStart, because the fingerprint then mismatches and triggers a
  reinstall. The real controls are server-side (branch protection) or making the repo private.
  Raised as CRITICAL in round 8; recorded rather than papered over with a check that cannot
  work.

- **`--all-history` remains a coarse primary-pattern audit.** It does not apply the PIN lane and
  does not honor the rc=3 contract. It is a one-time sweep, not a gate, and is not
  composite-equivalent.

- **No coverage for a mid-run generator swap, `refs/replace`, or here-string under-delivery.**
  The fail-closed code for all three exists and was reasoned through, but no test triggers them
  because each needs a precisely timed external event. Stated plainly rather than implied by a
  green suite.

The honest summary: on `main`, with the hooks installed, the chain reliably stops **accidental**
exposure through ordinary commit and push workflows - that path is live-verified end to end.
It is not a control against a determined person; it does not protect a checkout of an older
revision, whose tooling is that revision's; and the residuals above are the places where
"proven" degrades to "argued".


### Two accepted regex residuals (measured, not theoretical)

Both were live in `scripts/secret-scan.sh` and stated only in a code comment until 2026-08-03,
which is how three separate reviewers each re-derived them from scratch. They belong here.

- **An alphanumeric-glued key is a false NEGATIVE.** The `sk-` lane is left-anchored on
  `(^|[^A-Za-z0-9])`, so `PREFIXsk-<44 chars>` returns **rc=0** (measured). This is the
  unavoidable cost of excluding only `[A-Za-z0-9]`: widening the boundary to also exclude `_`
  and `-` is what made `backup_sk-<key>` invisible in an earlier round, and narrowing it
  reintroduces false positives on ordinary kebab-case prose - which jam every commit. A key
  run together with a preceding word and no separator at all is not a shape secrets are
  normally written in, so the trade is **accepted**. It is accepted, not absent. Do not
  "fix" it without a measured false-positive count.
- **Three lanes are deliberately still unanchored**, in the false-positive (jam) direction:
  `hf_`, `xox[abposr]-`, and `(rk|sk|pk)_(live|test)_`. Measured rc=2 on the ordinary strings
  `branchf_...`, `prefixoxb-...`, `network_live_...`. They are far rarer in prose than the
  `task-`/`risk-`/`disk-` family that forced the original anchoring, and widening a fix
  without a measured false-positive rate is precisely how the previous over-correction
  happened. **Tracked, not closed.**
