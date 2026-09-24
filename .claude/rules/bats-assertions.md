---
paths:
  - '**/*.bats'
---

# Bats Assertion Hygiene (bash 3.2 safe)

macOS ships bash 3.2.57 as `/bin/bash`, which is what bats-core resolves to by default on a stock Mac, and bash 3.2 silently skips a failing bare `[[ ... ]]` inside a `@test` body under `set -e` so a broken assertion greens locally with nothing to catch it, which is why bats always runs through the bash-5 guard below rather than directly.

## Run bats under bash 5 (pre-flight)

A bash-3.2 local `bats` run is a **weaker signal than CI** (ubuntu bash 5), and the gap is not limited to the `[[ ]]` skip above. A second, independent gap is BSD-vs-GNU CLI divergence: a macOS-only green misses commands that only exist in one flavor. The concrete case is `date -v` (BSD) versus `date -d` (GNU): the losing form exits non-zero on Linux, and under bats' `set -e` that aborts the test before any fallback runs.

Run bats through the guard in `.gaia/scripts/bats5.sh` instead of calling `bats` directly: `source .gaia/scripts/bats5.sh`, then call `bats5` wherever the rest of this page says `bats` (or run `.gaia/scripts/bats5.sh <args>` directly). It prefers a Homebrew bash 5 when one is installed (Apple Silicon: `/opt/homebrew/bin/bash`, Intel: `/usr/local/bin/bash`) and warns loudly on stderr when the bash bats will actually use resolves to major version < 4, so the warning fires only where the gap is real (silent on any bash 5 host, macOS or Linux).

<!-- gaia:maintainer-only:start -->
A deterministic lint over `.bats` files and shipped `*.sh` for `date -v` / `date -d` usage would catch the BSD/GNU class statically; that belongs in the shell-lint gate (`.gaia/tests/shell-lint.sh`), outside this rule's scope.
<!-- gaia:maintainer-only:end -->

## `!`-negated assertions never fail a non-final test line (all bash versions)

<!-- gaia-harden: promoted from recurring finding_class rule/bats-negation-under-set-e; pruned by /gaia-audit on obsolescence/redundancy/supersession/duplication only, never for non-recurrence -->

Separate from the bash-3.2 `[[ ]]` skip, and present on **every** bash version including bash 5: POSIX `set -e` explicitly exempts a command whose exit status is inverted by `!` from triggering the abort. bats runs each `@test` body under `set -e`, so a `!`-negated absence assertion used as a **non-final** statement passes silently even when its bad case is true. The inverted non-zero status never aborts, and only the test's last command decides the result.

The trap, an absence assertion meant to fail when `needle` leaks into `$output`:

```bash
! grep -qF -- "needle" <<<"$output"   # needle present -> grep 0 -> ! inverts to 1, but set -e exempts a !-negation, so the test continues and greens
# ... more assertions ...
```

Write the bad case as a positive match that returns non-zero on its own, so the failure is the test's own `return`, not a `!`-inverted status `set -e` ignores:

```bash
grep -qF -- "needle" <<<"$output" && return 1   # needle present -> grep 0 -> return 1 -> the test fails
```

The principle is general: end a failing branch with an explicit `return 1`, applied here to inline absence assertions. A `!`-negated command is only safe as a test's **final** line, where its status becomes the test result. Anywhere earlier, write `<positive-condition-for-the-bad-case> && return 1`.

The mirror image, and the reason the two forms swap places: `&& return 1` is safe anywhere except a test's **final** statement. There, an absent needle leaves grep's own non-zero status as the AND-list's status, which becomes the test's return value, so the test fails in exactly the case it exists to pass. A test whose last statement is such a check ends with an explicit `true`.

## A guard over a set derives the set and asserts per element

A different axis from everything above. Those sections decide whether an assertion *can* fail. This one decides whether it covers what its name claims. A guard that pins one representative element and names itself for the set is green, non-vacuous, and still blind to every element it never drove.

**The rule: a guard over a set derives the set from the artifact that owns it and asserts per element. It never asserts one element and names itself for the set.**

- **A short read is more dangerous than an empty one.** A derivation that yields nothing trips a non-empty guard. A derivation that yields three of four entries does not: the guard stays satisfied and the suite drives a subset while its names still say "every". Count the entries the derivation should have produced, compare against the names it actually read, and fail on the difference. Symmetrically, a per-element claim over an empty set is true without meaning anything, so a derivation that can legitimately come back empty reports that as a failure, never as a pass.
