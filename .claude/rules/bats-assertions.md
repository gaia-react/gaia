---
paths:
  - '**/*.bats'
---

# Bats Assertion Hygiene (bash 3.2 safe)

macOS ships bash 3.2.57 as `/bin/bash`, which is what bats-core resolves to by default on a stock Mac. On bash 3.2 a **false** bare `[[ ... ]]` inside a `@test` body does **not** fail the test: bash 3.2 skips a failing `[[ ]]` under `set -e` / the ERR trap, so only the test's **last** command's exit status flows through. A broken assertion greens locally with nothing to catch it.

Repro (bats runs each `@test` body under `set -e`, so mirror it with a plainly-called function -- not `f && ...`, since `&&` suppresses `set -e` inside `f` on *both* versions): `bash -c 'set -e; f(){ [[ 1 == 2 ]]; echo reached; }; f; echo after'` prints `reached` + `after` on bash 3.2 (the false `[[ ]]` is skipped, so only the last command's status flows through) but nothing on bash 5 (it aborts at the `[[ ]]`).

## Write assertions that fail correctly on bash 3.2

For any assertion that is not the test's final command, use a form that fails under 3.2:

- **Substring / prefix:** `grep -qF -- "needle" <<<"$output"`, not `[[ "$output" == *needle* ]]`.
- **Equality / numeric / empty / file:** POSIX `[ ... ]` fails correctly: `[ "$status" -eq 0 ]`, `[ "$a" = "$b" ]`, `[ -z "$output" ]`.
- **Keep a `[[ ]]` matcher when you need one:** append `|| return 1` -> `[[ "$output" == *needle* ]] || return 1`.
- **Custom checks:** end the failing branch with an explicit `return 1`.

Reference pattern: `.gaia/scripts/tests/token-cost-e2e.bats` -- its `assert_contains` / `refute_contains` / `assert_prefix` helper trio and the assertion-style note at the top.

## Backstops, not substitutes

- CI (`.github/workflows/audit-ci-tests.yml`) runs the `.gaia/scripts/tests/`, `.gaia/tests/forensics/`, and `.gaia/tests/hooks/` suites on ubuntu (bash 5), which **does** enforce `[[ ]]`. That is the authoritative gate, but it only catches a hollow assertion after push.
- Run bats under bash 5 locally so local matches CI: `brew install bash` installs `/opt/homebrew/bin/bash`, and bats picks it up via `env bash` when that dir precedes `/bin` on `PATH`. A false mid-test `[[ ]]` then fails locally too.

## Scope

This steers **new and edited** assertions. Existing suites use bare `[[ ]]` heavily; they are grandfathered and enforced by CI's bash 5. Do not rewrite them for this rule alone.
