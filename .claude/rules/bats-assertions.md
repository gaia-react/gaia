---
paths:
  - '**/*.bats'
---

# Bats Assertion Hygiene (bash 3.2 safe)

macOS ships bash 3.2.57 as `/bin/bash`, which is what bats-core resolves to by default on a stock Mac. On bash 3.2 a **false** bare `[[ ... ]]` inside a `@test` body does **not** fail the test: bash 3.2 skips a failing `[[ ]]` under `set -e` / the ERR trap, so only the test's **last** command's exit status flows through. A broken assertion greens locally with nothing to catch it.

Repro (bats runs each `@test` body under `set -e`, so mirror it with a plainly-called function -- not `f && ...`, since `&&` suppresses `set -e` inside `f` on *both* versions): `bash -c 'set -e; f(){ [[ 1 == 2 ]]; echo reached; }; f; echo after'` prints `reached` + `after` on bash 3.2 (the false `[[ ]]` is skipped, so only the last command's status flows through) but nothing on bash 5 (it aborts at the `[[ ]]`).

## Run bats under bash 5 (pre-flight)

A bash-3.2 local `bats` run is a **weaker signal than CI** (ubuntu bash 5), and the gap is not limited to the `[[ ]]` skip documented below. A second, independent gap is BSD-vs-GNU CLI divergence: a macOS-only green misses commands that only exist in one flavor. The concrete case is `date -v` (BSD) versus `date -d` (GNU): the losing form exits non-zero on Linux, and under bats' `set -e` that aborts the test before any fallback runs.

Run bats through this guard instead of calling `bats` directly. It prefers a Homebrew bash 5 when one is installed (Apple Silicon: `/opt/homebrew/bin/bash`, Intel: `/usr/local/bin/bash`) and warns loudly on stderr when the bash bats will actually use resolves to major version < 4, so the warning fires only where the gap is real (silent on any bash 5 host, macOS or Linux):

```bash
bats5() {
  for d in /opt/homebrew/bin /usr/local/bin; do
    if [ -x "$d/bash" ]; then
      PATH="$d:$PATH"
      export PATH
      break
    fi
  done
  resolved_bash=$(command -v bash)
  major=$("$resolved_bash" -c 'echo "${BASH_VERSINFO[0]}"')
  if [ "$major" -lt 4 ]; then
    echo "############################################################" >&2
    echo "# WARNING: bats will run under bash $major ($resolved_bash)." >&2
    echo "# This local green is a WEAKER signal than CI (ubuntu bash 5):" >&2
    echo "# a false bare [[ ]] can pass silently, and BSD-only commands" >&2
    echo "# (e.g. 'date -v') that fail on Linux won't be caught here." >&2
    echo "# brew install bash, then re-run before trusting this pass count." >&2
    echo "############################################################" >&2
  fi
  bats "$@"
}
```

Source it (or paste it into the shell), then call `bats5` wherever the rest of this page says `bats`.

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

## Backstops, not substitutes

<!-- gaia:maintainer-only:start -->
- CI (`.github/workflows/audit-ci-tests.yml`) runs the `.gaia/scripts/tests/`, `.gaia/tests/forensics/`, and `.gaia/tests/hooks/` suites on ubuntu (bash 5), which **does** enforce `[[ ]]`. That is the authoritative gate, but it only catches a hollow assertion after push.
<!-- gaia:maintainer-only:end -->
- Run bats under bash 5 locally so local matches CI: see "Run bats under bash 5 (pre-flight)" above for the guard.

## Scope

This steers **new and edited** assertions. Existing suites use bare `[[ ]]` heavily; they are grandfathered and enforced by CI's bash 5. Do not rewrite them for this rule alone.
