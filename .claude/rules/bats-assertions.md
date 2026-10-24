---
paths:
  - '**/*.bats'
---

# Bats Assertion Hygiene (bash 3.2 safe)

macOS ships bash 3.2.57 as `/bin/bash`, which is what bats-core resolves to by default on a stock Mac, and bash 3.2 silently skips a failing bare `[[ ... ]]` inside a `@test` body under `set -e` so a broken assertion greens locally with nothing to catch it, which is why bats always runs through the bash-5 guard below rather than directly.

## Run bats under bash 5 (pre-flight)

A bash-3.2 local `bats` run is a **weaker signal than CI** (ubuntu bash 5), and the gap is not limited to the `[[ ]]` skip above. A second, independent gap is BSD-vs-GNU CLI divergence: a macOS-only green misses commands that only exist in one flavor. The concrete case is `date -v` (BSD) versus `date -d` (GNU): the losing form exits non-zero on Linux, and under bats' `set -e` that aborts the test before any fallback runs.

Run bats through the guard in `.gaia/scripts/bats5.sh` instead of calling `bats` directly: `source .gaia/scripts/bats5.sh`, then call `bats5` wherever the rest of this page says `bats` (or run `.gaia/scripts/bats5.sh <args>` directly). It prefers a Homebrew bash 5 and warns on stderr only when the bash bats will use is older than 4.

## `!`-negated assertions never fail a non-final test line (all bash versions)

<!-- gaia-harden: promoted from recurring finding_class rule/bats-negation-under-set-e; pruned by /gaia-cleanse on obsolescence/redundancy/supersession/duplication only, never for non-recurrence -->

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

Those sections decide whether an assertion *can* fail; this one decides whether it covers what its name claims.

**The rule: a guard over a set derives the set from the artifact that owns it and asserts per element. It never asserts one element and names itself for the set.**

- **A short read is more dangerous than an empty one.** A derivation that yields nothing trips a non-empty guard. A derivation that yields three of four entries does not: the guard stays satisfied and the suite drives a subset while its names still say "every". Count the entries the derivation should have produced, compare against the names it actually read, and fail on the difference. Symmetrically, a per-element claim over an empty set is true without meaning anything, so a derivation that can legitimately come back empty reports that as a failure, never as a pass.

## Mark a whole-tree test with `# bats test_tags=whole-tree`

The change selector picks a suite only when the suite names a changed file. A test whose outcome depends on tracked files its suite does not name (an invariant over every agent file, every shell script, every workflow) is never picked, so it goes red on CI after the push. Mark it.

**The per-test mark is the default.** Put `# bats test_tags=whole-tree` on a line of its own at column 0, directly above each `@test` that depends on unnamed tracked files:

```bash
# bats test_tags=whole-tree
@test "every agent file declares a model" {
```

`whole-tree` joins an existing comma list (`# bats test_tags=foo,whole-tree`), because bats keeps only the last `test_tags` line before a test.

**The file mark is the exception.** `# bats file_tags=whole-tree`, on a line of its own after the header comment and before `setup`, `setup_file` and the first `@test`, is for a suite whose every test depends on unnamed tracked files, or whose `setup`, `setup_file` or a helper enumerates the tracked tree without a waiver. It joins a comma list the same way.

**The waiver.** A statement that enumerates the tracked tree outside a test body is waived with `# gaia-lint-ignore whole-tree-mark-guard: <reason>` on the comment line directly above it. Two reasons are accepted: every test that depends on the idiom carries the per-test mark, or the idiom's operand is not the tracked tree. One recorded exception exists, the `setup_file` waiver in the pre-push end-to-end suite, whose reason records the decision to keep that suite out of the whole-tree step. Shell-lint's owner guard reports an empty reason as malformed; review checks that the reason is true. Write the pragma form inside backticks in prose, never as a line whose first token after `#` is `gaia-lint-ignore`.

**How the runner uses the marks.** The verification runner (`.gaia/tests/verify-harness.sh`) runs every marked test in branch mode (`--filter-tags whole-tree`), runs a suite the change selector picks in full under bats selected, and leaves marks out of round mode; the why is the maintainer block in `wiki/concepts/Audit Round Procedure.md`. Pre-merge CI runs every marked test, so it catches a round fix that breaks a whole-tree invariant, and the full suite runs on every push to main. The patterns in `.gaia/tests/helpers/verify-harness-bats-lib.sh` define the marked set.

`.gaia/tests/whole-tree-mark-guard.sh` flags an unmarked test or suite that enumerates the real tracked tree through an idiom it recognizes; its header lists the idioms. It also sees a test that reaches the tree through a script or helper it calls; its header owns the hops it follows and the idioms it recognizes. What it cannot see (a path built at run time) needs a hand mark, and an unmarked one is caught only by the push-to-main full run. A suite that writes fixture suites carrying either tag assembles the line at run time (`printf '# bats %s\n' 'test_tags=whole-tree'`) so it never holds the line at column 0 itself.
