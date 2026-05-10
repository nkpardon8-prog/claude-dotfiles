#!/usr/bin/env bash
# Beacon emit helper — opt-in finer-grained Bar 2 progress.
# Usage: emit-beacon.sh <step> <total> "<label>"
# Optional env: SESSION_ID (override auto-discovery; required for sub-agents
#               whose pwd may not match the project's transcript dir).
STEP=${1:-0}
TOTAL=${2:-0}
LABEL=${3:-working}

SID="${SESSION_ID:-}"
if [ -z "$SID" ]; then
  PROJ_DIR="$HOME/.claude/projects/$(pwd | sed 's|/|-|g; s|^|-|')"
  SID=$(ls -t "$PROJ_DIR"/*.jsonl 2>/dev/null | head -1 | xargs -I {} basename {} .jsonl 2>/dev/null)
fi
[ -z "$SID" ] && exit 0

mkdir -p "$HOME/.claude/progress" 2>/dev/null
F="$HOME/.claude/progress/$SID.current.json"
python3 - "$F" "$STEP" "$TOTAL" "$LABEL" <<'PY' 2>/dev/null
import json, sys
with open(sys.argv[1], "w") as fh:
    json.dump({"step": int(sys.argv[2]), "total": int(sys.argv[3]), "label": sys.argv[4]}, fh)
PY
exit 0
