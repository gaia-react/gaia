# Distribution tests

Maintainer-only validation of the post-scrub GAIA tarball. Excluded from the release bundle via category 3 (`.gaia/tests/`). Audience is the machine; every scenario reports PASS/FAIL with a deterministic exit code.

## When to run

- Before cutting a GAIA release (`/gaia-release`).
- When modifying any file that shapes the staged tarball:
  - `.gaia/release-scrub.yml`
  - `.gaia/release-exclude`
  - `.github/workflows/release.yml`
  - `.gaia/manifest.ts`
- Automatically: the pre-push hook runs `01-files-present`, the build-staging leak check and `03-marker-strip` on every branch push, and the verification runner's branch and round modes (`bash .gaia/tests/verify-harness.sh`) run them too.

## Layout

`run-all.sh` is the driver, `lib/` holds its helpers, and each numbered `*.sh` at the root is one scenario whose header comment states what it asserts. `fixtures/` holds files a scenario copies into its staged tree; each fixture folder's README says which scenario uses it.

## Running

```bash
bash .gaia/tests/distribution/run-all.sh
```

Walks `*.sh` (excluding `run-all.sh` and anything under `lib/`) in lexicographic order, each scenario's output captured to a log. Scenarios run in two phases: first every scenario concurrently, up to `DISTRIBUTION_JOBS` at a time (the host's CPU count by default; `1` runs them serially), then each scenario whose header carries the line `# distribution-runner: exclusive`, one at a time with the host to itself. It prints a progress line as each scenario finishes, then every log in scenario order, then the PASS/FAIL summary, and exits non-zero on any failure.

Mark a scenario exclusive when it runs the scaffold's own test suite: Vitest already uses every core, and its per-test timeouts fail under a second suite or the concurrent phase running beside it. A scenario that only installs or runs the CLI stays concurrent. Scenarios share no state beyond the pnpm store and the Playwright browser cache, both safe under concurrent installs, so a new scenario keeps its scratch files in its own `mktemp` directories.

Individual scenarios are runnable directly:

```bash
bash .gaia/tests/distribution/01-files-present.sh
```

## Prerequisites

- An executable `.gaia/cli/gaia-maintainer` binary: every scenario builds its staging tree through `build-staging.sh`, which refuses without it.
- `.gaia/cli/gaia` binary built and present; the adopter-flow scenarios shell out to it directly, not to `pnpm -C .gaia/cli`.
- Host has `git`, `tar`, `rsync`, `pnpm` on PATH (Layer 0).

## Layered isolation

Layer 0; host pnpm available, scenarios run with the maintainer's PATH (default). Layer 1; PATH-stripped subshell (`05-clean-env.sh`) verifies the bootstrapper extracts cleanly with only `/usr/bin:/bin`. Adopter-flow regressions (`07-`+) run on the host or runner without Docker and exercise the bundled CLI against a writable copy of the staged tree.

### Layer 1: clean-env bootstrap (`05-clean-env.sh`)

Covers tarball extraction and the corepack-driven pnpm bootstrap inside a PATH-stripped subshell with an isolated `$HOME`. Reuses `lib/build-staging.sh` to produce a release-shape tree, tars it, and extracts into a scratch scaffold; the same shape `create-gaia` runs on an adopter's machine. The subshell's PATH is reduced to `/usr/bin:/bin` plus symlinks to the outer `node`/`corepack`/`tar`/`git`, so any maintainer-local `pnpm`/`uv`/`claude` becomes invisible. The scenario asserts pnpm is _not_ visible before bootstrap, then exercises `corepack enable pnpm` followed by `pnpm install --frozen-lockfile`.

Does not cover `/gaia-init` or `/setup-gaia` execution (no Claude in the subshell), full filesystem isolation (a true Docker run is the answer), or non-host operating systems. The `npm install -g pnpm` fallback path inside `create-gaia`'s `ensurePnpm()` is intentionally untested here; exercising it would mutate the host's global npm state with no clean rollback.

Skips automatically if `corepack` is not on the host PATH (Node 16.13+ ships corepack, so this is rare). Skip is reported as a soft PASS so `run-all.sh` summaries stay green on hosts where the layer cannot run. Setting `GAIA_DISTRIBUTION_REQUIRE_COREPACK=1` turns the skip into a failure; `release.yml` sets it on the distribution gate step, so a release run counts this scenario only when the install executed. A run that installed prints a PASS line containing `frozen install ran`, while the skip's PASS line contains `skipped`. When the install fails, the last 40 lines of pnpm's output are printed to stderr under a `FAIL` line.

### Adopter-flow regressions (`07-`+)

Layers 0+1 prove the release tree stages and bootstraps cleanly, but do NOT prove any GAIA-specific flow works in the shipped tarball. Adopter-flow scenarios fill that gap by running the bundled `.gaia/cli/gaia` binary directly against a writable copy of the staged tree.

`07-gaia-init-strip-branding.sh` runs `gaia init strip-branding --title "Test Project"` and asserts two post-conditions: `README.md` is regenerated from `.gaia/templates/README.md` with the title substituted, and the subcommand exits 0 with no stdout per its contract. Catches the failure mode where `release-exclude` accidentally strips a file the subcommand needs (template source); Layers 0+1 stay green; only this scenario fails.

`08-gaia-init-cli-sequence.sh` runs the full deterministic sequence behind `/gaia-init` Step 3; `strip-branding` → `configure-i18n --strip false` → `rename` → `wire-statusline --mode project` → `finalize`; and asserts each step's post-conditions on the staged tree. Catches release-exclude drift on every CLI surface the slash command dispatches to: the `existsSync` guards in `configure-i18n`/`rename`/`finalize` mean a missing target file silently no-ops rather than erroring, so this scenario is the gate that turns a no-op into a failure. `--mode project` for `wire-statusline` keeps the merge inside the scaffold's `.claude/settings.json` and never writes to the host's `~/.claude`. The `configure-i18n --strip true` path (full i18n removal via the prose `remove-i18n.md` instruction) is out of scope here; that path is orchestrated by the slash command, not the CLI alone.

#### CI

CI entry points:

- **PR gate inside `cli-tests.yml` (`Distribution harness (no-Docker) (advisory)` job).** Runs `bash .gaia/tests/distribution/run-all.sh` on every `pull_request`, path-filtered to `.gaia/cli/**`, `.gaia/release-exclude`, `.gaia/release-scrub.yml`, and the harness itself. That filter stays narrow because the scenario suite is the expensive part of the job, and the narrowness is backstopped rather than merely tolerated: the two checks it can skip whose real input is the whole shipped surface, the leak check and the marker-strip scenario, both run unfiltered in the sibling job below. The required lane is Layers 0+1 plus the adopter-flow regressions (`07`+) and the deterministic marker-strip survival check. This catches a bundle-breaking change (a leak, a marker-strip regression, manifest drift) at PR review instead of only at release. The job always runs and reports green when the filter does not match, so it is branch-protection-safe; it is deliberately NOT a declared-required context (see `.gaia/scripts/verify-required-checks.sh`). Its sibling `Vitest (.gaia/cli)` job shares the always-reports shape but IS declared-required, because its reproducibility step is the only gate on the committed CLI bundles.
- **PR gate inside `cli-tests.yml` (`Shipped-surface leak check (advisory)` job).** Runs `bash .gaia/tests/distribution/lib/build-staging.sh` (the stage, wiki-sentinel reset, scrub leak check, and runtime-dependency phases), then `03-marker-strip.sh`, which builds its own staging tree and asserts the strip left no surviving fragment. About fifteen seconds of work. The marker-strip scenario runs here as well as in the harness job above, and this is the copy that gates: every file its assertions read (`.claude/hooks/lib/*.sh`, `.gaia/scripts/*.sh`, `.gaia/statusline/gaia-statusline.sh`, `.gaia/audit-ci.yml`, `.prettierignore`) sits outside the harness job's filter, so a PR adding a `# gaia:maintainer-only:` block to one of them skipped the harness entirely and first met the assertion at `release.yml`. It carries no paths-filter at all, deliberately. `build-staging.sh` reads every tracked file `.gaia/release-exclude` does not withhold, so the only allowlist that describes its inputs honestly is `'**'`, which gates nothing while still costing a filter step and a `pull-requests: read` round trip, and the complement is a denylist shape both `.gaia/release-scrub.yml`'s `workflow-denylist` check and `.gaia/scripts/tests/workflow-filter-coverage.bats` reject. Running unfiltered is what makes a leak in any shipped file fail at PR review rather than at tag push in `release.yml`. Advisory and deliberately NOT a declared-required context, with `contents: read` as its whole permission set; it admits `workflow_dispatch` so an audit self-heal re-dispatch stamps a real conclusion instead of a bare `skipped`.
- **Pre-publish gate inside `release.yml`.** The tag-triggered release workflow runs `bash .gaia/tests/distribution/run-all.sh` after the staging + scrub + runtime-deps phases and before the tarball is built. If any scenario fails the release halts; the tarball never builds and `gh release create` never runs, so a broken release cannot publish. This is the production gate.

Ad-hoc verification of harness changes on a feature branch (no tag) runs `bash .gaia/tests/distribution/run-all.sh` locally; there is no dedicated CI entry point for it.

## See also

- `wiki/concepts/Release Workflow.md`; what the staged tarball is and how it's built.
