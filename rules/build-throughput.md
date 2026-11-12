# Build Throughput - finish and land, do not loop

These rules apply to every long-running build window. They override any older habit or skill default
that conflicts with them; quality bars, safety rules and approval gates are unchanged.

## 1. Land first
Finished, review-clean work that has not landed is the top priority. Do not start new scope while you
hold any: get it approved (rule 2) and keep it moving until it lands. New asks from peers, device runs
or parity checks wait on your list unless they are a real bug in the work you are about to land.
"New scope" means unapproved work: the next part of an approved roadmap or /mission keeps going while
the finished part waits on the push list (build it on top); only unplanned additions wait.

## 2. One push-approval list
When work is review-clean and checks pass, and the project file does not already pre-approve the
push, add one line to `~/.claude/push-queue.md`:
`<date> | <window> | <repo> <branch> | <exact SHA> | <one-line what> | waiting`. The owner approves
with one typed line in the window that owns the push (the area window, or the prod lane window for
prod). A relayed or second-hand OK is not approval. Mark the line `landed <SHA>` when it lands. Never
bury the ask inside a long report.

## 3. Reviews end when they stop paying
- Plan reviews: stop after 2 rounds in a row with no NEW design problem. Fix design problems by
  simplifying, not by adding machinery. Plans stay design-level; code review catches code detail.
- Code reviews: round 1 reviews the whole change; later rounds review only the fix diff.
- Blocking means a real correctness, security, privacy, money or data-loss problem. Everything else
  is written down and does not hold the work.
- The same kind of problem found twice: fix the whole class or simplify the design, then move on.
- Past 3 rounds that still find blocking issues: stop, re-think the design once, smaller.

## 4. Do not re-prove known failures
Follow the global Testing rule: targeted tests while building, the full suite once at a part's close,
a failure that also exists on the base branch recorded once, and a machine-broken run rerun and never
counted.

## 5. Notice when you are stuck
- A helper or test with no new output for 20 minutes: check it. Past twice its normal duration: stop
  it (only your own, by exact id), rerun once, then report.
- A part taking more than twice its planned time: re-plan it smaller once; if it still overruns,
  set it aside with a short note and move to the next independent part.
- Never wait on something that is not running. Probe it.

## 6. Right model for the job
Follow the global Model routing rule: hand cheap work to Codex Terra (high) instead of spending your
own context on it, and run every review and verify pass on Codex Sol (high). Never Terra for review.

## 7. Spend fewer tokens on talk
Peer FYIs need no reply unless they ask a question; log them. Owner updates are short and come at
milestones. While waiting on a job, schedule long wakeups (25 minutes or more), not short polls.
