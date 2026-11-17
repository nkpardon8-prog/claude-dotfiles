#!/bin/bash
# Install the Claude dotfiles Codex bridge globally for this user.

set -euo pipefail

REPO="${CLAUDE_DOTFILES_DIR:-$HOME/.claude-dotfiles}"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
QUIET=0
INSTALL_SHELL=1
RULES_ONLY=0

for arg in "$@"; do
    case "$arg" in
        --quiet) QUIET=1 ;;
        --skip-shell|--no-shell) INSTALL_SHELL=0 ;;
        --rules-only) RULES_ONLY=1; INSTALL_SHELL=0 ;;   # global rules changed: refresh only AGENTS.md
        *)
            echo "usage: $0 [--quiet] [--skip-shell] [--rules-only]" >&2
            exit 2
            ;;
    esac
done

log() {
    [ "$QUIET" -eq 1 ] || printf '%s\n' "$*"
}

[ -d "$REPO" ] || { echo "missing repo: $REPO" >&2; exit 1; }

# One install at a time on this machine (the rules-in-force hook starts this from many windows at once,
# and every Codex home shares codex/generated/). An OS-held lock: released when the holder exits, even
# by crash, so there is no stale-lock takeover to race. After 20 s of waiting we leave; the run holding
# the lock regenerates from the same files, and the hook re-checks the hash on every prompt.
LOCKFILE="${TMPDIR:-/tmp}/claude-dotfiles-install-codex.lock"
if [ -z "${INSTALL_CODEX_LOCKED:-}" ]; then
    export INSTALL_CODEX_LOCKED=1
    if command -v flock >/dev/null 2>&1; then
        exec flock -w 20 "$LOCKFILE" bash "$0" "$@"
    elif [ -x /usr/bin/lockf ]; then
        exec /usr/bin/lockf -t 20 "$LOCKFILE" bash "$0" "$@"
    fi
    log "no flock or lockf on this machine: installing without a lock"
fi

if [ "$RULES_ONLY" -eq 1 ]; then
    python3 "$REPO/scripts/generate-codex-layer.py" --rules-only
else
    python3 "$REPO/scripts/generate-codex-layer.py"
    mkdir -p "$CODEX_HOME/skills"
    rm -rf "$CODEX_HOME/skills/claude-dotfiles"
    cp -R "$REPO/codex/generated/skills/claude-dotfiles" "$CODEX_HOME/skills/claude-dotfiles"
fi

# Codex reads its global instructions from $CODEX_HOME/AGENTS.md (proven 2026-11-17 on codex-cli
# 0.160: a block in instructions.md never reached the model). The managed block goes there; Pane's
# own block and anything else in the file stay untouched. The old copy in instructions.md is removed.
mkdir -p "$CODEX_HOME"
AGENTS="$CODEX_HOME/AGENTS.md"
LEGACY="$CODEX_HOME/instructions.md"
BLOCK="$REPO/codex/generated/instructions-block.md"

python3 - "$AGENTS" "$LEGACY" "$BLOCK" <<'PY2'
import os
import sys
from pathlib import Path

agents, legacy, block_path = (Path(a) for a in sys.argv[1:4])
block = block_path.read_text()
begin = "<!-- BEGIN CLAUDE-DOTFILES-CODEX -->"
end = "<!-- END CLAUDE-DOTFILES-CODEX -->"


def without_block(text: str) -> tuple[str, str]:
    if begin in text and end in text:
        pre, rest = text.split(begin, 1)
        _, post = rest.split(end, 1)
        return pre.rstrip(), post.lstrip()
    return text.rstrip(), ""


def read(path: Path) -> str:
    return path.read_text() if path.exists() else ""


def atomic_write(path: Path, text: str, expect: str) -> bool:
    """Replace path with text unless someone else changed it since we read `expect` (Pane rewrites its
    own block in AGENTS.md). False on that race, so the caller re-reads and merges again."""
    tmp = path.with_name(f".{path.name}.install-codex-{os.getpid()}.tmp")
    tmp.write_text(text)
    if read(path) != expect:
        tmp.unlink()
        return False
    os.replace(tmp, path)
    return True


for _ in range(5):
    old = read(agents)
    pre, post = without_block(old)
    new = "\n\n".join(p for p in (pre, block.strip(), post.rstrip()) if p) + "\n"
    if old == new or atomic_write(agents, new, old):
        break

if legacy.exists():
    old = legacy.read_text()
    if begin in old and end in old:
        pre, post = without_block(old)
        rest = "\n\n".join(p for p in (pre, post.rstrip()) if p)
        if rest.strip():
            atomic_write(legacy, rest + "\n", old)
        else:
            legacy.unlink()
PY2

if [ "$INSTALL_SHELL" -eq 1 ]; then
    ZSHRC="$HOME/.zshrc"
    touch "$ZSHRC"
    python3 - "$ZSHRC" "$REPO" <<'PY'
from pathlib import Path
import sys

zshrc = Path(sys.argv[1])
repo = sys.argv[2]
begin = "# >>> claude-dotfiles codex bridge >>>"
end = "# <<< claude-dotfiles codex bridge <<<"
block = f"""{begin}
# Refresh generated Codex skills/instructions before each Codex launch.
export CLAUDE_DOTFILES_DIR="${{CLAUDE_DOTFILES_DIR:-{repo}}}"
codex() {{
  local dotfiles="${{CLAUDE_DOTFILES_DIR:-$HOME/.claude-dotfiles}}"
  if [[ -x "$dotfiles/scripts/codex-sync.sh" ]]; then
    "$dotfiles/scripts/codex-sync.sh" --quiet >/dev/null 2>&1 || true
  fi
  command codex "$@"
}}
alias codex-sync-dotfiles="$CLAUDE_DOTFILES_DIR/scripts/codex-sync.sh"
{end}
"""
old = zshrc.read_text() if zshrc.exists() else ""
if begin in old and end in old:
    pre, rest = old.split(begin, 1)
    _, post = rest.split(end, 1)
    new = pre.rstrip() + "\n\n" + block + "\n" + post.lstrip()
else:
    new = old.rstrip() + "\n\n" + block + "\n"
zshrc.write_text(new)
PY
fi

log "Installed Codex bridge:"
log "  skills: $CODEX_HOME/skills/claude-dotfiles"
log "  instructions: $AGENTS"
log "  shell wrapper: $([ "$INSTALL_SHELL" -eq 1 ] && echo installed || echo skipped)"
