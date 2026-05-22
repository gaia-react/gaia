# SPEC-ledger lib harness

Maintainer-only bats suite for the SPEC ledger machinery:
`.specify/extensions/gaia/lib/spec-allocator.sh`, `ledger-update.sh`, and the
shared `with-ledger-lock.sh` mutex. Excluded from the release bundle via
`.gaia/release-exclude` (category `.gaia/tests/`). Every test is hermetic —
each spins up its own tmp git repo via `helpers/tmp-spec-repo.sh` and tears it
down; no reliance on the real project `.gaia/specs.json`.

## Coverage

| File                              | What it tests                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| --------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `with-ledger-lock.bats`           | The mutex helper in isolation (Contract C1): acquire/release, exit-code passthrough, no-stdout rule, forced mkdir fallback, acquisition timeout → 75, stale-lock recovery, flock path when present.                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| `spec-allocator-concurrency.bats` | Allocator + ledger-update concurrency (Contracts C2/C3): N-parallel `next` with no lost rows and no duplicate ids (real flock and forced fallback), stale-lock recovery, `in_progress` draft surfacing + legacy fallback + none, read-only modes take no lock, exit-code preservation, and the cross-script `ledger-update` racing `next` interleaving.                                                                                                                                                                                                                                                                                                      |
| `spec-folder-layout.bats`         | Per-SPEC folder layout + migration (Contract C7): `spec-folderize.sh` happy path (flat + `archived/` → `<id>/SPEC.md`, byte-identical contents), idempotent re-run, `--dry-run` no-op, empty-tree no-op, flat+foldered conflict → exit 4, tracked-vs-untracked move strategy (`git mv` vs `mv`); allocator `highest`/`next`/`in_progress` over foldered specs (`next` creates no folder, ledger-first wins, foldered fallback resolves); `spec-renumber.sh` folder rename keeping `SPEC.md` named `SPEC.md` with siblings carried + collision guard; a flat→folderize→`next`→renumber→archive round-trip; read-only modes take no lock and create no folder. |

The N-parallel test uses a start-flag barrier so the `next` calls genuinely
overlap. A passing run with no contention proves nothing — with the barrier,
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
  - Any platform: `npx -y bats-core@latest` (the `run-all.sh` entrypoint falls
    back to this)
- `jq` on `$PATH`
- `git` on `$PATH`

`flock` is optional. On a box without it (e.g. stock macOS) the
mkdir-fallback is the load-bearing lock path and is exercised by the forced
fallback tests; the flock-path test `skip`s with a clear reason.

## CI integration

CI should add a `bash .gaia/tests/lib/run-all.sh` step parallel to the
forensics suite, in whichever workflow runs the other bats harnesses. The
actual CI YAML edit is out of scope for this suite.
