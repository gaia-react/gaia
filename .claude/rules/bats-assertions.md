---
paths:
  - '**/*.bats'
---

# Bats Assertion Hygiene (bash 3.2 safe)

macOS ships bash 3.2.57 as `/bin/bash`, which is what bats-core resolves to by default on a stock Mac. On bash 3.2 a **false** bare `[[ ... ]]` inside a `@test` body does **not** fail the test: bash 3.2 skips a failing `[[ ]]` under `set -e` / the ERR trap, so only the test's **last** command's exit status flows through. A broken assertion greens locally with nothing to catch it.

Repro (bats runs each `@test` body under `set -e`, so mirror it with a plainly-called function -- not `f && ...`, since `&&` suppresses `set -e` inside `f` on *both* versions): `bash -c 'set -e; f(){ [[ 1 == 2 ]]; echo reached; }; f; echo after'` prints `reached` + `after` on bash 3.2 (the false `[[ ]]` is skipped, so only the last command's status flows through) but nothing on bash 5 (it aborts at the `[[ ]]`).

## Run bats under bash 5 (pre-flight)

A bash-3.2 local `bats` run is a **weaker signal than CI** (ubuntu bash 5), and the gap is not limited to the `[[ ]]` skip documented below. A second, independent gap is BSD-vs-GNU CLI divergence: a macOS-only green misses commands that only exist in one flavor. The concrete case is `date -v` (BSD) versus `date -d` (GNU): the losing form exits non-zero on Linux, and under bats' `set -e` that aborts the test before any fallback runs.

Run bats through the guard in `.gaia/scripts/bats5.sh` instead of calling `bats` directly: `source .gaia/scripts/bats5.sh`, then call `bats5` wherever the rest of this page says `bats` (or run `.gaia/scripts/bats5.sh <args>` directly). It prefers a Homebrew bash 5 when one is installed (Apple Silicon: `/opt/homebrew/bin/bash`, Intel: `/usr/local/bin/bash`) and warns loudly on stderr when the bash bats will actually use resolves to major version < 4, so the warning fires only where the gap is real (silent on any bash 5 host, macOS or Linux).

<!-- gaia:maintainer-only:start -->
A deterministic lint over `.bats` files and shipped `*.sh` for `date -v` / `date -d` usage would catch the BSD/GNU class statically; that belongs in the shell-lint gate (`.gaia/tests/shell-lint.sh`), outside this rule's scope.
<!-- gaia:maintainer-only:end -->

## Write assertions that fail correctly on bash 3.2

For any assertion that is not the test's final command, use a form that fails under 3.2:

- **Substring / prefix:** `grep -qF -- "needle" <<<"$output"`, not `[[ "$output" == *needle* ]]`.
- **Equality / numeric / empty / file:** POSIX `[ ... ]` fails correctly: `[ "$status" -eq 0 ]`, `[ "$a" = "$b" ]`, `[ -z "$output" ]`.
- **Keep a `[[ ]]` matcher when you need one:** append `|| return 1` -> `[[ "$output" == *needle* ]] || return 1`.
- **Custom checks:** end the failing branch with an explicit `return 1`.
<!-- gaia:maintainer-only:start -->

Reference pattern: `.gaia/scripts/tests/token-cost-e2e.bats` -- its `assert_contains` / `refute_contains` / `assert_prefix` helper trio and the assertion-style note at the top.
<!-- gaia:maintainer-only:end -->

## `!`-negated assertions never fail a non-final test line (all bash versions)

<!-- gaia-harden: promoted from recurring finding_class rule/bats-negation-under-set-e; pruned by /gaia-audit on obsolescence/redundancy/supersession/duplication only, never for non-recurrence -->

Separate from the bash-3.2 `[[ ]]` skip above, and present on **every** bash version including bash 5: POSIX `set -e` explicitly exempts a command whose exit status is inverted by `!` from triggering the abort. bats runs each `@test` body under `set -e`, so a `!`-negated absence assertion used as a **non-final** statement passes silently even when its bad case is true. The inverted non-zero status never aborts, and only the test's last command decides the result.

The trap, an absence assertion meant to fail when `needle` leaks into `$output`:

```bash
! grep -qF -- "needle" <<<"$output"   # needle present -> grep 0 -> ! inverts to 1, but set -e exempts a !-negation, so the test continues and greens
# ... more assertions ...
```

Write the bad case as a positive match that returns non-zero on its own, so the failure is the test's own `return`, not a `!`-inverted status `set -e` ignores:

```bash
grep -qF -- "needle" <<<"$output" && return 1   # needle present -> grep 0 -> return 1 -> the test fails
```

This is the same principle as the custom-check rule above, end the failing branch with an explicit `return 1`, applied to inline absence assertions. A `!`-negated command is only safe as a test's **final** line, where its status becomes the test result. Anywhere earlier, write `<positive-condition-for-the-bad-case> && return 1`.

The mirror image, and the reason the two forms swap places: `&& return 1` is safe anywhere except a test's **final** statement. There, an absent needle leaves grep's own non-zero status as the AND-list's status, which becomes the test's return value, so the test fails in exactly the case it exists to pass. A test whose last statement is such a check ends with an explicit `true`.

## Backstops, not substitutes

<!-- gaia:maintainer-only:start -->
- CI (`.github/workflows/audit-ci-tests.yml`) runs the `.gaia/scripts/tests/`, `.gaia/tests/forensics/`, and `.gaia/tests/hooks/` suites on ubuntu (bash 5), which **does** enforce `[[ ]]`. That is the authoritative gate, but it only catches a hollow assertion after push.
<!-- gaia:maintainer-only:end -->
- Run bats under bash 5 locally so local matches CI: see "Run bats under bash 5 (pre-flight)" above for the guard.

## A guard over a set derives the set and asserts per element

A different axis from everything above. Those sections decide whether an assertion *can* fail. This one decides whether it covers what its name claims. A guard that pins one representative element and names itself for the set is green, non-vacuous, and still blind to every element it never drove.

**The rule: a guard over a set derives the set from the artifact that owns it and asserts per element. It never asserts one element and names itself for the set.**

What follows from it:

- **Coverage is per element; a non-vacuity control may sample one.** A mutation control exists to prove an assertion is not vacuous, and one element establishes that; mutating the whole set buys the same signal at N times the cost. Say in the comment that it is sampling on purpose, so the next reader does not mistake the sample for the coverage.
- **Derive from the artifact, do not restate it.** The source of truth is the file the machinery itself reads. A second list kept in the test is a list someone has to remember to grow, and nothing goes red when they do not.
- **A short read is more dangerous than an empty one.** A derivation that yields nothing trips a non-empty guard. A derivation that yields three of four entries does not: the guard stays satisfied and the suite drives a subset while its names still say "every". Count the entries the derivation should have produced, compare against the names it actually read, and fail on the difference. Symmetrically, a per-element claim over an empty set is true without meaning anything, so a derivation that can legitimately come back empty reports that as a failure, never as a pass.
- **No counts in test names or in the comments describing the set.** The elements are the authority on how many. A cardinal (`both`, `all five`, `the eleven hooks`) or a parenthesized literal list rots the next time the set changes, and the rotted number reads as an assertion nobody has checked.

When the set genuinely is not machine-derivable, the guard's name has to say what it actually pins, and the hand-written enumeration carries a per-entry warrant plus a "deliberately not a member" list with a reason on each entry, so a reader sees that every candidate was considered rather than missed.
<!-- gaia:maintainer-only:start -->

This rule is armed on `**/*.bats` and stays there, so a `.gaia/scripts/check-*.sh` guard over a set
never loads it. That is the scoping the class earned rather than an oversight: every instance the
sweep behind this section found was a `.bats` file, and the `.sh` checks below are where the good
pattern already lives. They are named as the form to copy, not as a claim this rule reaches them.

Reference forms, in order of how much of the pattern each one shows:

- `.gaia/scripts/check-step-body-extractor-roster.sh` -- the whole shape, including a header that records why the literal recipe it replaced was believed complete each time it was written and was not.
- `.gaia/tests/hooks/audit-root-resolution.bats` -- `roster_members` derives the Code Audit Team from `.gaia/audit-ci.yml` rather than listing it, counts entries against names read so an off-spelled member stops the suite instead of shrinking it, and its stage 8 header states the coverage-versus-non-vacuity split for the one control that samples a single member.
- `.gaia/tests/lib/audit-ci-shards.bats` -- `read_wf aggok` derives an aggregator job's dependencies from its own `needs:` and answers `no` on an empty one.
<!-- gaia:maintainer-only:end -->

## Scope

This steers **new and edited** assertions. Existing suites use bare `[[ ]]` heavily; they are grandfathered and enforced by CI's bash 5. Do not rewrite them for this rule alone.
