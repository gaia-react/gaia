# SPEC-ledger lib harness

Maintainer-only bats suite for the SPEC ledger machinery:
`.specify/extensions/gaia/lib/spec-allocator.sh`, `ledger-update.sh`, and the
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

| File                              | What it tests                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| --------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `with-ledger-lock.bats`           | The mutex helper in isolation (Contract C1): acquire/release, exit-code passthrough, no-stdout rule, forced mkdir fallback, acquisition timeout → 75, stale-lock recovery, flock path when present.                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| `spec-allocator-concurrency.bats` | Allocator + ledger-update concurrency (Contracts C2/C3): N-parallel `next` with no lost rows and no duplicate ids (real flock and forced fallback), stale-lock recovery, `in_progress` draft surfacing + legacy fallback + none, read-only modes take no lock, exit-code preservation, and the cross-script `ledger-update` racing `next` interleaving.                                                                                                                                                                                                                                                                                                      |
| `spec-folder-layout.bats`         | Per-SPEC folder layout + migration (Contract C7): `spec-folderize.sh` happy path (flat + `archived/` → `<id>/SPEC.md`, byte-identical contents), idempotent re-run, `--dry-run` no-op, empty-tree no-op, flat+foldered conflict → exit 4, tracked-vs-untracked move strategy (`git mv` vs `mv`); allocator `highest`/`next`/`in_progress` over foldered specs (`next` creates no folder, ledger-first wins, foldered fallback resolves); `spec-renumber.sh` folder rename keeping `SPEC.md` named `SPEC.md` with siblings carried + collision guard; a flat→folderize→`next`→renumber→archive round-trip; read-only modes take no lock and create no folder. |
| `doc-isolation.bats`              | Doc-conformance for the shared isolation reference (`.claude/skills/gaia/references/isolation.md`) and its two callers. Byte-identity: a bash renderer takes the prompt literals, the option order, and the lead option out of the fragment, substitutes each caller's four slots, and diffs against the golden fixtures in `fixtures/isolation/` (captured from git, never from the working tree). Plus the single `(Recommended)` append site, the single `Default. ` prefix site (pinned to the fragment, since the renderer synthesizes the prefix and would otherwise green a fragment that had dropped the rule), the single `EnterWorktree(` call, the arm ordering (forced worktree before the policy read, and it never prompts), one pointer per caller with no copied literals, the pointer-not-snapshot rule for the generated `ORCHESTRATOR.md`, and the `RESOLVED_MODE` export.                                                                                        |
| `doc-setup-gaia-isolation.bats`   | Doc-conformance for the `/setup-gaia` `## Phase 3.5` clause (`.claude/commands/setup-gaia.md`), the existing-adopter entry point for the team isolation policy. Gate ordering (the absent-config skip precedes the write shell-out; the `check-admin` probe precedes the question; the `has("isolation_policy")` + `RECONFIGURE` gate precedes the question), exactly one `AskUserQuestion` headed `Isolation policy` with neither fragment option label, no JSON-writing construct besides the one CLI shell-out, the clause's own commit, and the explainer naming all four worktree costs plus the `/gaia-plan` / `/gaia-debt` scope limit.                                                                                        |
| `doc-gaia-init-isolation.bats`    | Doc-conformance for the `/gaia-init` Step 9 isolation-policy question (`.claude/commands/gaia-init.md`), the first-adopter entry point. The `AskUserQuestion` block and the conditional `--isolation-policy` flag passed to `gaia init configure-automation`, omitted entirely on a non-response so the `/setup-gaia` Phase 3.5 clause stays reachable for every new project.                                                                                        |

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
