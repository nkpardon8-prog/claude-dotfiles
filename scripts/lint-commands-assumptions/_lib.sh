#!/usr/bin/env bash
# _lib.sh - shared fixture builder and assertions for the lint-commands assumption suite.
# SOURCED by every NN-*.sh case; it is not a case itself (run-all.sh lists the cases
# explicitly, and the leading underscore keeps it out of the NN-* namespace).
#
# HERMETIC BY CONSTRUCTION, and the mechanism is the thing under test. Each case builds a
# throwaway git repo under `mktemp -d` shaped like the dotfiles repo:
#
#     <sandbox>/commands/*.md              copies of the live command files
#     <sandbox>/scripts/lint-commands/*.sh copies of the live lint scripts
#
# and invokes the SANDBOX COPY of the lint. Because the lint now derives ROOT from its own
# BASH_SOURCE and the staged set from `git rev-parse --show-toplevel`, that copy reads the
# sandbox's commands/ and the sandbox's index - it cannot reach $HOME/.claude-dotfiles or
# the real git index. No env override was added to the lint for testing; the ROOT split IS
# the seam, so exercising it is also proof that it works.
#
# WHY COPIES OF THE LIVE COMMAND FILES rather than checked-in snapshots: a snapshot of
# three files totalling ~100k chars would duplicate the very text the lint guards, and
# would drift the moment a command file is edited - a green suite proving a stale premise.
# Copying makes every case start from the CURRENT truth and mutate exactly one thing, so a
# red result is attributable to the mutation. The cost is that the suite depends on the
# live files being lint-clean; lc_baseline asserts that explicitly and says so when it is
# not, rather than failing somewhere confusing later.
#
# bash 3.2 safe (macOS /bin/bash): no associative arrays, no `mapfile`, no ${var^^}.

# --- gate --------------------------------------------------------------------------------
# script.md:35 reserves _SMOKE_ALLOW_ gates for suites that touch live infrastructure, and a
# hermetic suite would normally carry none. This one keeps the gate for uniformity with its
# siblings in the same Validation-Gates list: a suite that silently runs when the others
# refuse trains the wrong reflex. UNIFORMITY CONVENTION, NOT A SAFETY CLAIM.
lc_gate() {
  if [ "${LINTCMD_SMOKE_ALLOW_DEV:-}" != "true" ]; then
    echo "REFUSED: set LINTCMD_SMOKE_ALLOW_DEV=true to run assumption tests" >&2
    exit 2
  fi
}

lc_cleanup() {
  [ -n "${BASE:-}" ] || return 0
  rm -rf "$BASE" 2>/dev/null || echo "CLEANUP WARNING: ${BASE}" >&2
}

# g - git inside the sandbox with a fixed identity and NO hooks. `-c core.hooksPath` points
# at an empty dir so the sandbox can never execute the real repo's generated pre-commit
# (which is itself under test in this task - a sandbox commit must not run it).
g() {  # g <repo-or-worktree> <git args...>
  local r="$1"; shift
  git -C "$r" -c user.email=lint@test -c user.name=linttest -c commit.gpgsign=false \
      -c "core.hooksPath=${BASE}/nohooks" "$@"
}

lc_setup() {  # lc_setup <case-name>
  NAME="$1"
  DIR="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd -P)"
  SRC="$(cd "${DIR}/.." && pwd -P)"                      # <repo>/scripts
  REPO_SRC="$(cd "${DIR}/../.." && pwd -P)"              # <repo>
  [ -f "${SRC}/lint-commands/lint-skill-contract.sh" ] || { echo "INFRA: missing lint-skill-contract.sh" >&2; exit 3; }
  [ -f "${SRC}/lint-commands/lint-skill-size.sh" ]     || { echo "INFRA: missing lint-skill-size.sh" >&2; exit 3; }
  command -v python3 >/dev/null 2>&1 || { echo "INFRA: python3 is required" >&2; exit 3; }
  command -v git >/dev/null 2>&1     || { echo "INFRA: git is required" >&2; exit 3; }

  BASE="$(mktemp -d "${TMPDIR:-/tmp}/lintcmd-XXXXXX")" || { echo "INFRA: mktemp failed" >&2; exit 3; }
  trap lc_cleanup EXIT
  mkdir -p "${BASE}/nohooks" || { echo "INFRA: cannot create ${BASE}/nohooks" >&2; exit 3; }

  FIX="${BASE}/repo"
  mkdir -p "${FIX}/commands" "${FIX}/scripts/lint-commands" || { echo "INFRA: cannot build fixture" >&2; exit 3; }
  cp "${REPO_SRC}/commands/"*.md "${FIX}/commands/" 2>/dev/null || { echo "INFRA: cannot copy commands/*.md" >&2; exit 3; }

  # NEGATIVE CONTROL (documented, repeatable): LINTCMD_NEGATIVE_CONTROL=head populates the
  # fixture with the lint scripts as of git HEAD instead of the working copy. Every case is
  # expected to go RED under it - that is how each was watched failing before being
  # trusted. Note the HEAD scripts hardcode ROOT="$HOME/.claude-dotfiles", so in that mode
  # they read the REAL commands/ (read-only) and ignore the sandbox entirely; that is
  # precisely the defect the ROOT split fixes, and it is why the control is honest.
  if [ "${LINTCMD_NEGATIVE_CONTROL:-}" = "head" ]; then
    git -C "$REPO_SRC" show "HEAD:scripts/lint-commands/lint-skill-contract.sh" \
      > "${FIX}/scripts/lint-commands/lint-skill-contract.sh" 2>/dev/null \
      || { echo "INFRA: cannot read HEAD lint-skill-contract.sh" >&2; exit 3; }
    git -C "$REPO_SRC" show "HEAD:scripts/lint-commands/lint-skill-size.sh" \
      > "${FIX}/scripts/lint-commands/lint-skill-size.sh" 2>/dev/null \
      || { echo "INFRA: cannot read HEAD lint-skill-size.sh" >&2; exit 3; }
    chmod +x "${FIX}/scripts/lint-commands/"*.sh
  else
    cp "${SRC}/lint-commands/"*.sh "${FIX}/scripts/lint-commands/" || { echo "INFRA: cannot copy lint scripts" >&2; exit 3; }
  fi

  CONTRACT="${FIX}/scripts/lint-commands/lint-skill-contract.sh"
  SIZE="${FIX}/scripts/lint-commands/lint-skill-size.sh"

  git init -q "$FIX" >/dev/null 2>&1 || { echo "INFRA: git init failed" >&2; exit 3; }
  g "$FIX" add -A >/dev/null 2>&1 || { echo "INFRA: git add failed" >&2; exit 3; }
  g "$FIX" commit -qm "fixture baseline" >/dev/null 2>&1 || { echo "INFRA: git commit failed" >&2; exit 3; }

  FAILS=()
  LC_OUT=""
  LC_RC=0
}

# --- assertions ---------------------------------------------------------------------------
lc_fail() { echo "  FAIL: $1" >&2; FAILS+=("$1"); }
lc_ok()   { echo "  ok: $1"; }

# lc_run - run a lint script with a chosen cwd and assert its exit code.
#   lc_run <expected-exit> <label> <cwd> <script> [args...]
lc_run() {
  local want="$1" label="$2" cwd="$3"; shift 3
  LC_OUT="$( cd "$cwd" && bash "$@" 2>&1 )"
  LC_RC=$?
  if [ "$LC_RC" != "$want" ]; then
    lc_fail "${label}: exit ${LC_RC}, expected ${want}"
    echo "$LC_OUT" | sed 's/^/    | /' >&2
  else
    lc_ok "${label} (exit ${LC_RC})"
  fi
}

lc_out_has()   { case "$LC_OUT" in *"$1"*) lc_ok "$2: output names '$1'";; *) lc_fail "$2: output does NOT name '$1'"; echo "$LC_OUT" | sed 's/^/    | /' >&2;; esac; }
lc_out_lacks() { case "$LC_OUT" in *"$1"*) lc_fail "$2: output unexpectedly names '$1'"; echo "$LC_OUT" | sed 's/^/    | /' >&2;; *) lc_ok "$2: output does not name '$1'";; esac; }

# --- fixture manipulation -------------------------------------------------------------------
# lc_edit - rewrite a fixture command file with python. The snippet gets `s` (the file text)
# and must leave the new text in `s`. Exact, and visible in the case source.
lc_edit() {  # lc_edit <repo-relative-path> <python snippet>
  local f="${FIX}/$1"
  python3 -c "
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
$2
open(p, 'w', encoding='utf-8').write(s)" "$f" || { echo "INFRA: lc_edit failed on $1" >&2; exit 3; }
}

lc_restore() {  # lc_restore  - back to the committed baseline, index and worktree
  g "$FIX" reset -q >/dev/null 2>&1
  g "$FIX" checkout -q -- . >/dev/null 2>&1
}

lc_stage()   { g "$FIX" add -- "$@" >/dev/null 2>&1 || { echo "INFRA: git add $* failed" >&2; exit 3; }; }
lc_unstage() { g "$FIX" reset -q -- "$@" >/dev/null 2>&1; }

# lc_touch - a harmless edit so a file can be STAGED without violating anything.
lc_touch() { lc_edit "$1" "s = s + '\n<!-- lint fixture touch -->\n'"; }

# lc_baseline - the pristine fixture must be lint-clean, or nothing downstream is
# attributable. Skipped under the negative control, where a red baseline is the point.
lc_baseline() {
  [ "${LINTCMD_NEGATIVE_CONTROL:-}" = "head" ] && return 0
  local out rc
  out="$( cd "$FIX" && bash "$CONTRACT" 2>&1 )"; rc=$?
  if [ "$rc" != 0 ]; then
    lc_fail "baseline: the fixture (copies of the LIVE commands/) is not lint-clean - fix the real repo first, every case below is unattributable until then"
    echo "$out" | sed 's/^/    | /' >&2
  else
    lc_ok "baseline: pristine fixture passes the contract lint (exit 0)"
  fi
}

# --- finish -----------------------------------------------------------------------------
lc_finish() {  # lc_finish <fingerprint-json> <summary>
  local fp="${DIR}/${NAME}.fingerprint.json"
  if [ "${#FAILS[@]}" -gt 0 ]; then
    echo "FAIL ${NAME}: ${#FAILS[@]} assertion(s)" >&2
    exit 1
  fi
  printf '%s\n' "$1" > "$fp"
  echo "PASS ${NAME}: $2"
  exit 0
}
