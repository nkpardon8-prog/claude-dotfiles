# Verify by Mechanism

## Behavior is proven by mechanism, not by labels
A function name, a status field, an enum value, a comment, or the mere existence of the parts
(a model + a route + a page) is a **hypothesis about behavior — never evidence of it.** Establish
what something actually does by tracing its causal chain to the concrete real-world effect (did the
row reach the queue? did the request reach the provider? did the data come back?). Distrust the label;
follow the wire.

## Aim skepticism at the seams
"Looks done" hides "isn't done" in the **connections between components**, not inside them — each
component can be individually well-built while the integration between them is dead. When auditing
"is X built?" or reviewing a change, spend your scrutiny at the integration boundaries (caller→callee,
enqueue→worker→effect, send→receive→ingest), and trace the **whole round-trip**, not just the entry
point. One dead leg silently kills all the machinery downstream of it.

## Enforce a recurring bug-class with a machine — but only when it earns it
When you FIX a bug, ask whether it is a *class* (a shape that can recur). If it is, ship a fail-closed
check **with** the fix (same change) so the bad shape can't reship — a doc, an ADR, or "we fixed this
once" does NOT stop the next person/agent from re-growing it. **Bounded — this is NOT "guard everything":**
add the machine-guard ONLY when the failure is **silent** AND the shape **can recur**. A loud failure
(it throws, a test goes red) needs no guard; a one-off does not either. That two-part gate is the
anti-over-engineering valve: a fail-closed CI check for a silent chokepoint-bypass, yes; for a typo, no.

(The fix for over-engineering must not itself become over-engineering: this is a thinking habit, not a
mandate to add a check, a gate, or a process to everything.)
