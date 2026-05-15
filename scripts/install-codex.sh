#!/bin/bash
# Install the Claude dotfiles Codex bridge globally for this user.

set -euo pipefail

REPO="${CLAUDE_DOTFILES_DIR:-$HOME/.claude-dotfiles}"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
QUIET=0
INSTALL_SHELL=1

for arg in "$@"; do
    case "$arg" in
        --quiet) QUIET=1 ;;
        --skip-shell|--no-shell) INSTALL_SHELL=0 ;;
        *)
            echo "usage: $0 [--quiet] [--skip-shell]" >&2
            exit 2
            ;;
    esac
done

log() {
    [ "$QUIET" -eq 1 ] || printf '%s\n' "$*"
}

[ -d "$REPO" ] || { echo "missing repo: $REPO" >&2; exit 1; }

python3 "$REPO/scripts/generate-codex-layer.py"

mkdir -p "$CODEX_HOME/skills"
rm -rf "$CODEX_HOME/skills/claude-dotfiles"
cp -R "$REPO/codex/generated/skills/claude-dotfiles" "$CODEX_HOME/skills/claude-dotfiles"

mkdir -p "$CODEX_HOME"
INSTRUCTIONS="$CODEX_HOME/instructions.md"
BLOCK="$REPO/codex/generated/instructions-block.md"

python3 - "$INSTRUCTIONS" "$BLOCK" <<'PY'
from pathlib import Path
import sys
from datetime import datetime

instructions = Path(sys.argv[1])
block = Path(sys.argv[2]).read_text()
begin = "<!-- BEGIN CLAUDE-DOTFILES-CODEX -->"
end = "<!-- END CLAUDE-DOTFILES-CODEX -->"

old = instructions.read_text() if instructions.exists() else ""
if begin in old and end in old:
    pre, rest = old.split(begin, 1)
    _, post = rest.split(end, 1)
    new = pre.rstrip() + "\n\n" + block + "\n" + post.lstrip()
else:
    if old.strip():
        backup = instructions.with_suffix(instructions.suffix + ".backup-" + datetime.now().strftime("%Y%m%d%H%M%S"))
        backup.write_text(old)
        new = block + "\n\n# Existing Local Codex Instructions\n\n" + old.lstrip()
    else:
        new = block + "\n"
instructions.write_text(new)
PY

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
log "  instructions: $INSTRUCTIONS"
log "  shell wrapper: $([ "$INSTALL_SHELL" -eq 1 ] && echo installed || echo skipped)"
