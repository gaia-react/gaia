# /gaia-debt: spec hand-off

The hand-off procedure for a confirmed spec-class member. `debt.md` routes here from its `## Fix-time spec screen`, once per confirmed member, including the members of a named set's spec hand-off. Do not implement a confirmed member; run these steps for it, then return to the spec screen's stop conditions in `debt.md`.

1. **No-orphan claim swap.** Reconcile the label via the registry idempotently (`.gaia/cli/gaia labels sync 2>/dev/null || true; gh label list --json name --jq '.[].name' 2>/dev/null | grep -qx 'debt:spec-pending' || gh label create 'debt:spec-pending' 2>/dev/null || true`), then **add `debt:spec-pending` before removing `in-progress`** (`gh issue edit <n> --add-label debt:spec-pending` then `gh issue edit <n> --remove-label in-progress`), so a mid-swap failure never strands the issue label-less. The registry reconcile leaves a hand-created label alone, for the reason `## Claim the fix unit` in `debt.md` gives at its fallback create.
2. **Print a single copy-pasteable `/gaia-spec` handoff block**, carrying the originating issue number `#<N>` so the eventual implementation PR can `Closes #<N>`, and carrying the `debt:spec-pending` -> `debt:spec-active` swap the pasted session runs on arrival:

   ```
   /gaia-spec Design-first tech debt from issue #<N>: <one-line problem>. First run
   `gh issue edit <N> --remove-label debt:spec-pending --add-label debt:spec-active`
   (best-effort; do not block authoring on it). Author a SPEC for this fix; the
   implementation PR the resulting plan produces should carry `Closes #<N>` so the
   tech-debt issue closes on merge. If the SPEC resolves without an implementation
   PR that closes #<N>, settle the label yourself: when nothing remains to
   implement, run `gh issue edit <N> --remove-label debt:spec-active` and close #<N>;
   when the SPEC holds #<N> open on a recorded trigger, keep the label and comment
   on #<N> naming where the trigger is recorded.
   ```

   The block is the only channel that carries the swap and the label release to the spec session; a session that skips the swap leaves the issue parked at `debt:spec-pending`.

**Two park states, and what each one means.** `debt:spec-pending` means handed off and not yet started; `debt:spec-active` means the pipeline is running, the SPEC being authored, planned, or executed, or that the SPEC answered by holding the issue open on a recorded trigger. Both park the issue identically for every consumer (out of `openCount`, out of the backlog pass's `candidates` and `clusters`), so nothing downstream branches on which one is set. What the split buys is that an un-started handoff stays **distinguishable** from one somebody is working, which is the whole point: under a single label a second person sees a marker that says "waiting for someone" and authors a second SPEC for the same debt.

**`debt:spec-active` has no automatic release; outside a closing merge it comes off by hand.** No hook or reconcile releases it. Every consumer filters on open issues, so a label left on a closed issue is inert. The cases:

- **The implementation PR merges carrying `Closes #<N>`.** The issue closes and the label goes inert with it. No action.
- **The SPEC or its plan merges and nothing remains to implement.** No closing keyword fires, so nothing closes the issue. Strip the label (`gh issue edit <N> --remove-label debt:spec-active`) and close the issue by hand.
- **The SPEC answers by holding the issue open on a recorded trigger.** Keep the label: it is the hold. Unparked, a `footprint:spec` issue re-routes straight back into a second `/gaia-spec` handoff on the next drain. Comment on the issue naming where the trigger is recorded, so a reader of the label can find what would release it.
- **The SPEC is abandoned.** Strip the label and leave the issue open, per the next paragraph.

The handoff block above carries the second and third cases to the spec session, because it is the only channel that reaches it.

**Abandoning the SPEC strips the label and leaves the issue open.** When a human or agent decides to stop pursuing the SPEC, remove whichever park label is set (`gh issue edit <n> --remove-label debt:spec-pending` or `--remove-label debt:spec-active`), so the issue returns to the candidate pool and re-offers on the next drain. **Do not close it.** Abandoning a spec means the fix was not attempted, not that the debt is gone, and closing it is worse than losing a backlog row: `.claude/skills/file-tech-debt/SKILL.md` step 2 reads a closed match carrying `wontfix`, or closed as not-planned, as *declined* and suppresses re-filing permanently, so a dropped spec would block an audit from ever re-filing that finding. Closing as `wontfix` stays a separate, deliberate "this should not be fixed" decision. This is the controlled-stop case only; the silent case, where the block is never pasted at all, is nobody's decision and nothing reaps it, which is exactly what keeping `pending` distinct from `active` leaves queryable.

**Hard constraints.** `/gaia-debt` never invokes `/gaia-spec`, never dispatches a spec author, and never reads the SPEC template or `plan.md`. Authoring or saving the SPEC does not close the issue, and this handoff issues **no** close call. A merge carrying `Closes #<N>` closes the issue on its own; any other close is by hand, per the hand-release cases for `debt:spec-active` above.
