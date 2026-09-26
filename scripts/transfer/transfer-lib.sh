#!/usr/bin/env bash
# transfer-lib.sh - shared primitives for /transfer (transfer-send.sh), resumework and transfer-doctor.
#
# Source it; it defines functions only (plus TX_LIB_DIR / TX_REPO_DIR) and has no side effects.
# macOS bash 3.2 + BSD tools: no mapfile, no associative arrays, no timeout(1) (pt_run instead).
#
# Provides (FROZEN - other scripts code against these names and behaviors):
#   tx_new_code                 -> TX-XXXX-XXXX-XXXX-XXXX (80 bits, Crockford base32, from `openssl rand 10`)
#   tx_normalize <code>         -> 16 upper-case chars (strips TX- and dashes, I/L->1, O->0); rc 2 if invalid
#   tx_format <normalized>      -> TX-XXXX-XXXX-XXXX-XXXX
#   tx_locator <code>           -> first 16 hex of sha256(normalized code) - the bundle's file name
#   tx_openssl                  -> absolute path of an openssl that supports -pbkdf2 (prefers /usr/bin)
#   tx_encrypt <in> <out> <code>, tx_decrypt <in> <out> <code>
#                               -> AES-256-CBC, PBKDF2-SHA256 600000 iterations, passphrase on STDIN
#                                  (never argv, never a here-string). Decrypt failure removes <out>, rc 3.
#   tx_guard_path <path>        -> rc 2 (with a reason on stderr) if the path resolves inside the PUBLIC
#                                  dotfiles repo ($HOME/.claude-dotfiles or this script's own checkout)
#   tx_drop_dir                 -> prints (and creates) the iCloud drop folder; TX_DROP_DIR overrides
#   tx_log <msg>                -> appends to ~/.claude/logs/transfer.log (mode 600); codes are redacted
#   tx_expire_sweep             -> deletes *.tx / *.tx.sha256 / *.tx.failed older than 7 days in the drop dir
#   tx_is_secret_name <path>    -> rc 0 if the basename looks secret-bearing. REPORTING ONLY: such
#                                  files travel inside the encrypted bundle; their names are listed
#                                  in the manifest (secret_named_files_moved)
#   tx_is_never_name <relpath>  -> rc 0 if the path is machine-bound state (locks, sentinels, liveness,
#                                  pid files, sockets, keychains) - never copied
#   tx_is_never_home <claude|codex> <rel-to-state-dir>
#                               -> rc 0 if a Claude/Codex state file is machine-bound (login
#                                  credentials, the session registry, Codex auth.json and thread
#                                  locks) or tx_is_never_name says so - never copied
#   tx_is_heavy_path <relpath>  -> rc 0 if a component is a rebuildable heavy dir (TX_HEAVY_DIRS)
#   TX_HEAVY_DIRS               -> the space-separated heavy dir names (one list: tx_is_heavy_path and
#                                  transfer-send.sh's repo walker both read it)
#   tx_git_diff_head <dir>      -> the ONE canonical `git diff HEAD` both Macs hash (config-proof flags)
#   tx_git_info_exclude <repo>  -> adds TRANSFER/CLAUDE.local/MISSION patterns to <common-dir>/info/exclude
#   tx_resolve_self [path]      -> real directory of path after following symlinks (resumework runs via
#                                  a ~/.local/bin symlink)
#   tx_alias_homes              -> one physical path per VERIFIED home alias of this account: a real
#                                  directory <base>/<name> (base /Users) holding a .home-alias-of
#                                  marker (make-home-alias.sh) whose alias_of= line names `id -un`,
#                                  both owned by this account. TX_TEST_ALIAS_HOMES_BASE replaces
#                                  the base, honored ONLY under TRANSFER_TESTS_ALLOW_DEV=true.
#
# PLACEMENT RULE (transfer-send.sh writes it, resumework enforces it): every payload file is one of
#   "home" - Claude/Codex state ($HOME/.claude/..., $CODEX_HOME/...): stored relative to that state
#            dir and placed under the RECEIVER's own real $HOME/.claude or CODEX_HOME;
#   "abs"  - repo/worktree content (ROOT handoff, MISSION files, TRANSFER notes, untracked and
#            ignored files): stored by absolute path and placed at the SAME absolute path, which must
#            sit under the receiver's own $HOME or one of its verified home aliases.
#
# WHY the public-repo guard: ~/.claude-dotfiles is a PUBLIC GitHub repo whose auto-sync stages
# everything with `git add -A` and pushes. A bundle, staging dir or log written there is published.

[ -n "${_TX_LIB_LOADED:-}" ] && return 0
readonly _TX_LIB_LOADED=1

tx_resolve_self() {  # tx_resolve_self [path] -> real directory holding path
  local p="${1:-${BASH_SOURCE[1]:-$0}}" t n=0
  while [ -L "$p" ] && [ "$n" -lt 40 ]; do
    t=$(readlink "$p") || break
    case "$t" in /*) p="$t" ;; *) p="$(dirname "$p")/$t" ;; esac
    n=$((n + 1))
  done
  (cd -P "$(dirname "$p")" 2>/dev/null && pwd -P)
}

TX_LIB_DIR="$(tx_resolve_self "${BASH_SOURCE[0]}")"
TX_REPO_DIR="$(cd -P "$TX_LIB_DIR/../.." 2>/dev/null && pwd -P)"
# shellcheck source=../lib/portable-timeout.sh
. "$TX_REPO_DIR/scripts/lib/portable-timeout.sh"
# shellcheck source=../hooks/lib/handoff-locate.sh
. "$TX_REPO_DIR/scripts/hooks/lib/handoff-locate.sh"

# ---------------------------------------------------------------------------------------------
# Codes. Crockford base32 (no I, L, O, U) so a code read aloud or typed over Remote Desktop
# survives case changes and the usual look-alike mistakes.
# ---------------------------------------------------------------------------------------------
_TX_B32="0123456789ABCDEFGHJKMNPQRSTVWXYZ"

_tx_b32_40() {  # 10 hex chars (40 bits) -> 8 base32 chars; fits bash's 64-bit arithmetic
  local n=$((16#$1)) i out=""
  for i in 7 6 5 4 3 2 1 0; do
    out="${out}${_TX_B32:$(( (n >> (i * 5)) & 31 )):1}"
  done
  printf '%s' "$out"
}

tx_format() {  # tx_format <16 normalized chars>
  printf 'TX-%s-%s-%s-%s\n' "${1:0:4}" "${1:4:4}" "${1:8:4}" "${1:12:4}"
}

tx_new_code() {
  local ossl hex
  ossl=$(tx_openssl) || return 1
  hex=$("$ossl" rand 10 2>/dev/null | od -An -tx1 | tr -d ' \n')
  case "$hex" in *[!0-9a-f]*) return 1 ;; esac
  [ "${#hex}" -eq 20 ] || { echo "transfer: openssl rand returned too few bytes" >&2; return 1; }
  tx_format "$(_tx_b32_40 "${hex:0:10}")$(_tx_b32_40 "${hex:10:10}")"
}

tx_normalize() {  # tx_normalize <code> -> 16 chars, rc 2 when it cannot be a code
  local c
  c=$(printf '%s' "${1:-}" | tr 'a-z' 'A-Z' | tr -d ' \t\r\n')
  case "$c" in TX-*) c="${c#TX-}" ;; esac
  c=$(printf '%s' "$c" | tr -d '-')
  # "TX" typed without its dash: only strip it when the remainder is exactly a full code, because
  # T and X are themselves valid code characters.
  if [ "${#c}" -eq 18 ]; then
    case "$c" in TX*) c="${c#TX}" ;; esac
  fi
  c=$(printf '%s' "$c" | tr 'ILO' '110')
  case "$c" in "" | *[!0-9ABCDEFGHJKMNPQRSTVWXYZ]*) return 2 ;; esac
  [ "${#c}" -eq 16 ] || return 2
  printf '%s\n' "$c"
}

tx_locator() {
  local n
  n=$(tx_normalize "${1:-}") || return 2
  printf '%s' "$n" | shasum -a 256 | cut -c1-16
}

# ---------------------------------------------------------------------------------------------
# Crypto. OpenSSL `enc` has no authentication tag: integrity comes from the sha256 sidecar (a
# corruption check) plus the per-file sha256 manifest inside the archive (checked after decrypt).
# LibreSSL (/usr/bin) and OpenSSL 3 produce interchangeable output for these exact flags.
# ---------------------------------------------------------------------------------------------
tx_openssl() {
  local c h
  for c in /usr/bin/openssl "$(command -v openssl 2>/dev/null)"; do
    [ -n "$c" ] && [ -x "$c" ] || continue
    # Captured, not piped: `enc -help` exits non-zero on both flavors, which under a caller's
    # `set -o pipefail` would fail the pipeline and silently skip a perfectly good binary.
    h=$("$c" enc -help 2>&1)
    case "$h" in
      *-pbkdf2*) printf '%s\n' "$c"; return 0 ;;
    esac
  done
  echo "transfer: no openssl with -pbkdf2 support found" >&2
  return 1
}

tx_encrypt() {  # tx_encrypt <in> <out> <code>
  local pass ossl
  pass=$(tx_normalize "${3:-}") || { echo "transfer: not a valid transfer code" >&2; return 2; }
  ossl=$(tx_openssl) || return 1
  # printf is a shell builtin, so the passphrase never appears in any process's argv.
  if ! printf '%s' "$pass" | "$ossl" enc -aes-256-cbc -pbkdf2 -iter 600000 -md sha256 -salt \
       -pass stdin -in "$1" -out "$2" 2>/dev/null; then
    rm -f "$2"
    return 1
  fi
  return 0
}

tx_decrypt() {  # tx_decrypt <in> <out> <code>; rc 3 on a wrong code / corrupt input (out removed)
  local pass ossl
  pass=$(tx_normalize "${3:-}") || { echo "transfer: not a valid transfer code" >&2; return 2; }
  ossl=$(tx_openssl) || return 1
  if ! printf '%s' "$pass" | "$ossl" enc -d -aes-256-cbc -pbkdf2 -iter 600000 -md sha256 \
       -pass stdin -in "$1" -out "$2" 2>/dev/null; then
    rm -f "$2"
    return 3
  fi
  return 0
}

# ---------------------------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------------------------
_tx_resolve_path() {  # physical path; a not-yet-existing tail is appended to its nearest real ancestor
  local p="$1" tail="" t n=0 dir=""
  case "$p" in /*) ;; *) p="$PWD/$p" ;; esac
  while [ "$n" -lt 256 ]; do
    n=$((n + 1))
    if [ -d "$p" ]; then
      dir=$(cd -P "$p" 2>/dev/null && pwd -P) && break
    fi
    if [ -L "$p" ]; then
      t=$(readlink "$p") || break
      case "$t" in /*) p="$t" ;; *) p="$(dirname "$p")/$t" ;; esac
      continue
    fi
    tail="/$(basename "$p")$tail"
    p=$(dirname "$p")
  done
  printf '%s%s\n' "${dir%/}" "$tail"
}

tx_guard_path() {  # rc 2 + reason on stderr when <path> resolves inside the public dotfiles repo
  local r d dr
  [ -n "${1:-}" ] || { echo "transfer: REFUSED: empty path" >&2; return 2; }
  case "/$1/" in
    */../*) echo "transfer: REFUSED: path contains '..': $1" >&2; return 2 ;;
  esac
  r=$(_tx_resolve_path "$1")
  for d in "$HOME/.claude-dotfiles" "$TX_REPO_DIR"; do
    [ -n "$d" ] || continue
    dr=$(_tx_resolve_path "$d")
    [ -n "$dr" ] || continue
    case "$r/" in
      "$dr"/*)
        echo "transfer: REFUSED: $1 is inside the public dotfiles repo ($dr); transfer artifacts never go there" >&2
        return 2
        ;;
    esac
  done
  return 0
}

tx_alias_homes() {  # verified home aliases of this account (see the header); physical paths
  local base="/Users" me d who
  if [ "${TRANSFER_TESTS_ALLOW_DEV:-}" = "true" ] && [ -n "${TX_TEST_ALIAS_HOMES_BASE:-}" ]; then
    base="$TX_TEST_ALIAS_HOMES_BASE"
  fi
  me=$(id -un 2>/dev/null) || return 0
  [ -n "$me" ] || return 0
  for d in "$base"/*; do
    [ -d "$d" ] && [ ! -L "$d" ] && [ -O "$d" ] || continue
    [ -f "$d/.home-alias-of" ] && [ ! -L "$d/.home-alias-of" ] && [ -O "$d/.home-alias-of" ] || continue
    who=$(sed -n 's/^alias_of=//p' "$d/.home-alias-of" 2>/dev/null | head -1)
    [ "$who" = "$me" ] || continue
    (cd -P "$d" 2>/dev/null && pwd -P)
  done
  return 0
}

tx_drop_dir() {
  local d="${TX_DROP_DIR:-$HOME/Library/Mobile Documents/com~apple~CloudDocs/claude-transfers}"
  tx_guard_path "$d" || return 2
  mkdir -p "$d" 2>/dev/null || { echo "transfer: cannot create drop folder $d" >&2; return 1; }
  printf '%s\n' "$d"
}

# ---------------------------------------------------------------------------------------------
# Logging (mode 600, bounded ring like auto-compact-sentinel.sh). Callers pass locators, never
# codes; a code-shaped token is redacted anyway as a second line of defense.
# ---------------------------------------------------------------------------------------------
tx_log() {
  local log="$HOME/.claude/logs/transfer.log" dir msg size
  dir=$(dirname "$log")
  if [ ! -d "$dir" ]; then
    mkdir -p "$dir" 2>/dev/null
    chmod 700 "$dir" 2>/dev/null
  fi
  msg=$(printf '%s' "$*" | tr '\n' ' ' | sed -E 's/[Tt][Xx]-?[0-9A-Za-z]{4}-?[0-9A-Za-z]{4}-?[0-9A-Za-z]{4}-?[0-9A-Za-z]{4}/TX-<redacted>/g')
  ( umask 077 && printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$msg" >> "$log" ) 2>/dev/null || return 0
  chmod 600 "$log" 2>/dev/null
  size=$(wc -c < "$log" 2>/dev/null | tr -d '[:space:]')
  if [ -n "$size" ] && [ "$size" -gt 262144 ]; then
    ( umask 077 && tail -c 131072 "$log" > "$log.tmp.$$" ) 2>/dev/null && mv "$log.tmp.$$" "$log" 2>/dev/null
  fi
  return 0
}

tx_expire_sweep() {  # delete bundles nobody collected within 7 days (the code sits in A's chat history)
  local d f n=0
  d=$(tx_drop_dir 2>/dev/null) || return 0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if rm -f "$f" 2>/dev/null; then
      n=$((n + 1))
      tx_log "expire: removed $(basename "$f") (older than 7 days)"
    fi
  done <<EOF
$(find "$d" -maxdepth 1 -type f \( -name '*.tx' -o -name '*.tx.sha256' -o -name '*.tx.failed' -o -name '.*.tmp.*' \) -mmin +10080 2>/dev/null)
EOF
  [ "$n" -gt 0 ] && echo "transfer: expired $n uncollected bundle file(s) older than 7 days" >&2
  return 0
}

# ---------------------------------------------------------------------------------------------
# What never travels. Owner policy 2026-09-26: "just move everything" - secrets and every other
# untracked or ignored repo file travel inside the encrypted bundle. The two things that never do:
# machine-bound state (only meaningful on the Mac that wrote it; copying it would lie to the other
# Mac about locks, liveness, logins or live processes) and rebuildable heavy dirs.
# ---------------------------------------------------------------------------------------------
TX_HEAVY_DIRS="node_modules dist .next coverage .git .turbo .venv __pycache__"

tx_is_secret_name() {  # rc 0 if the BASENAME looks secret-bearing (case-insensitive); reporting only
  local b="${1##*/}" had=0 rc=1
  shopt -q nocasematch && had=1
  shopt -s nocasematch
  case "$b" in
    .env* | *.env | *creds* | *credential* | *.pem | *.key | *.p12 | .envrc | .npmrc | *secret* | auth.json) rc=0 ;;
  esac
  [ "$had" = 1 ] || shopt -u nocasematch
  return "$rc"
}

tx_is_never_name() {  # rc 0 if <relpath> is machine-bound state: pid/tty-bound, locks, liveness
  local rel="$1" base="${1##*/}" rest comp
  case "$base" in
    auto-compact-* | mission-liveness-* | resumed-* | .ctx-zone-bucket-* | transferred-* | \
    transfer-arrived-* | prod.lock | .DS_Store | *.pid | *.sock | *.socket | \
    *.keychain | *.keychain-db) return 0 ;;
  esac
  rest="$rel"
  while [ -n "$rest" ]; do
    comp="${rest%%/*}"
    case "$comp" in
      # Package-manager lockfiles are project content, not runtime locks: they travel.
      yarn.lock | bun.lock | Cargo.lock | Gemfile.lock | poetry.lock | Pipfile.lock | composer.lock | \
      flake.lock | pdm.lock | uv.lock | Podfile.lock | mix.lock | pubspec.lock) ;;
      *.lock | node_modules) return 0 ;;
    esac
    [ "$rest" = "$comp" ] && break
    rest="${rest#*/}"
  done
  return 1
}

tx_is_never_home() {  # tx_is_never_home <claude|codex> <path relative to that state dir>
  case "$1:$2" in
    claude:.credentials* | claude:sessions/* | codex:auth.json | codex:thread-writer-locks/*) return 0 ;;
  esac
  tx_is_never_name "$2"
}

tx_is_heavy_path() {  # rc 0 if a component is a rebuildable dependency/output dir (TX_HEAVY_DIRS)
  local rest="$1" comp
  while [ -n "$rest" ]; do
    comp="${rest%%/*}"
    case " $TX_HEAVY_DIRS " in *" $comp "*) return 0 ;; esac
    [ "$rest" = "$comp" ] && break
    rest="${rest#*/}"
  done
  return 1
}

# ---------------------------------------------------------------------------------------------
# Git
# ---------------------------------------------------------------------------------------------
tx_git_diff_head() {  # the canonical uncommitted-change patch; both Macs hash exactly this output
  # Every flag pins something a user config could otherwise change between the two Macs: colour,
  # prefixes, external/textconv drivers, rename detection, and abbreviated blob ids (whose length
  # depends on each clone's object count).
  git -C "$1" -c core.quotePath=true -c diff.noprefix=false -c diff.mnemonicPrefix=false \
    -c diff.relative=false diff --no-color --no-ext-diff --no-textconv --no-renames \
    --full-index --binary HEAD
}

tx_git_info_exclude() {  # keep sid-keyed handoff/transfer files out of `git status` (local, untracked)
  local common f p
  common=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  [ -n "$common" ] || return 1
  f="$common/info/exclude"
  mkdir -p "$common/info" 2>/dev/null || return 1
  if [ -s "$f" ] && [ -n "$(tail -c1 "$f")" ]; then printf '\n' >> "$f"; fi
  for p in 'TRANSFER.*.md' 'CLAUDE.local.*' 'MISSION.*' '.mission-backups/'; do
    grep -qxF -- "$p" "$f" 2>/dev/null || printf '%s\n' "$p" >> "$f"
  done
  return 0
}
