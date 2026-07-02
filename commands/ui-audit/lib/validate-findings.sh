#!/bin/bash
# validate-findings.sh — hard gate: findings.json MUST conform to findings.schema.json (ajv-cli).
#
# Usage:  bash validate-findings.sh <findings.json> [schema.json]
#         (schema defaults to findings.schema.json next to this script)
#
# Exits non-zero when findings.json is invalid or missing.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FINDINGS="${1:?usage: bash validate-findings.sh <findings.json> [schema.json]}"
SCHEMA="${2:-$SCRIPT_DIR/findings.schema.json}"

if [ ! -f "$FINDINGS" ]; then echo "validate-findings: no findings file at $FINDINGS" >&2; exit 2; fi
if [ ! -f "$SCHEMA" ]; then echo "validate-findings: no schema at $SCHEMA" >&2; exit 2; fi

npx --yes ajv-cli validate -s "$SCHEMA" -d "$FINDINGS"
