/**
 * Suppress git's background auto-maintenance for every git subprocess this
 * vitest run spawns.
 *
 * Wired as the `setupFiles` entry in `.gaia/cli/vitest.config.ts`, so nothing
 * imports it; vitest evaluates it once per test file, before that file's own
 * imports. `git-maintenance-env.test.ts` is what proves it reaches git.
 *
 * ## Why this is run-wide rather than per-fixture
 *
 * `#1216` established the hazard: a sandbox built by `mkdtempSync` + `git init`
 * + a run of `git commit`s is exposed to git's own maintenance, because every
 * `git commit` spawns `git maintenance run --auto --quiet --detach` unless the
 * repository gates it. A detached run has two ways to hurt a suite. It repacks
 * the object store while the next `git commit` is still running, which is what
 * corrupted HEAD in `#1216`, and it outlives the test into an `afterEach` that
 * `rmSync`s the repository out from under it.
 *
 * Files under `src/` build such a sandbox and commit into it, and only
 * `wiki/commit-classify.test.ts` gates it in its own config. That is the
 * argument for the environment rather than for a shared fixture every sandbox
 * has to remember to call: `GIT_CONFIG_*` reaches every git subprocess in the
 * run regardless of `cwd`, so a sandbox added later inherits the suppression
 * without opting in, and the hand-written list of which files need it, which
 * has already been drawn once and come out short, stops being load-bearing.
 *
 * ## Why these four keys
 *
 * The spelling that gates this moved when `git maintenance` replaced
 * `git gc --auto`, and the git a run gets is whatever the machine or the CI
 * runner supplies:
 *
 * - `maintenance.auto=false` is the documented gate on the spawn, covering the
 *   whole task set including `loose-objects` and `incremental-repack`, the two
 *   that pack.
 * - `gc.auto=0` is the gate for git predating that task set, which reaches the
 *   repository through `git gc --auto` instead.
 * - `gc.autoDetach=false` and `maintenance.autoDetach=false` are the fallback
 *   for both. Neither is a gate; they matter only for a run that starts anyway,
 *   which then finishes before the command that triggered it returns and so can
 *   neither outlive the test nor race the next `git commit`. Both spellings,
 *   because modern git resolves `maintenance.autoDetach` ahead of
 *   `gc.autoDetach`.
 *
 * ## What this deliberately does not do
 *
 * It sets no identity or signing config. A sandbox still owns those, and a
 * suite testing what git does without them keeps working.
 *
 * It is also not in `execGaiaGit` (`git-env.ts`), which is production code the
 * shipped CLI runs against adopters' real repositories; suppressing maintenance
 * there would disable auto-gc in every checkout GAIA touches. The seam is
 * test-side, which is what makes an environment variable set by a test-run
 * setup file the right altitude.
 *
 * ## Opting out
 *
 * `GIT_CONFIG_COUNT` set to `0` for the duration of a call restores git's own
 * resolution, which a test proving the suppression works needs and nothing else
 * should. `wiki/commit-classify.test.ts`'s control repository is the one such
 * caller: an environment entry outranks repo-local config, the same way
 * `git -c` does, so a repository that writes the gates at git's defaults still
 * inherits the suppression from here.
 *
 * ## Ambient `GIT_CONFIG_*` is overwritten, not appended to
 *
 * Stated as a tradeoff rather than left to be inferred from the code. The
 * assignment below forces the count and writes slots 0-3, so an entry the
 * environment already supplied is dropped for this run. The case that would
 * bite is a containerized runner exporting `safe.directory` this way: every git
 * command in the suite would then fail on ownership. Nothing in this repository
 * or its CI sets `GIT_CONFIG_*`, and the failure would be loud rather than a
 * silent behaviour change.
 *
 * Appending at the ambient count is the alternative and it does work. It does
 * not compound across the suite, because vitest evaluates a setup file once per
 * test file in a **fresh process** (measured: three test files, three pids,
 * each seeing its own first run), so `process.env` never carries an earlier
 * file's count forward. It is declined here as machinery for a condition this
 * repository does not produce, and taking it would also mean the two opt-out
 * call sites restoring an ambient count rather than the literal `0` they can
 * hard-code today.
 */
const MAINTENANCE_SUPPRESSION: [string, string][] = [
  ['gc.auto', '0'],
  ['maintenance.auto', 'false'],
  ['gc.autoDetach', 'false'],
  ['maintenance.autoDetach', 'false'],
];

process.env.GIT_CONFIG_COUNT = String(MAINTENANCE_SUPPRESSION.length);

MAINTENANCE_SUPPRESSION.forEach(([key, value], index) => {
  process.env[`GIT_CONFIG_KEY_${index}`] = key;
  process.env[`GIT_CONFIG_VALUE_${index}`] = value;
});
