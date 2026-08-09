/**
 * The run-wide git auto-maintenance suppression, proved against git itself.
 *
 * `git-maintenance-env.ts` is a vitest `setupFiles` entry, so nothing imports
 * it and no assertion about its exports would show that it reached a git
 * subprocess. This asserts the effect instead: a repository carrying git's own
 * defaults for both gates, committed into from inside this run, spawns no
 * maintenance.
 *
 * Two arms, because a bare "no maintenance was spawned" assertion passes just
 * as well when the trace recorded nothing at all. The control arm clears
 * `GIT_CONFIG_COUNT` and commits into an identically configured repository, so
 * a spawn there proves both that such a repository is genuinely ungated and
 * that the trace can see a spawn. What holds every other variable fixed is the
 * shared `beforeEach`, not a shared repository: each arm gets its own
 * `mkdtempSync` repo, built from the same list and deleted in `afterEach`. They
 * are deliberately not hoisted into a `beforeAll`, which would let the control
 * arm's own maintenance run touch the object store the subject arm measures.
 */
import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {mkdtempSync, rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {execGaiaGit} from './git-env.js';
import {
  autoMaintenanceSpawns,
  detachedSpawns,
  MAINTENANCE_GATE_DEFAULTS,
} from './git-maintenance.js';

/**
 * Enough config to commit, with the gates left at git's own defaults.
 *
 * `MAINTENANCE_GATE_DEFAULTS` carries the gates, so what makes this repository
 * ungated is stated once, in the module both maintenance guards read it from.
 *
 * `gc.autoDetach` and `maintenance.autoDetach` are not gates and are set here,
 * which keeps the control arm's own maintenance run a foreground child so it
 * cannot outlive the test into the `rmSync` in `afterEach`. Both spellings,
 * because modern git resolves `maintenance.autoDetach` ahead of `gc.autoDetach`.
 */
const UNGATED_CONFIG: [string, string][] = [
  ['user.email', 'test@example.com'],
  ['user.name', 'Test'],
  ['commit.gpgsign', 'false'],
  ['gc.autoDetach', 'false'],
  ['maintenance.autoDetach', 'false'],
  ...MAINTENANCE_GATE_DEFAULTS,
];

describe('run-wide git maintenance suppression', () => {
  let root: string;
  let traceRoot: string;

  beforeEach(() => {
    root = mkdtempSync(path.join(tmpdir(), 'gaia-git-maint-'));
    traceRoot = mkdtempSync(path.join(tmpdir(), 'gaia-git-maint-trace-'));
    execGaiaGit(['init', '-q', '-b', 'main'], root);

    for (const [key, value] of UNGATED_CONFIG) {
      execGaiaGit(['config', key, value], root);
    }
  });

  afterEach(() => {
    vi.unstubAllEnvs();
    rmSync(root, {force: true, recursive: true});
    rmSync(traceRoot, {force: true, recursive: true});
  });

  const commitTraced = (traceName: string, message: string): string[] => {
    const tracePath = path.join(traceRoot, traceName);
    vi.stubEnv('GIT_TRACE2_EVENT', tracePath);
    execGaiaGit(['commit', '-q', '--allow-empty', '-m', message], root);

    return autoMaintenanceSpawns(tracePath);
  };

  test('a repository at git defaults spawns maintenance without the run env', () => {
    vi.stubEnv('GIT_CONFIG_COUNT', '0');
    const spawns = commitTraced('control.json', 'control baseline');

    expect(spawns.length).toBeGreaterThan(0);
    // The control's own run must stay in the foreground, or `afterEach` deletes
    // the repository out from under a live background git. A count alone cannot
    // see that: the parent records the child either way, so this arm would pass
    // green while leaking the orphan the suppression exists to prevent.
    expect(detachedSpawns(spawns)).toEqual([]);
  });

  test('the run env suppresses maintenance in that same repository', () => {
    expect(commitTraced('subject.json', 'subject baseline')).toEqual([]);
  });
});
