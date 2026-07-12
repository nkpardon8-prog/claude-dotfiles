#!/bin/bash
# portable-timeout.sh — ONE shared timeout helper (macOS has no `timeout`).
# Source this file, then: pt_run <secs> <cmd...>
#   exit 124  = timed out (child's whole PROCESS GROUP got TERM, then KILL after 2s)
#   128+sig   = child died from a signal (bare $?>>8 would read a SIGNAL-KILLED child as
#               success/0 — proven live 2026-07-12; shell convention is 128+signal)
#   other     = child's own exit code (127 = exec failed / command not found)
# Used by scripts/codex-exec.sh AND embedded in the script.md run-all template — keep in sync.
#
# Why perl: a $SIG{ALRM} handler does NOT survive exec, so the naive single-process
# `perl -e 'alarm N; exec ...'` form exits 142 and dodges infra-fail mapping. The fork/wait
# form keeps the handler in the parent and puts the child in its own process group so the
# TERM/KILL escalation reaps grandchildren too.

pt_run() {  # pt_run <secs> <cmd...>
  if command -v gtimeout >/dev/null 2>&1; then
    gtimeout --kill-after=2 "$1" "${@:2}"
    return $?
  fi
  perl -e '
    my $t = shift;
    my $pid = fork;
    if (!$pid) { setpgrp(0,0); exec @ARGV or exit 127 }
    $SIG{ALRM} = sub { kill "TERM", -$pid; sleep 2; kill "KILL", -$pid; waitpid $pid, 0; exit 124 };
    alarm $t;
    waitpid $pid, 0;
    exit(($? & 127) ? 128 + ($? & 127) : ($? >> 8));
  ' "$@"
}
