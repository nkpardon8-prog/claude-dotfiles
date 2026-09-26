#!/usr/bin/env bash
# Harness for the live display-name path of /line:
#   line-agent-communicator.py set / sync-display-name   (writer: record + one-shot request)
#   scripts/hooks/line-apply-rename.sh                    (Stop hook: types /rename into the tab)
#   scripts/hooks/line-reassert-identity.sh               (SessionStart: restores the name on reopen)
#
# Everything runs against a FAKE HOME. No keystrokes reach any real tab:
#   - the fire path runs under a fake `claude` process that `script` gives its own pty, and
#     /usr/bin/osascript is replaced by a stub via LINE_RENAME_OSASCRIPT, which the hook honors ONLY
#     when HOME is not the account's real home;
#   - the pre-claim abort path runs the hook DETACHED (re-parented to launchd, stdin held on a fifo
#     until the launcher is gone), so its own-ancestry walk cannot reach the real claude running
#     this harness.
#
# Usage: bash scripts/hooks/test-line-apply-rename.sh
#   LR_HOOK_UNDER_TEST=<path>  run the hook cases against a mutated copy (negative controls); the
#                              copy must sit next to a lib/ directory like the real one.
#   LR_LAC_UNDER_TEST=<path>   run everything against a mutated communicator (negative controls).
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="${LR_HOOK_UNDER_TEST:-$HERE/line-apply-rename.sh}"
REASSERT="$HERE/line-reassert-identity.sh"
LAC_SRC="${LR_LAC_UNDER_TEST:-$(cd "$HERE/.." && pwd)/line-agent-communicator.py}"
TEMPLATE="$(cd "$HERE/../.." && pwd)/settings.json.template"

for need in jq python3 script; do
  command -v "$need" >/dev/null 2>&1 || { echo "INFRA: $need missing" >&2; exit 3; }
done
[ -f "$HOOK" ] && [ -f "$LAC_SRC" ] || { echo "INFRA: hook or communicator not found" >&2; exit 3; }

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
check() { if [ "$2" = 1 ]; then ok "$1"; else bad "$1"; fi; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/lr-test-XXXXXX")"
[ -n "$ROOT" ] && [ -d "$ROOT" ] || { echo "INFRA: mktemp -d failed; refusing to run unsandboxed" >&2; exit 3; }
trap 'rm -rf "$ROOT"' EXIT
FAKE_HOME="$ROOT/home"
PROG="$FAKE_HOME/.claude/progress"
LOG="$FAKE_HOME/.claude/logs/line-rename.log"
RLOG="$FAKE_HOME/.claude/logs/line-reassert.log"
mkdir -p "$PROG" "$FAKE_HOME/.claude/logs" "$FAKE_HOME/.claude/session-status" \
         "$FAKE_HOME/.claude/sessions" "$FAKE_HOME/.claude/projects/-fake-proj" \
         "$FAKE_HOME/.claude-dotfiles/scripts" "$ROOT/bin"
ln -s "$LAC_SRC" "$FAKE_HOME/.claude-dotfiles/scripts/line-agent-communicator.py"

SID="lrtest-$$"
REQ="$PROG/line-rename-$SID.json"
TRANSCRIPT="$FAKE_HOME/.claude/projects/-fake-proj/$SID.jsonl"

# Stub osascript: records its argv and the AppleScript it was fed, prints $LR_STUB_RESULT.
cat > "$ROOT/bin/osa-stub" <<'EOF'
#!/bin/bash
cat > "$LR_STUB_DIR/script.applescript"
printf '%s\n' "$2" > "$LR_STUB_DIR/arg-tty"
printf '%s\n' "$3" > "$LR_STUB_DIR/arg-name"
printf '%s\n' "${LR_STUB_RESULT:-fired}"
EOF
chmod +x "$ROOT/bin/osa-stub"

# Fake `claude`: argv ends in /claude (matches the library ERE), and under `script` it is the
# session leader + foreground group on a fresh pty - the exact shape of a real claude TUI.
cat > "$ROOT/bin/claude" <<'EOF'
#!/bin/bash
"$LR_HOOK" < "$LR_JSON" > /dev/null 2>&1
EOF
chmod +x "$ROOT/bin/claude"

printf '{"session_id":"%s","hook_event_name":"Stop"}' "$SID" > "$ROOT/stop.json"

now() { date +%s; }
write_req() {  # <name> <at> [tries]
  ( umask 077; jq -cn --arg n "$1" --argjson a "$2" --argjson t "${3:-0}" \
      'if $t > 0 then {name:$n,at:$a,tries:$t} else {name:$n,at:$a} end' > "$REQ" )
}
log_has() { grep -q -- "$1" "$LOG" 2>/dev/null; }
reset() {
  rm -f "$REQ" "$REQ".claimed.* "$LOG" "$RLOG" "$PROG"/auto-compact-* "$ROOT"/stub/* 2>/dev/null
  mkdir -p "$ROOT/stub"
}

# Hook invocations -----------------------------------------------------------------------------
# Plain: direct child of this harness, for cases that must exit BEFORE the identity checks. Its
# ancestry DOES reach the real claude running this harness, so a regression that slipped past the
# early exits would pass verification against the REAL tab - which is why it ALSO carries the stub
# osascript (a 2026-09-26 negative-control mutant without it typed /rename into the live window).
# Every runner here uses the stub; never add one that does not.
run_hook_plain() {
  env HOME="$FAKE_HOME" TERM_PROGRAM="${LR_TERM:-Apple_Terminal}" TMUX= STY= \
      LR_STUB_DIR="$ROOT/stub" LINE_RENAME_OSASCRIPT="$ROOT/bin/osa-stub" \
      "$HOOK" < "$ROOT/stop.json" > /dev/null 2>&1
}
# Under a fake claude on its own pty, with the stub osascript.
run_hook_fake_claude() {
  env HOME="$FAKE_HOME" TERM_PROGRAM=Apple_Terminal TMUX= STY= \
      LR_HOOK="$HOOK" LR_JSON="$ROOT/stop.json" LR_STUB_DIR="$ROOT/stub" \
      LR_STUB_RESULT="${LR_STUB_RESULT:-fired}" LINE_RENAME_OSASCRIPT="$ROOT/bin/osa-stub" \
      script -q /dev/null "$ROOT/bin/claude" < /dev/null > /dev/null 2>&1
}
# Detached: no claude anywhere in its ancestry -> deterministic pre-claim abort.
run_hook_detached() {
  local fifo="$ROOT/fifo.$RANDOM" before i
  before=$( { wc -l < "$LOG"; } 2>/dev/null | tr -d ' '); before=${before:-0}
  mkfifo "$fifo"
  ( env HOME="$FAKE_HOME" TERM_PROGRAM=Apple_Terminal TMUX= STY= \
        LR_STUB_DIR="$ROOT/stub" LINE_RENAME_OSASCRIPT="$ROOT/bin/osa-stub" \
        "$HOOK" < "$fifo" > /dev/null 2>&1 & )
  cat "$ROOT/stop.json" > "$fifo"
  for i in $(seq 1 100); do
    [ "$( { wc -l < "$LOG"; } 2>/dev/null | tr -d ' ')" -gt "$before" ] 2>/dev/null && break
    sleep 0.1
  done
  rm -f "$fifo"
}

echo "== Stop hook: fast paths and request hygiene =="
reset
run_hook_plain
check "no request -> no-op (no log written)" "$([ ! -e "$LOG" ] && echo 1 || echo 0)"

reset
write_req "summit-admin-hub" "$(( $(now) - 7200 ))"
run_hook_plain
check "stale request (2h) deleted" "$([ ! -e "$REQ" ] && echo 1 || echo 0)"
check "stale request logged as stale" "$(log_has '^.* stale sid=' && echo 1 || echo 0)"
check "stale request: nothing typed" "$([ ! -e "$ROOT/stub/arg-name" ] && echo 1 || echo 0)"

reset
write_req "summit-admin-hub" "$(now)"
: > "$PROG/auto-compact-$SID.json"
run_hook_fake_claude
check "auto-compact armed -> request kept" "$([ -f "$REQ" ] && echo 1 || echo 0)"
check "auto-compact armed -> logged defer" "$(log_has 'defer sid=' && echo 1 || echo 0)"
check "auto-compact armed -> nothing typed" "$([ ! -e "$ROOT/stub/arg-name" ] && echo 1 || echo 0)"
check "auto-compact armed -> retry budget untouched" "$([ "$(jq -r '.tries // 0' "$REQ")" = 0 ] && echo 1 || echo 0)"

reset
write_req "summit-admin-hub" "$(now)"
: > "$PROG/auto-compact-$SID.json.claim.4242"
run_hook_fake_claude
check "auto-compact mid-claim -> deferred, request kept" "$([ -f "$REQ" ] && log_has 'defer sid=' && echo 1 || echo 0)"

reset
write_req 'bad; do shell script "id"' "$(now)"
run_hook_plain
check "unsafe name in request -> dropped as malformed" "$([ ! -e "$REQ" ] && log_has 'drop sid=.* reason=malformed' && echo 1 || echo 0)"

reset
write_req '-help' "$(now)"
run_hook_plain
check "flag-shaped name -> dropped as malformed" "$([ ! -e "$REQ" ] && log_has 'reason=malformed' && echo 1 || echo 0)"

reset
write_req 'Summit admin hub' "$(now)"
run_hook_plain
check "free-text (not a handle) name -> dropped as malformed" "$([ ! -e "$REQ" ] && log_has 'reason=malformed' && echo 1 || echo 0)"

reset
printf 'KEEP-ME\n' > "$ROOT/target-file"
ln -s "$ROOT/target-file" "$REQ"
run_hook_plain
check "symlinked request -> link removed, target intact" \
  "$([ ! -L "$REQ" ] && [ "$(cat "$ROOT/target-file")" = KEEP-ME ] && log_has 'reason=symlink' && echo 1 || echo 0)"

reset
write_req "summit-admin-hub" "$(now)"
LR_TERM=iTerm.app run_hook_plain
check "iTerm -> unsupported-terminal logged, request deleted" \
  "$([ ! -e "$REQ" ] && log_has 'unsupported-terminal sid=.* term=iTerm.app' && echo 1 || echo 0)"

echo "== Stop hook: fire path (fake claude on its own pty, stub osascript) =="
reset
write_req "dso-ui-ref" "$(now)"
LR_STUB_RESULT=fired run_hook_fake_claude
check "success -> request removed" "$([ ! -e "$REQ" ] && echo 1 || echo 0)"
check "success -> no claim file left behind" "$(ls "$REQ".claimed.* >/dev/null 2>&1 && echo 0 || echo 1)"
check "success -> logged fired" "$(log_has 'fired sid=.* name=dso-ui-ref' && echo 1 || echo 0)"
check "osascript got the name as argv (not in the script source)" \
  "$([ "$(cat "$ROOT/stub/arg-name" 2>/dev/null)" = "dso-ui-ref" ] && ! grep -q 'dso-ui-ref' "$ROOT/stub/script.applescript" && echo 1 || echo 0)"
check "osascript got a /dev/ttysN target" "$(grep -Eq '^/dev/ttys[0-9]+$' "$ROOT/stub/arg-tty" 2>/dev/null && echo 1 || echo 0)"
check "AppleScript types /rename into the tty-matched tab" \
  "$(grep -q 'do script ("/rename " & theName) in foundTab' "$ROOT/stub/script.applescript" 2>/dev/null && echo 1 || echo 0)"

reset
write_req "dso-ui-ref" "$(now)"
LR_STUB_RESULT="no-matching-tab/win=1/skip=0/tabs=3" run_hook_fake_claude
check "osascript failure -> request kept for one retry" \
  "$([ -f "$REQ" ] && [ "$(jq -r '.tries' "$REQ")" = 1 ] && echo 1 || echo 0)"
check "osascript failure -> abort logged with reason" "$(log_has 'abort sid=.* reason=osascript-failed' && echo 1 || echo 0)"
LR_STUB_RESULT="no-matching-tab/win=1/skip=0/tabs=3" run_hook_fake_claude
check "second failure -> give-up, request dropped" "$([ ! -e "$REQ" ] && log_has 'give-up sid=' && echo 1 || echo 0)"

echo "== Stop hook: pre-claim abort (no claude in ancestry) =="
reset
write_req "summit-admin-hub" "$(now)"
run_hook_detached
check "own-claude-unresolved -> abort logged" "$(log_has 'abort sid=.* reason=own-claude-unresolved' && echo 1 || echo 0)"
check "pre-claim abort -> nothing typed" "$([ ! -e "$ROOT/stub/arg-name" ] && echo 1 || echo 0)"
check "pre-claim abort -> request kept for one retry (tries=1)" \
  "$([ -f "$REQ" ] && [ "$(jq -r '.tries' "$REQ")" = 1 ] && echo 1 || echo 0)"
run_hook_detached
check "pre-claim abort again -> give-up, request dropped" "$([ ! -e "$REQ" ] && log_has 'give-up sid=' && echo 1 || echo 0)"

[ -n "${LR_HOOK_UNDER_TEST:-}" ] && { echo; echo "RESULT: $PASS passed, $FAIL failed (hook cases only, mutated hook)"; [ "$FAIL" -eq 0 ]; exit $?; }

echo "== Writer: the display name is the peer handle =="
SHAPE=$(python3 - "$LAC_SRC" <<'EOF'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("lac", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
for raw in ["Internal › dentall › summit admin hub", "dso UI / ref", "it's; rm -rf ~ `id` $(x)",
            "café v1.2-beta", "x" * 100, "--help", "Mac Mini Setup"]:
    h = m.slugify(raw)
    print(("ok" if m.TYPEABLE_NAME.match(h) else "BAD"), repr(raw)[:36], "->", repr(h))
for bad in ["Summit admin hub", "-x", "a;b", "", "x" * 61, "café"]:
    print(("ok" if not m.write_rename_request("s1", bad) else "BAD"), "request refused for", repr(bad)[:20])
EOF
)
while IFS= read -r line; do
  case "$line" in ok*) ok "shape ${line#ok }" ;; *) bad "shape ${line#BAD }" ;; esac
done <<<"$SHAPE"

lac() { env HOME="$FAKE_HOME" CLAUDE_SESSION_ID="$SID" TERM_PROGRAM="${LR_TERM:-Apple_Terminal}" TMUX= STY= \
          python3 "$LAC_SRC" "$@" 2>&1; }
last_title() { jq -r 'select(.type=="custom-title") | .customTitle' "$TRANSCRIPT" 2>/dev/null | tail -n 1; }
titles() { grep -c '"custom-title"' "$TRANSCRIPT" 2>/dev/null | tr -d ' '; }
REG="$FAKE_HOME/.claude/sessions/1.json"
reg() {  # <name> <nameSource>
  printf '{"pid":1,"sessionId":"%s","cwd":"/x","name":"%s","nameSource":"%s"}\n' "$SID" "$1" "$2" > "$REG"
}
reg_name() { jq -r '.name + "|" + .nameSource' "$REG" 2>/dev/null; }

echo "== Writer: /line set -> record + request carry the handle =="
reset; rm -f "$TRANSCRIPT" "$REG"
OUT=$(lac set "dso UI / ref")
check "no transcript -> says it could not be saved" "$(printf '%s' "$OUT" | grep -q 'could not be saved' && echo 1 || echo 0)"
check "no transcript -> no request file" "$([ ! -e "$REQ" ] && echo 1 || echo 0)"

reset; printf '{"type":"user"}\n' > "$TRANSCRIPT"
OUT=$(lac set "dso UI / ref")
check "no registry entry -> falls back to slugify(sentence) for the request" "$([ "$(jq -r '.name' "$REQ" 2>/dev/null)" = "dso-ui-ref" ] && echo 1 || echo 0)"
check "no registry entry -> transcript record is the same handle" "$([ "$(last_title)" = "dso-ui-ref" ] && echo 1 || echo 0)"
check "caption keeps the free-text sentence" "$([ "$(cat "$FAKE_HOME/.claude/session-status/$SID.txt")" = "dso UI / ref" ] && echo 1 || echo 0)"

reset; printf '{"type":"user"}\n' > "$TRANSCRIPT"; reg "dentall-42" derived
OUT=$(lac set "Mac Mini Setup")
check "registry entry -> address set to the handle" "$([ "$(reg_name)" = "mac-mini-setup|explicit" ] && echo 1 || echo 0)"
check "registry entry -> request name == address" "$([ "$(jq -r '.name' "$REQ" 2>/dev/null)" = "mac-mini-setup" ] && echo 1 || echo 0)"
check "registry entry -> transcript record == address" "$([ "$(last_title)" = "mac-mini-setup" ] && echo 1 || echo 0)"
check "set -> request is mode 600" "$([ "$(stat -f '%Lp' "$REQ" 2>/dev/null)" = 600 ] && echo 1 || echo 0)"
check "set -> request carries an epoch 'at'" "$([ "$(jq -r '.at|type' "$REQ" 2>/dev/null)" = number ] && echo 1 || echo 0)"
check "set -> promises the live update" \
  "$(printf '%s' "$OUT" | grep -q 'Your other Macs will show this name as soon as this reply finishes.' && echo 1 || echo 0)"
check "set -> no 'also type /rename' tip in Terminal.app" "$(printf '%s' "$OUT" | grep -q 'also type' && echo 0 || echo 1)"
N1=$(titles); rm -f "$REQ"; OUT=$(lac set "Mac Mini Setup")
check "same name again -> no duplicate record, request re-queued" "$([ "$(titles)" = "$N1" ] && [ -f "$REQ" ] && echo 1 || echo 0)"

# A LIVE sibling window already holding the handle -> /line picks the numeric suffix, and the display
# name follows it. Symlink, not copy: macOS SIGKILLs a copied system binary on exec.
mkdir -p "$ROOT/live"; ln -s /bin/sleep "$ROOT/live/claude"
"$ROOT/live/claude" 60 & SIB_PID=$!
sleep 0.3
printf '{"pid":%s,"sessionId":"sibling-%s","cwd":"/y","name":"mac-mini-setup","nameSource":"explicit"}\n' \
  "$SIB_PID" "$$" > "$FAKE_HOME/.claude/sessions/$SIB_PID.json"
reset; reg "dentall-42" derived
lac set "Mac Mini Setup" >/dev/null
check "handle collision -> address gets the suffix" "$([ "$(reg_name)" = "mac-mini-setup-2|explicit" ] && echo 1 || echo 0)"
check "handle collision -> display name carries the SAME suffix" \
  "$([ "$(jq -r '.name' "$REQ" 2>/dev/null)" = "mac-mini-setup-2" ] && [ "$(last_title)" = "mac-mini-setup-2" ] && echo 1 || echo 0)"
{ kill "$SIB_PID"; wait "$SIB_PID"; } 2>/dev/null
rm -f "$FAKE_HOME/.claude/sessions/$SIB_PID.json"

reset; reg "dentall-42" derived
OUT=$(LR_TERM=iTerm.app lac set "billing desk")
check "iTerm -> no request, manual /rename tip names the handle" \
  "$([ ! -e "$REQ" ] && printf '%s' "$OUT" | grep -q 'also type: /rename billing-desk' && echo 1 || echo 0)"

reset
OUT=$(lac set "$(printf '\xf0\x9f\x98\x80')")
check "sentence with no letters/digits -> no request, says unchanged" \
  "$([ ! -e "$REQ" ] && printf '%s' "$OUT" | grep -q 'Display name: UNCHANGED' && echo 1 || echo 0)"

echo "== SessionStart re-assert: display name (= handle) after a reopen =="
reassert() {  # <source>
  printf '{"session_id":"%s","source":"%s","hook_event_name":"SessionStart"}' "$SID" "$1" \
    | env HOME="$FAKE_HOME" TERM_PROGRAM=Apple_Terminal TMUX= STY= bash "$REASSERT" > /dev/null 2>&1
}
set_title() { printf '{"type":"custom-title","customTitle":"%s","sessionId":"%s"}\n' "$1" "$SID" > "$TRANSCRIPT"; }

reset; printf 'summit admin hub\n' > "$FAKE_HOME/.claude/session-status/$SID.txt"
reg "summit-admin-hub" explicit; set_title "summit-admin-hub"
N0=$(titles); reassert resume
check "resume, title == handle -> no request" "$([ ! -e "$REQ" ] && echo 1 || echo 0)"
check "resume, title == handle -> transcript unchanged" "$([ "$(titles)" = "$N0" ] && echo 1 || echo 0)"
check "resume, title == handle -> no display-name log line" "$(grep -q 'display-name' "$RLOG" 2>/dev/null && echo 0 || echo 1)"

reset; set_title "summit admin hub"
reassert resume
check "resume, title is the old free-text caption -> record == handle" "$([ "$(last_title)" = "summit-admin-hub" ] && echo 1 || echo 0)"
check "resume, mismatch -> /rename request carries the handle" "$([ "$(jq -r '.name' "$REQ" 2>/dev/null)" = "summit-admin-hub" ] && echo 1 || echo 0)"
check "resume, mismatch -> logged result=written" "$(grep -q 'display-name sid=.* source=resume result=written' "$RLOG" 2>/dev/null && echo 1 || echo 0)"

reset; reg "summit-admin-hub-2" explicit; set_title "summit-admin-hub"
reassert resume
check "resume compares against the REGISTRY handle (suffix kept), not a re-slug" \
  "$([ "$(last_title)" = "summit-admin-hub-2" ] && [ "$(jq -r '.name' "$REQ" 2>/dev/null)" = "summit-admin-hub-2" ] && echo 1 || echo 0)"

reset; reg "summit-admin-hub" explicit; printf '{"type":"user"}\n' > "$TRANSCRIPT"
reassert startup
check "startup, no title record -> record + request" \
  "$([ "$(last_title)" = "summit-admin-hub" ] && [ -f "$REQ" ] && echo 1 || echo 0)"

reset; set_title "old-name"
reassert compact
check "compact (same live process) -> display name left alone" \
  "$([ ! -e "$REQ" ] && [ "$(last_title)" = "old-name" ] && echo 1 || echo 0)"

reset; rm -f "$FAKE_HOME/.claude/session-status/$SID.txt"
reassert resume
check "no caption -> no-op" "$([ ! -e "$REQ" ] && [ "$(last_title)" = "old-name" ] && echo 1 || echo 0)"

reset; printf 'summit admin hub\n' > "$FAKE_HOME/.claude/session-status/$SID.txt"
reg "dentall-42" derived; set_title "old-name"
reassert resume
check "derived address + stale title -> address restored to the handle" "$([ "$(reg_name)" = "summit-admin-hub|explicit" ] && echo 1 || echo 0)"
check "derived address + stale title -> exactly one new record, one request (handle)" \
  "$([ "$(titles)" = 2 ] && [ "$(last_title)" = "summit-admin-hub" ] && [ "$(jq -r '.name' "$REQ" 2>/dev/null)" = "summit-admin-hub" ] && echo 1 || echo 0)"
check "derived address -> existing reassert log line still written" "$(grep -q 'reassert sid=.* nameSource=derived' "$RLOG" 2>/dev/null && echo 1 || echo 0)"

# After a live /rename fired, the registry says nameSource "user" with the handle as its name and the
# transcript already ends on it: a reopen must re-mark the address but NOT type /rename again.
reset; reg "summit-admin-hub" user; set_title "summit-admin-hub"
reassert resume
check "post-rename reopen (user source, title == handle) -> no request, no new record" \
  "$([ ! -e "$REQ" ] && [ "$(titles)" = 1 ] && [ "$(reg_name)" = "summit-admin-hub|explicit" ] && echo 1 || echo 0)"

echo "== Registration =="
check "settings.json.template is valid JSON" "$(python3 -m json.tool "$TEMPLATE" >/dev/null 2>&1 && echo 1 || echo 0)"
check "template registers line-apply-rename.sh as a Stop hook" \
  "$(jq -e '[.hooks.Stop[].hooks[].command] | any(test("line-apply-rename\\.sh$"))' "$TEMPLATE" >/dev/null 2>&1 && echo 1 || echo 0)"

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
