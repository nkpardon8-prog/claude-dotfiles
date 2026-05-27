#!/usr/bin/env bash
# gemini-invoke.sh — headless, read-only wrapper around the Google Gemini CLI.
#
# The single source of truth for "ask a Gemini model something and get text back."
# Mirrors the role of god-review/lib/codex-invoke.sh: a thin bridge any skill can
# call in one line to get a review or draft from a Gemini model.
#
# Usage:
#   [context on stdin] | gemini-invoke.sh <outfile> <prompt> <workdir>
#
#     outfile  — file to write the model's text reply to.
#     prompt   — the instruction (review/draft framing + the task).
#     workdir  — directory the CLI runs in (scopes optional read-only repo access).
#
# Context: pipe it on stdin. Per `gemini --help`, the -p prompt is "appended to
# input on stdin (if any)" — so stdin carries the context, -p carries the instruction.
# If nothing is piped (a TTY), no context is sent.
#
# Posture: ALWAYS read-only. `--approval-mode plan` is the CLI's read-only mode —
# Gemini can read and reason but cannot edit files or run shell commands. Claude
# remains the only writer. This is the structural guarantee, not a default we hope for.
#
# Env knobs (all optional):
#   GEMINI_BIN          binary name/path                      (default: gemini)
#   GEMINI_MODEL        model id; if unset, the CLI picks the account default
#   GEMINI_CONTEXT_MAX  max bytes of piped stdin context      (default: 100000)
#   GEMINI_TIMEOUT      per-call timeout in seconds; 0 = off  (default: 120)
#
# Auth is handled by the CLI itself, never hardcoded here:
#   - `gemini` interactive OAuth login (free Google AI Pro quota), OR
#   - an exported GEMINI_API_KEY.
# See ../README.md. NOTE: the free OAuth/Code-Assist path for AI Pro is deprecated
# on the Gemini CLI as of 2026-06-18 — after that, export GEMINI_API_KEY.
#
# ALWAYS exits 0 — it must never block a caller. Failures are written into <outfile>
# as [unavailable] / [empty] / [timeout] markers for the caller to surface.
#
# Portability: written for bash 3.2 (stock macOS). No `timeout`/`gtimeout` dependency
# (uses a perl alarm fallback). No empty-array expansion under `set -u`.

set -uo pipefail

OUTFILE="${1:?outfile argument required}"
PROMPT="${2:?prompt argument required}"
WORKDIR="${3:?workdir argument required}"

GEMINI_BIN="${GEMINI_BIN:-gemini}"
CAP="${GEMINI_CONTEXT_MAX:-100000}"
TO="${GEMINI_TIMEOUT:-120}"

# --- Guard: binary present? Never block a caller. ---
if ! command -v "$GEMINI_BIN" >/dev/null 2>&1; then
  echo "[unavailable] gemini binary not found on PATH (GEMINI_BIN=$GEMINI_BIN). Install: npm i -g @google/gemini-cli" > "$OUTFILE"
  exit 0
fi

# --- Config isolation: relocate the CLI's config home to a private dir so the wrapper
#     never auto-loads a global/foreign GEMINI.md (which injects unrelated "memory"
#     preferences into every review/draft). We symlink ONLY the auth material from the
#     real ~/.gemini and deliberately omit GEMINI.md. Auth (OAuth or GEMINI_API_KEY) is
#     fully preserved; the real ~/.gemini is left untouched for other Gemini/Antigravity
#     use. GEMINI_CLI_HOME is the PARENT of the .gemini config dir. Idempotent, self-healing
#     (symlinks re-pointed each call so re-auth / token refresh stays in sync). ---
ISO_HOME="${GEMINI_SUBAGENT_HOME:-${XDG_CACHE_HOME:-$HOME/.cache}/claude-gemini-subagent}"
REAL_GEMINI="$HOME/.gemini"
if mkdir -p "$ISO_HOME/.gemini" 2>/dev/null; then
  for f in oauth_creds.json google_accounts.json settings.json; do
    [ -e "$REAL_GEMINI/$f" ] && ln -sf "$REAL_GEMINI/$f" "$ISO_HOME/.gemini/$f"
  done
  rm -f "$ISO_HOME/.gemini/GEMINI.md" 2>/dev/null || true   # guarantee no context-file leak
  export GEMINI_CLI_HOME="$ISO_HOME"
fi

# --- Build the gemini argv. Always non-empty, so "${gemini_args[@]}" is set -u safe. ---
gemini_args=(--approval-mode plan --skip-trust -o text)
if [ -n "${GEMINI_MODEL:-}" ]; then
  gemini_args=("${gemini_args[@]}" -m "$GEMINI_MODEL")
fi
gemini_args=("${gemini_args[@]}" -p "$PROMPT")

# --- Timeout: prefer a perl SIGALRM wrapper (perl ships with macOS; the alarm
#     survives exec and kills a hung CLI). Disabled when GEMINI_TIMEOUT=0 or no perl. ---
have_timeout=0
if [ "$TO" != "0" ] && command -v perl >/dev/null 2>&1; then
  have_timeout=1
fi

# invoke: runs gemini, reading whatever stdin it is given, optionally under timeout.
invoke() {
  if [ "$have_timeout" = "1" ]; then
    perl -e 'alarm shift; exec @ARGV' "$TO" "$GEMINI_BIN" "${gemini_args[@]}"
  else
    "$GEMINI_BIN" "${gemini_args[@]}"
  fi
}

TMP="$(mktemp)"; ERR="$(mktemp)"
trap 'rm -f "$TMP" "$ERR"' EXIT

(
  cd "$WORKDIR" 2>/dev/null || true
  if [ -t 0 ]; then
    invoke </dev/null            # no context piped → don't read the terminal
  else
    head -c "$CAP" | invoke      # context on stdin, capped for ALL callers
  fi
) >"$TMP" 2>"$ERR"
rc=$?

# perl's SIGALRM termination surfaces as 142 (128 + SIGALRM 14).
if [ "$rc" = "142" ]; then
  { echo "[timeout] gemini exceeded ${TO}s. Raise GEMINI_TIMEOUT, or check network/auth.";
    echo "--- stderr tail ---"; tail -n 8 "$ERR" 2>/dev/null; } > "$OUTFILE"
elif [ -s "$TMP" ]; then
  mv "$TMP" "$OUTFILE"
else
  { echo "[empty] gemini returned no output. Check auth ('gemini' login with your Google AI Pro account, or export GEMINI_API_KEY), quota, or GEMINI_MODEL.";
    echo "--- stderr tail ---"; tail -n 8 "$ERR" 2>/dev/null; } > "$OUTFILE"
fi

exit 0
