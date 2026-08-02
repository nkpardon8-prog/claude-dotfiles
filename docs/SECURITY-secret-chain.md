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
| pre-commit | `.git/hooks/pre-commit` (generated) | `git commit` | Yes — scans **index blobs** |
| pre-push | `.git/hooks/pre-push` (generated) | `git push` | Yes — scans the commit range, blobs **and** messages |
| auto-sync | `scripts/dotfiles-sync.sh` | any dotfile edit | Yes — scans the working tree before staging |
| CI | `.github/workflows/secret-scan.yml` | push / PR | **No — detection only** |

All four call the same scanner, `scripts/secret-scan.sh` (exit `0` clean / `2` secret /
`3` could-not-prove-clean; precedence `3 > 2 > 0`; hits to stderr, stdout stays empty).

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
  run the pre-commit pair

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

On a **new branch** the pre-push range is `<sha> --not --remotes`, which trusts local
remote-tracking refs. A stale or forged tracking ref can exclude commits the remote will
actually receive.

## CI is detection, not a gate

On a `push` event the workflow runs **after** the objects are already on GitHub. It cannot
prevent exposure; it tells you exposure happened. Treat a CI secret failure as an incident:
**rotate the credential at the provider first**, then clean history. Removing the commit
does not un-publish it.

## Why there are no JWT or connection-string patterns

Measured on this repo: the postgres-DSN lane produced **0** true positives across 302
tracked files and **1** confirmed false positive, and needed two hand-tuned placeholder
filter tables. A greedy `eyJ`-prefix or `scheme://user:pass@host` rule matches ordinary
documentation.

The failure mode is asymmetric and severe: a false positive jams **every** commit in this
repo *and* silently blocks the async auto-push, so the machine stops syncing and nothing
says why. A missed exotic secret is one exposure; a false positive is a dead toolchain.
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

**What the suite covers, precisely:** `scripts/secret-scan.sh` and the `pre-commit` /
`pre-push` hooks generated by `install-git-hooks.sh`, exercised against a throwaway repo and
a local bare remote. It does **not** cover `dotfiles-sync.sh`, the pause-marker reporting
path, or the CI workflow — those are verified by hand. A green suite means the scanner and
the two git hooks behave; it is not a statement about the whole chain.

Fixture credentials in the test suite are assembled at **runtime** from fragments — a
literal token in a tracked file would make the repo's own full-tree scan red forever.
