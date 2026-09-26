#!/usr/bin/env bash
# 05 - nothing transfer-related may ever be written under the public dotfiles repo.
#   A1 transfer-send.sh refuses (exit 2) when the chat's cwd is inside $HOME/.claude-dotfiles.
#   A2 tx_guard_path itself refuses a path inside the REAL dotfiles checkout (TX_REPO_DIR),
#      independent of whatever $HOME a caller happens to be using.
#   A3 tx_drop_dir refuses when TX_DROP_DIR points inside a fake $HOME/.claude-dotfiles.
#   A4 tx_drop_dir refuses when TX_DROP_DIR points inside the REAL dotfiles checkout.
set -uo pipefail
[ "${TRANSFER_TESTS_ALLOW_DEV:-}" = "true" ] || { echo "REFUSED: set TRANSFER_TESTS_ALLOW_DEV=true to run" >&2; exit 2; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/_common.sh"

HOME_T=$(tx_sandbox 05)
cleanup() { rm -rf "$HOME_T"; }
trap cleanup EXIT
DROP="$HOME_T/drop"

# --- A1: full transfer-send.sh, cwd inside a FAKE $HOME/.claude-dotfiles -------------------------
SID=$(tx_new_sid)
FAKE_DOTFILES_CWD="$HOME_T/.claude-dotfiles/some-project"
mkdir -p "$FAKE_DOTFILES_CWD"
tx_write_transcript "$HOME_T" "$SID" "$FAKE_DOTFILES_CWD"
tx_run_send "$HOME_T" "$DROP" --tool claude --sid "$SID" --cwd "$FAKE_DOTFILES_CWD"
if [ "$TX_LAST_RC" -ne 2 ]; then
  fail "A1: expected refuse (rc=2) for a cwd inside \$HOME/.claude-dotfiles, got rc=$TX_LAST_RC: $(tx_combined)"
else
  case "$TX_LAST_ERR" in
    *"dotfiles"*) ;;
    *) fail "A1: refusal did not mention the dotfiles repo: $TX_LAST_ERR" ;;
  esac
fi
[ -z "$(find "$DROP" -maxdepth 1 -type f 2>/dev/null)" ] || fail "A1: a bundle was written despite the guard"

# --- A2: tx_guard_path directly, against the REAL dotfiles checkout ------------------------------
if tx_guard_path "$TX_REPO_DIR/scratch-target" 2>/tmp/tx05.err; then
  fail "A2: tx_guard_path did not refuse a path inside the real dotfiles repo ($TX_REPO_DIR)"
else
  grep -qi "dotfiles" /tmp/tx05.err || fail "A2: tx_guard_path's refusal did not mention the dotfiles repo"
fi
rm -f /tmp/tx05.err
tx_guard_path "$HOME_T/somewhere/else" || fail "A2 (control): an ordinary sandbox path was refused - the guard over-matches"

# --- A3: tx_drop_dir, TX_DROP_DIR under a FAKE HOME's .claude-dotfiles ---------------------------
( HOME="$HOME_T"; TX_DROP_DIR="$HOME_T/.claude-dotfiles/drop"; tx_drop_dir >/dev/null 2>/tmp/tx05b.err )
if [ $? -eq 0 ]; then
  fail "A3: tx_drop_dir accepted a drop dir under a fake \$HOME/.claude-dotfiles"
else
  grep -qi "dotfiles" /tmp/tx05b.err || fail "A3: tx_drop_dir's refusal did not mention the dotfiles repo"
fi
rm -f /tmp/tx05b.err

# --- A4: tx_drop_dir, TX_DROP_DIR under the REAL dotfiles checkout -------------------------------
( TX_DROP_DIR="$TX_REPO_DIR/drop"; tx_drop_dir >/dev/null 2>/tmp/tx05c.err )
if [ $? -eq 0 ]; then
  fail "A4: tx_drop_dir accepted a drop dir under the REAL dotfiles repo"
else
  grep -qi "dotfiles" /tmp/tx05c.err || fail "A4: tx_drop_dir's refusal did not mention the dotfiles repo"
fi
rm -f /tmp/tx05c.err
[ -d "$TX_REPO_DIR/drop" ] && fail "A4: tx_drop_dir actually created a directory inside the real dotfiles repo" && rmdir "$TX_REPO_DIR/drop" 2>/dev/null

ok_report "05-public-repo-guard" "transfer-send.sh + tx_guard_path + tx_drop_dir all refuse a public-dotfiles-repo path (cwd, real repo, fake-home dotfiles, real-repo drop dir)"
