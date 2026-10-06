# SPEC-ledger lib harness

Maintainer-only bats suite for the SPEC ledger machinery:
`.gaia/scripts/spec/spec-allocator.sh`, `ledger-update.sh`, and the
shared `with-ledger-lock.sh` mutex. Excluded from the release bundle via
`.gaia/release-exclude` (category `.gaia/tests/`). Every test is hermetic
each spins up its own tmp git repo via `helpers/tmp-spec-repo.sh` and tears it
down; no reliance on the real project `.gaia/local/specs/ledger.json`.

This directory also carries **doc-conformance** suites, which grep instruction
markdown rather than exercising a script. They live here because this is the
bats directory `.github/workflows/audit-ci-tests.yml` actually runs (`bats
.gaia/tests/lib/`); a doc-conformance suite landed in `.gaia/tests/sandbox/`,
which no workflow runs, would gate nothing.

## Coverage

Each `*.bats` file's own header comment states what it tests and why; this page does not restate them.

The N-parallel test uses a start-flag barrier so the `next` calls genuinely
overlap. A passing run with no contention proves nothing; with the barrier,
the unlocked read-modify-write would fail (duplicate id + lost ledger row).
Several `@test`s assert that a non-zero exit code propagates _through_
`with_ledger_lock` (forced jq failure → 4, invalid patch → 5, lock timeout →
4); a single happy-path run stays green even with a swallowed-code bug, so
these negative assertions are load-bearing.

## Running

```bash
bash .gaia/tests/lib/run-all.sh
```

Individual test files:

```bash
bats .gaia/tests/lib/with-ledger-lock.bats
bats .gaia/tests/lib/spec-allocator-concurrency.bats
```

## Prerequisites

- `bats-core` on `$PATH`. Install via:
  - macOS: `brew install bats-core`
  - Debian/Ubuntu CI: `apt-get install -y bats`
  - Any platform: `npx -y bats@latest` (the `run-all.sh` entrypoint falls
    back to this)
- `jq` on `$PATH`
- `git` on `$PATH`

The npm package is `bats`, not `bats-core`. The project is bats-core and the
Homebrew formula is bats-core, but no `bats-core` package is published to npm,
so that spelling resolves to an E404 rather than to a fallback.

`flock` is optional. On a box without it (e.g. stock macOS) the
mkdir-fallback is the load-bearing lock path and is exercised by the forced
fallback tests; the flock-path test `skip`s with a clear reason.

## CI integration

CI should add a `bash .gaia/tests/lib/run-all.sh` step parallel to the
forensics suite, in whichever workflow runs the other bats harnesses. The
actual CI YAML edit is out of scope for this suite.
