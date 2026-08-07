# Mutation-proof record: sweep #8's combined-diff patch-id guard

This file is the re-runnable, checked-in proof that each guard arm sweep #8 (the
orphaned-worktree reap in `.claude/hooks/local-janitor.sh`) added is load-bearing. A test suite
that passes against a guard is not evidence the guard can fail; this record is evidence, because
every mutation below was actually applied to the shipped source, actually observed reddening the
test it claims, and actually reverted with a checksum match in both directions.

## How to re-run an entry

Pick a mutation section below. Apply its **edit** to `.claude/hooks/local-janitor.sh` exactly as
stated, one mutation at a time, never two applied together. Run:

```bash
bash .gaia/scripts/bats5.sh .gaia/tests/hooks/local-janitor-worktree-reap.bats
```

Confirm the named test(s) go red and the rest of the suite stays green, then revert the edit and
confirm `git diff -- .claude/hooks/local-janitor.sh` is empty and `shasum -a 256
.claude/hooks/local-janitor.sh` matches the "before" value recorded in that section. Only then move
to the next entry. Never leave a mutation applied: this reap is the janitor's one destructive path,
and an unreverted mutation on it is a data-loss bug in the working tree, not a documentation gap.

Every checksum below is the same value, because the file returns to its one shipped state after
every entry:

```
a0b1d759ccb546ecf72483c2d2c15bfb88b0e8424c18bc226fb9404c4bbfaab6
```

## Mutation 1: the clean-tree read's own exit status

Defends against taking a failed `git status` for a clean tree. `git status --porcelain` exits
non-zero on a worktree it cannot read while printing nothing on stdout; reading that silence as
"clean" would permit the reap of a worktree nobody can currently see into.

Guard line, verbatim:

```
    [ "$wt_status_rc" -eq 0 ] || continue
```

Edit: delete that line, leaving only `[ -z "$wt_status_out" ] || continue` after the read.

Test that goes red: `keeps a candidate that would otherwise be reaped when the status read fails`
(UAT-008).

What stays green, and why: all 36 other tests, including the sibling reap candidate UAT-008 builds
alongside the failing one (`debt/407-control`), which still reaps normally in the same run. The
mutation is attributable to this arm because UAT-008's shim fails only the status read scoped to
one worktree's path; nothing else in the run is touched.

Checksum before: `a0b1d759ccb546ecf72483c2d2c15bfb88b0e8424c18bc226fb9404c4bbfaab6`.
Checksum after revert: `a0b1d759ccb546ecf72483c2d2c15bfb88b0e8424c18bc226fb9404c4bbfaab6`. Match.

## Mutation 3: commits-ahead disposition on an empty diff

Defends against reaping a branch whose commits cancel out to an empty combined diff. The branch's
tree is not the merge base's tree in that case; the cancelled commits' content is real and becomes
unreachable once the branch is deleted, so an empty diff on a branch one or more commits ahead is
never itself a reap signal.

Guard line, verbatim:

```
      [ "$wt_ahead" -eq 0 ] || continue
```

(inside the `if [ -z "$wt_diff" ]; then` empty-diff arm)

Edit: replace that line with `true`.

Test that goes red: `keeps a [gone]-branch worktree whose two commits cancel out to an empty
combined diff` (UAT-005).

What stays green, and why: all 36 other tests, including the zero-commits-ahead reap
(`reaps a [gone]-branch worktree zero commits ahead of the merge base`), whose own `$wt_ahead -eq 0`
is already true and so is unaffected by loosening the check to always pass. The mutation is
attributable to this arm because only a candidate that is ahead with an empty diff exercises the
arm this check exists to refuse.

Checksum before: `a0b1d759ccb546ecf72483c2d2c15bfb88b0e8424c18bc226fb9404c4bbfaab6`.
Checksum after revert: `a0b1d759ccb546ecf72483c2d2c15bfb88b0e8424c18bc226fb9404c4bbfaab6`. Match.

## Mutation 4: the combined-diff read's exit status

Defends against a failed `git diff` read landing in the empty-diff arm unopposed. On a
zero-commits-ahead candidate the ahead-count check (`[ "$wt_ahead" -eq 0 ]`) is already true and
cannot catch a failed read the way it does on a candidate that carries unpushed work, so this
status check is the only thing standing between a failed diff read and a reap.

Guard line, verbatim:

```
    [ "$wt_diff_rc" -eq 0 ] || continue
```

Edit: delete that line.

Test that goes red: `keeps a zero-commits-ahead candidate when the combined-diff read fails`
(UAT-007d).

What stays green, and why: all 36 other tests, including UAT-007a
(`keeps a candidate carrying unpushed work when the combined-diff read fails`), which stays green
for a different reason than this check: that fixture is one or more commits ahead, so a failed read
slipping past the deleted status check still lands on `[ "$wt_ahead" -eq 0 ]`, which is false for
it, and the worktree is kept there too. Only the zero-ahead isolation fixture (UAT-007d) reaches the
reap and exposes the missing check, which is exactly the isolation this row exists to prove.

Checksum before: `a0b1d759ccb546ecf72483c2d2c15bfb88b0e8424c18bc226fb9404c4bbfaab6`.
Checksum after revert: `a0b1d759ccb546ecf72483c2d2c15bfb88b0e8424c18bc226fb9404c4bbfaab6`. Match.

## Mutation 5: the patch-id read's exit status

Defends against a failed `git patch-id` read on the combined diff landing in the empty-diff arm
unopposed, the same shape as mutation 4 one read downstream. `git patch-id` over an empty diff
prints nothing at exit 0, so a genuinely failed read on a zero-ahead candidate is otherwise
indistinguishable from the legitimate zero-commits-ahead reap.

Guard line, verbatim:

```
    [ "$wt_pid_rc" -eq 0 ] || continue
```

Edit: delete that line.

Test that goes red: `keeps a zero-commits-ahead candidate when the patch-id read fails` (UAT-007e).

What stays green, and why: all 36 other tests, including UAT-007b
(`keeps a candidate carrying unpushed work when the patch-id read fails`), which stays green because
that fixture is ahead of the merge base, so the failed read (empty `$wt_pid_out`, silently accepted
without this check) falls through to `[ -n "$wt_pid" ] || continue` in the non-empty-diff arm, which
still refuses it. Only the zero-ahead isolation fixture (UAT-007e) takes the empty-diff arm, where
that downstream check does not run, and exposes the missing status check.

Checksum before: `a0b1d759ccb546ecf72483c2d2c15bfb88b0e8424c18bc226fb9404c4bbfaab6`.
Checksum after revert: `a0b1d759ccb546ecf72483c2d2c15bfb88b0e8424c18bc226fb9404c4bbfaab6`. Match.

## Mutation 7: whitespace-verbatim comparison, both patch-id reads together

Defends against normalization giving an unpushed formatting-only commit the same patch id as the
upstream squash. `git patch-id`'s default mode strips leading whitespace before hashing; `--verbatim`
does not. A branch carrying only a whitespace-only follow-up on top of an already-squashed commit
would otherwise reproduce the squash's id exactly, and the follow-up would be reaped and destroyed
along with the branch.

Guard lines, verbatim (both sites move together; changing one alone makes the two sides
incomparable rather than proving anything about this arm):

```
    wt_pid_out=$(printf '%s\n' "$wt_diff" | git -C "$wt_main" patch-id --verbatim 2>/dev/null)
```

```
        | git -C "$wt_main" patch-id --verbatim 2>/dev/null)
```

Edit: drop `--verbatim` from both invocations (the combined-diff read and the upstream-scan
pipeline).

Test that goes red: `keeps a squash-merged worktree carrying an unpushed whitespace-only follow-up
commit` (UAT-003b).

What stays green, and why: all 36 other tests, including the substantive-follow-up sibling
(`keeps a squash-merged worktree carrying an unpushed substantive follow-up commit`, UAT-003a),
whose follow-up changes real content rather than only whitespace, so its combined diff never
normalizes to the squash's id under either mode and it is kept either way. The mutation is
attributable to this arm because UAT-003b's fixture is deliberately built to differ from the squash
by whitespace alone.

A one-site edit was tried first and rejected as a wrong proof rather than a weaker one: changing
only the combined-diff read's `--verbatim` leaves the branch-side id computed in the default mode
while the upstream-scan read stays verbatim, so the two ids become incomparable, nothing ever
matches, the worktree is kept regardless, and UAT-003b would stay green for a reason that has
nothing to do with the arm under test.

Checksum before: `a0b1d759ccb546ecf72483c2d2c15bfb88b0e8424c18bc226fb9404c4bbfaab6`.
Checksum after revert: `a0b1d759ccb546ecf72483c2d2c15bfb88b0e8424c18bc226fb9404c4bbfaab6`. Match.

## Mutation 8: the scan bound is applied by `git log`'s own `-n`

Defends against the upstream scan running unbounded. The bound has to come from `git log -n`
itself, never a downstream `head -n`, which would close the pipe and raise SIGPIPE 141 under this
file's `set -o pipefail`, silently disabling the guard rather than merely bounding it.

Guard line, verbatim:

```
        --format='commit %H' -n 1000 --end-of-options "$wt_mb..origin/$base" 2>/dev/null \
```

Edit: change `-n 1000` to `-n 500`.

Test that goes red: `UAT-009: the upstream scan bound is applied by git log's own -n option`.

What stays green, and why: 35 of the remaining 36 tests. One other test also reds under this
mutation, for the same underlying reason rather than a masking failure: `UAT-010 positive control:
the merge-evidence scan runs when no cheap gate refuses` asserts the same literal `-n 1000` argv
token as a positive-control witness assertion, so it reds alongside UAT-009 rather than in place of
it. Both reds are attributable to the one literal this mutation changes; nothing unrelated turned.

Checksum before: `a0b1d759ccb546ecf72483c2d2c15bfb88b0e8424c18bc226fb9404c4bbfaab6`.
Checksum after revert: `a0b1d759ccb546ecf72483c2d2c15bfb88b0e8424c18bc226fb9404c4bbfaab6`. Match.

## Mutation 9: gate ordering, the merge-evidence block moves ahead of the cheap refusals

Defends against the expensive merge-evidence reads (merge-base, rev-list, diff, patch-id, the
upstream log scan) running before the cheap refusals (the clean-tree read and the live-RUNNING-plan
sentinel loop) have already had a chance to decline for free. Every gate here is a refusal, so gate
order changes cost, not correctness, but the order is a contract line this row proves is actually
in force.

Edit (a block move, stated as precisely as it can be without reproducing the whole diff): cut the
clean-tree read (`wt_status_out=$(git -C "$wt_path" status --porcelain ...)` through
`[ -z "$wt_status_out" ] || continue`) and the RUNNING-sentinel loop immediately after it (the
`wt_live=0` ... `[ "$wt_live" -eq 0 ] || continue` block) from their position directly after the
`[gone]` track check, and reinsert that same contiguous span directly after the merge-evidence
block's closing `fi` (the end of the empty-diff/non-empty-diff disposition), immediately before the
"Tear down inline" comment. Nothing inside either moved block is edited; only their position swaps
with the merge-evidence block's.

Test that goes red: `UAT-010: the merge-evidence scan runs only after the cheap refusal gates`.

What stays green, and why: all 36 other tests, including `UAT-010 positive control: the
merge-evidence scan runs when no cheap gate refuses` and `UAT-009: the upstream scan bound is
applied by git log's own -n option`, both of which build candidates with no cheap gate to refuse on,
so reordering which gate runs first changes nothing they assert. UAT-010's own two negative-count
candidates (a dirty tree, a live RUNNING sentinel) are the only fixtures built specifically to prove
the merge-evidence reads never ran on them; moving those reads ahead of the gates that were supposed
to spare them is exactly what turns this test's witness counts positive.

Checksum before: `a0b1d759ccb546ecf72483c2d2c15bfb88b0e8424c18bc226fb9404c4bbfaab6`.
Checksum after revert: `a0b1d759ccb546ecf72483c2d2c15bfb88b0e8424c18bc226fb9404c4bbfaab6`. Match.

## Mutation 10: the patch-id comparison itself

Defends against the upstream scan matching every candidate regardless of whether its patch id
actually appears in the upstream range, which would turn the guard from a proof of a squash merge
into an unconditional reap of anything [gone] and ahead.

Guard line, verbatim:

```
        if [ "$wt_up_id" = "$wt_pid" ]; then
```

Edit: change the condition to `if true; then`.

Test that goes red: `keeps a squash-merged worktree carrying an unpushed substantive follow-up
commit` (UAT-003a).

What stays green, and why: 35 of the remaining 36 tests. One other test also reds under this
mutation, attributably rather than vacuously: `keeps a squash-merged worktree carrying an unpushed
whitespace-only follow-up commit` (UAT-003b) is kept in the shipped guard by the same comparison
line (its combined diff, computed `--verbatim`, does not match the upstream squash's id), so forcing
the comparison to always match reaps it too, for the identical reason UAT-003a reds. Both are direct
consequences of the one condition this mutation changes, not an unrelated test turning.

Checksum before: `a0b1d759ccb546ecf72483c2d2c15bfb88b0e8424c18bc226fb9404c4bbfaab6`.
Checksum after revert: `a0b1d759ccb546ecf72483c2d2c15bfb88b0e8424c18bc226fb9404c4bbfaab6`. Match.

## Arms with no test that reds them

### Row 2: the merge-base read's status and emptiness, together

The frozen guard shape masks this pair rather than leaving it untested for want of a fixture.
Deleting both `[ "$wt_mb_rc" -eq 0 ] || continue` and `[ -n "$wt_mb" ] || continue` was tried and
observed, not assumed: `git merge-base` against a deleted `origin/main` (the fixture
`keeps a [gone]-branch worktree when the merge-base read fails`, UAT-006, builds) exits non-zero
**and** prints nothing on the same failure, so `wt_mb` is empty either way. With both checks
removed, `wt_mb` is the empty string and every downstream read that interpolates it
(`"$wt_mb..refs/heads/$wt_branch"`, `"$wt_mb" "refs/heads/$wt_branch"`, `"$wt_mb..origin/$base"`)
becomes a malformed git invocation that itself fails, and the next read's own status check (mutation
4's and 5's arms, still intact) refuses on that failure instead. Running the full 37-test suite
against this double deletion showed all 37 tests green, including UAT-006, confirming the pair is
masked rather than reachable. This is one condition expressed twice (an absent `origin/<base>`
producing a failed AND empty read simultaneously), not two independent checks, so it is recorded as
one unproven arm rather than split into two.

### Row 6 (old numbering): `[ -n "$wt_pid" ] || continue` inside the non-empty-diff arm

Defends against an empty branch-side patch id, which `git patch-id` can print at exit 0 in a way
this file's other checks do not otherwise catch. With it deleted, an empty `$wt_pid` is compared
against every upstream id in the scan and matches none of them, because `git patch-id` does not
itself emit empty id fields; the worktree is kept either way, so no fixture can red this line. It
stays in the guard as defense in depth against a future change to a neighbouring gate.

### `[ -n "$wt_up_id" ] || continue` inside the comparison loop

Same shape as the row above, from the other side of the same comparison: it can only matter if the
upstream id list materialized from `git log -p ... | git patch-id --verbatim` contains an empty
field, which that pipeline does not produce. No fixture can construct the condition this line
defends against without editing the pipeline itself, which is out of this change's scope.

### Row 11 (old numbering): `[ "$wt_up_rc" -eq 0 ] || continue`, the upstream-scan pipeline's status

Defends against a failed upstream scan (`git log -p ... | git patch-id --verbatim`) being read as an
empty, no-match result rather than a failure. With it deleted, a failed scan leaves `wt_up_ids`
empty, the comparison loop finds nothing to match, and the worktree is kept, the same outcome as a
genuinely bounded scan that ends without a match, so no fixture can distinguish the two cases. This
one status is the guard's single sanctioned exception to the own-exit-status rule: it covers the
whole two-command pipeline via `set -o pipefail` rather than a single read, because splitting it
would require materializing up to 1000 commits' patches into a shell variable before the pipeline
could report per-command status.

### Contract lines with no reddening fixture, by design

`--no-merges`, `--end-of-options`, `--no-ext-diff --no-textconv`, and the `refs/heads/`
qualification each defend against a condition (a merge commit contributing a spurious id, a
flag-shaped ref, an external differ or textconv filter emptying the diff at exit 0, a same-named tag
shadowing the branch) whose fixture would cost more to build than the arm is worth proving here.
None of these are attempted in this record.

## Reproducing this record

```bash
bash .gaia/scripts/bats5.sh .gaia/tests/hooks/local-janitor-worktree-reap.bats
```

Every red above was observed by applying its edit to the shipped `.claude/hooks/local-janitor.sh`,
running that command, reading the named test(s) fail and the rest of the suite pass, then reverting
and confirming the checksum. Nothing in this file is a predicted result.
