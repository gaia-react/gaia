/**
 * The test-side vocabulary of git's background auto-maintenance.
 *
 * Test-only. Two guards prove the suppression works, the run-wide one in
 * `git-maintenance-env.test.ts` and the repository-local one in
 * `wiki/commit-classify.test.ts`. Each builds a control repository that
 * deliberately leaves maintenance switched on, so both need the same answers to
 * "which keys are the gates", "what are git's own defaults for them", and "what
 * did git actually spawn". They live here so the two cannot drift into
 * disagreeing.
 */
import {existsSync, readFileSync} from 'node:fs';

/**
 * The gates, paired with the value that explicitly turns each one off.
 *
 * A control repository cannot establish "ungated" by leaving these out.
 * Repo-local config beats global, so a sandbox that sets them is immune to
 * whatever the machine's own `~/.gitconfig` says, but a control that merely
 * omits them inherits it, and `gc.auto = 0` is a common thing to carry in a
 * personal dotfile. The control would then spawn nothing and the arm asserting
 * git still spawns maintenance would fail against a fixture behaving perfectly.
 * Writing git's own defaults into the control makes its condition its own.
 *
 * Measured on git 2.55: `maintenance.auto` is the entry that decides here, and
 * an explicit `maintenance.auto = true` spawns a run even alongside
 * `gc.auto = 0`, which is what makes a control carrying both genuinely ungated.
 * `gc.auto` is not dead weight; it is what leaves a control ungated on git
 * predating the maintenance task set, where it is the only spelling. It is also
 * why mutating this entry on its own cannot red either guard on 2.55, the
 * sibling still forces the spawn, while mutating `maintenance.auto` reds both.
 */
export const MAINTENANCE_GATE_DEFAULTS: [string, string][] = [
  ['gc.auto', '6700'],
  ['maintenance.auto', 'true'],
];

/**
 * Just the keys, for subtracting the gates from a suppression list.
 *
 * Named beside the list it subtracts from so the two cannot drift into
 * disagreeing about which entries are the gates.
 */
export const MAINTENANCE_GATES = new Set(
  MAINTENANCE_GATE_DEFAULTS.map(([key]) => key)
);

/**
 * Every auto-maintenance child process git's own trace recorded.
 *
 * `GIT_TRACE2_EVENT` writes a `child_start` event, carrying the child's argv,
 * into the trace of the process that spawned it, so a run detached with
 * `--detach` is still visible without waiting on it or racing its exit. An
 * absent file means git spawned nothing and so wrote nothing.
 *
 * Both spellings count, because the spelling depends on the git that runs it:
 * modern git spawns `git maintenance run --auto`, and git predating that task
 * set reaches the repository through `git gc --auto` instead. Both suppression
 * lists name a key for each, so a filter matching only the first would assert
 * nothing on exactly the git the other key exists for.
 */
export const autoMaintenanceSpawns = (tracePath: string): string[] =>
  (existsSync(tracePath) ? readFileSync(tracePath, 'utf8') : '')
    .split('\n')
    .filter(
      (line) =>
        line.includes('"child_start"') &&
        (line.includes('"maintenance"') || line.includes('"gc"'))
    );

/**
 * The subset of those spawns that git detached.
 *
 * A control repository leaves the gates off on purpose, so it spawns a
 * maintenance run and the test that built it must show that run stayed in the
 * foreground; a detached one outlives the test into the `rmSync` that deletes
 * the repository out from under it. Returning the offending lines rather than a
 * boolean is what puts the argv in the failure message.
 */
export const detachedSpawns = (spawns: string[]): string[] =>
  spawns.filter((line) => line.includes('"--detach"'));
