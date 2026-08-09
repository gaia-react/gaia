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
 * Nineteen files under `src/` build such a sandbox and commit into it, and only
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
 * The assignment below overwrites an ambient `GIT_CONFIG_*` rather than
 * appending to it, which is deliberate: the run owns its own git configuration,
 * and appending would make which slots this file writes depend on what the
 * calling shell happened to set.
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
