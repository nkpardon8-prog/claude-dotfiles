# Destructive Actions

## Silence is not approval
An offer that got no answer is an offer that was **not accepted**. When you propose a destructive
action — overwrite, delete, move, truncate, force-push, drop — and no answer comes back, that is a
**no**, and asking twice does not convert it into a yes. Repetition is not consent; it only moves the
count of unanswered questions. Do the non-destructive part, say plainly what you did not do and what
you would need in order to do it, and leave the destructive half undone until someone actually says
yes. The asymmetry is the whole reason: waiting costs a round trip, and being wrong costs work that
no longer exists.

## Never destroy a prior version in a shared or human-owned path
`~/Downloads`, `~/Desktop`, `~/Documents`, a scratch directory another agent is working in — these
hold files with no version history and, often, no other copy. **Never overwrite another agent's
work.** Before writing over anything you did not create in one of these paths: write to a NEW
filename, or copy the original to `<name>.bak` first, and say which you did. The failure this
prevents already happened here — an agent found errors in a relay prompt authored by a different
window, offered twice to fix it, got no reply, and overwrote it in place with no backup; the original
was recoverable only because the acting agent still happened to hold the text in its context. That is
luck, not a procedure.

(SCOPE: paths with no undo. This is NOT a rule against ordinary in-repo edits — a tracked file under
version control has `git` as its backup, and adding `.bak` files beside it is clutter, not safety.
The line is whether a prior version still exists somewhere after you write.)
