/**
 * Strategy: every case runs against `planSync` and its pure companions
 * (`mutationFor`, `resolveBlocked`, `classifyGhResult`), never against `gh`.
 * `run`'s only additions over those four are argv parsing and printing.
 */
import {describe, expect, test} from 'vitest';
import type {LabelAudience, LabelFeature} from '../../schemas/labels.js';
import {resolveRepoRootFromImportMeta} from '../../util/repo-root-fixture.js';
import {readRegistry} from '../registry.js';
import type {LiveLabel, SyncAction, SyncFlags} from '../sync.js';
import {
  classifyGhResult,
  mutationFor,
  planSync,
  resolveBlocked,
} from '../sync.js';

const repoRoot = resolveRepoRootFromImportMeta(import.meta.url);
const registry = readRegistry(repoRoot);

const ALL_FEATURES: LabelFeature[] = ['tech-debt', 'gaia-ci', 'forensics'];

const AUDIENCES: LabelAudience[] = ['adopter', 'maintainer'];

const NO_FLAGS: SyncFlags = {
  adopt: false,
  adoptPalette: false,
  enforceBlocked: false,
  pruneDeprecated: false,
};

const entryFor = (name: string): LiveLabel => {
  const entry = registry.labels.find((candidate) => candidate.name === name);

  if (entry === undefined) throw new Error(`no registry entry: ${name}`);

  return {
    color: entry.color ?? '',
    description: entry.description,
    name: entry.name,
  };
};

const plan = (options: {
  audience?: LabelAudience;
  features?: LabelFeature[];
  flags?: Partial<SyncFlags>;
  live?: LiveLabel[];
}): readonly SyncAction[] =>
  planSync({
    audience: options.audience ?? 'adopter',
    enabledFeatures: options.features ?? ALL_FEATURES,
    flags: {...NO_FLAGS, ...options.flags},
    live: options.live ?? [],
    registry,
  }).actions;

const kinds = (
  actions: readonly SyncAction[],
  kind: SyncAction['kind']
): SyncAction[] => actions.filter((action) => action.kind === kind);

/** The one action of `kind` in `actions`, or a failure naming the count. */
const sole = (
  actions: readonly SyncAction[],
  kind: SyncAction['kind']
): SyncAction => {
  const matching = kinds(actions, kind);
  const [first] = matching;

  if (first === undefined || matching.length !== 1) {
    throw new Error(`expected one ${kind} action, got ${matching.length}`);
  }

  return first;
};

const createNames = (actions: readonly SyncAction[]): string[] =>
  actions
    .flatMap((action) => (action.kind === 'create' ? [action.entry.name] : []))
    .toSorted((a, b) => a.localeCompare(b));

const FLAG_COMBINATIONS: SyncFlags[] = [
  NO_FLAGS,
  {...NO_FLAGS, adopt: true},
  {...NO_FLAGS, adoptPalette: true},
  {...NO_FLAGS, enforceBlocked: true},
  {...NO_FLAGS, pruneDeprecated: true},
  {
    adopt: true,
    adoptPalette: true,
    enforceBlocked: true,
    pruneDeprecated: true,
  },
];

describe('labels/sync planSync create sets', () => {
  test('an empty adopter repo with every feature on', () => {
    expect(createNames(plan({}))).toEqual([
      'bug',
      'debt:in-progress',
      'debt:spec-pending',
      'difficulty:easy',
      'difficulty:hard',
      'difficulty:medium',
      'enhancement',
      'fold:required',
      'gaia-ci',
      'handler:plan',
      'handler:prompt',
      'handler:spec',
      'needs-human',
      'run-audit',
      'security',
      'severity:critical',
      'severity:important',
      'severity:suggestion',
      'tech-debt',
      'wontfix',
    ]);
  });

  test('GAIA CI off drops the two labels its workflows own', () => {
    const names = createNames(plan({features: ['tech-debt', 'forensics']}));

    expect(names).not.toContain('gaia-ci');
    expect(names).not.toContain('security');
    expect(names).toHaveLength(18);
  });

  test('tech-debt off leaves the always-on set plus the GAIA CI set', () => {
    expect(createNames(plan({features: ['gaia-ci', 'forensics']}))).toEqual([
      'bug',
      'enhancement',
      'gaia-ci',
      'needs-human',
      'run-audit',
      'security',
      'severity:critical',
      'severity:important',
      'wontfix',
    ]);
  });

  test('the maintainer audience creates the adopter set as well as its own', () => {
    expect(createNames(plan({audience: 'maintainer'}))).toEqual([
      'auto-fixable',
      'bug',
      'debt:in-progress',
      'debt:spec-pending',
      'difficulty:easy',
      'difficulty:hard',
      'difficulty:medium',
      'enhancement',
      'fold:required',
      'gaia-ci',
      'gaia-forensics',
      'gaia-triaged',
      'handler:plan',
      'handler:prompt',
      'handler:spec',
      'needs-human',
      'non-issue',
      'run-audit',
      'security',
      'severity:critical',
      'severity:important',
      'severity:suggestion',
      'surface:adopter',
      'surface:maintainer',
      'tech-debt',
      'wontfix',
    ]);
  });

  test('the maintainer audience with tech-debt off drops the surface axis', () => {
    const names = createNames(
      plan({audience: 'maintainer', features: ['gaia-ci', 'forensics']})
    );

    expect(names).toEqual([
      'auto-fixable',
      'bug',
      'enhancement',
      'gaia-ci',
      'gaia-forensics',
      'gaia-triaged',
      'needs-human',
      'non-issue',
      'run-audit',
      'security',
      'severity:critical',
      'severity:important',
      'wontfix',
    ]);
  });
});

describe('labels/sync planSync rename', () => {
  test('an old name present and the new name absent plans one rename', () => {
    const actions = plan({
      live: [{color: 'd93f0b', description: '', name: 'needs-human-review'}],
    });
    const renames = kinds(actions, 'rename');

    expect(renames).toEqual([
      {from: 'needs-human-review', kind: 'rename', to: 'needs-human'},
    ]);
    expect(createNames(actions)).not.toContain('needs-human');
    expect(kinds(actions, 'prune')).toEqual([]);
    expect(kinds(actions, 'blocked-removed')).toEqual([]);
    expect(kinds(actions, 'unknown')).toEqual([]);
  });

  test('a maintainer tree renames an adopter entry rather than creating it', () => {
    // The maintainer audience is a superset for creation, so an adopter entry
    // reaches a maintainer tree's plan. The rename guard has to agree: if it
    // still tested audiences for equality, the old name would fall through to
    // the create branch, the live label would survive unclaimed, and the
    // rename-never-delete-and-recreate invariant would be lost for it.
    const actions = plan({
      audience: 'maintainer',
      live: [{color: 'd93f0b', description: '', name: 'needs-human-review'}],
    });

    expect(kinds(actions, 'rename')).toEqual([
      {from: 'needs-human-review', kind: 'rename', to: 'needs-human'},
    ]);
    expect(createNames(actions)).not.toContain('needs-human');
    expect(kinds(actions, 'unknown')).toEqual([]);
  });

  test('the rename never becomes a delete plus a create', () => {
    const actions = plan({
      live: [{color: 'd93f0b', description: '', name: 'needs-human-review'}],
    });

    for (const action of actions) {
      for (const flags of FLAG_COMBINATIONS) {
        expect(mutationFor(action, flags)?.[1]).not.toBe('delete');
      }
    }
  });

  test('a rename edits the old name rather than recreating it', () => {
    expect(
      mutationFor(
        {from: 'needs-human-review', kind: 'rename', to: 'needs-human'},
        NO_FLAGS
      )
    ).toEqual(['label', 'edit', 'needs-human-review', '--name', 'needs-human']);
  });
});

describe('labels/sync planSync deletes', () => {
  test('no plan yields a delete without --prune-deprecated', () => {
    const actions = plan({
      audience: 'maintainer',
      live: [entryFor('debt:pre-provenance')],
    });

    const prune = sole(actions, 'prune');

    expect(mutationFor(prune, NO_FLAGS)).toBeNull();
    expect(mutationFor(prune, {...NO_FLAGS, pruneDeprecated: true})).toEqual([
      'label',
      'delete',
      'debt:pre-provenance',
      '--yes',
    ]);
  });

  test('the deprecated, unmanaged entry is never created', () => {
    for (const audience of AUDIENCES) {
      for (const flags of FLAG_COMBINATIONS) {
        expect(createNames(plan({audience, flags}))).not.toContain(
          'debt:pre-provenance'
        );
      }
    }
  });

  test('a blocked entry is never created, on either audience', () => {
    for (const audience of AUDIENCES) {
      for (const flags of FLAG_COMBINATIONS) {
        const names = createNames(plan({audience, flags}));

        expect(names).not.toContain('good first issue');
        expect(names).not.toContain('help wanted');
      }
    }
  });
});

describe('labels/sync blocked entries', () => {
  const blockedLive: LiveLabel[] = [
    {
      color: '7057ff',
      description: 'Good for newcomers',
      name: 'good first issue',
    },
  ];

  test('a blocked label present plans blocked-present with its reason', () => {
    const actions = plan({flags: {enforceBlocked: true}, live: blockedLive});

    expect(sole(actions, 'blocked-present')).toMatchObject({
      carrierCount: null,
      countUnavailable: false,
      name: 'good first issue',
    });
  });

  test('an adopter repo never removes a blocked label, whatever the flags', () => {
    for (const flags of FLAG_COMBINATIONS) {
      const actions = plan({flags, live: blockedLive});

      expect(kinds(actions, 'blocked-removed')).toEqual([]);
    }
  });

  test('the adopter audience keeps the advisory even under enforcement', () => {
    const action: SyncAction = {
      carrierCount: null,
      countUnavailable: false,
      kind: 'blocked-present',
      name: 'good first issue',
      reason: 'policy',
    };

    expect(
      resolveBlocked(action, {
        audience: 'adopter',
        carrierCount: 0,
        flags: {...NO_FLAGS, enforceBlocked: true},
      })
    ).toBe(action);
  });

  test('the maintainer audience removes it only at a zero carrier count', () => {
    const action: SyncAction = {
      carrierCount: null,
      countUnavailable: false,
      kind: 'blocked-present',
      name: 'good first issue',
      reason: 'policy',
    };
    const flags: SyncFlags = {...NO_FLAGS, enforceBlocked: true};

    expect(
      resolveBlocked(action, {audience: 'maintainer', carrierCount: 0, flags})
    ).toEqual({kind: 'blocked-removed', name: 'good first issue'});

    expect(
      resolveBlocked(action, {audience: 'maintainer', carrierCount: 4, flags})
    ).toEqual({...action, carrierCount: 4});
  });

  test('enforcement without the flag leaves the advisory alone', () => {
    const action: SyncAction = {
      carrierCount: null,
      countUnavailable: false,
      kind: 'blocked-present',
      name: 'help wanted',
      reason: 'policy',
    };

    expect(
      resolveBlocked(action, {
        audience: 'maintainer',
        carrierCount: 0,
        flags: NO_FLAGS,
      })
    ).toBe(action);
  });
});

const drifted = (overrides: Partial<LiveLabel>): LiveLabel => ({
  ...entryFor('tech-debt'),
  ...overrides,
});

describe('labels/sync drift', () => {
  test('color drift reports and writes only under --adopt', () => {
    const actions = plan({live: [drifted({color: '000000'})]});
    const action = sole(actions, 'drift-color');

    expect(action).toMatchObject({name: 'tech-debt', registryColor: 'ededed'});
    expect(mutationFor(action, NO_FLAGS)).toBeNull();
    expect(mutationFor(action, {...NO_FLAGS, adopt: true})).toEqual([
      'label',
      'edit',
      'tech-debt',
      '--color',
      'ededed',
    ]);
  });

  test('an uppercase live color is not drift', () => {
    expect(
      kinds(plan({live: [drifted({color: 'EDEDED'})]}), 'drift-color')
    ).toEqual([]);
  });

  test('description drift writes with no flag at all', () => {
    const actions = plan({live: [drifted({description: 'stale'})]});
    const action = sole(actions, 'drift-description');

    expect(mutationFor(action, NO_FLAGS)).toEqual([
      'label',
      'edit',
      'tech-debt',
      '--description',
      'Out-of-scope review finding, tracked for a later drain',
    ]);
  });

  test('an unmanaged entry reconciles its description but not its color', () => {
    const live: LiveLabel = {
      color: '000000',
      description: 'stale',
      name: 'dependencies',
    };
    const actions = plan({live: [live]});

    expect(kinds(actions, 'drift-color')).toEqual([]);
    expect(kinds(actions, 'drift-description')).toHaveLength(1);
  });
});

describe('labels/sync unknown live labels', () => {
  test('a namespaced unknown carries its family color as a suggestion', () => {
    const actions = plan({
      live: [{color: '111111', description: '', name: 'severity:made-up'}],
    });

    expect(kinds(actions, 'unknown')).toEqual([
      {kind: 'unknown', name: 'severity:made-up', suggestedColor: 'b60205'},
    ]);
  });

  test('--adopt-palette turns the suggestion into a write', () => {
    const action: SyncAction = {
      kind: 'unknown',
      name: 'severity:made-up',
      suggestedColor: 'b60205',
    };

    expect(mutationFor(action, NO_FLAGS)).toBeNull();
    expect(mutationFor(action, {...NO_FLAGS, adoptPalette: true})).toEqual([
      'label',
      'edit',
      'severity:made-up',
      '--color',
      'b60205',
    ]);
  });

  test('an unknown outside every namespace is reported and never written', () => {
    const actions = plan({
      live: [{color: '111111', description: '', name: 'project-only'}],
    });

    expect(kinds(actions, 'unknown')).toEqual([
      {kind: 'unknown', name: 'project-only', suggestedColor: null},
    ]);
    expect(
      mutationFor(sole(actions, 'unknown'), {...NO_FLAGS, adoptPalette: true})
    ).toBeNull();
  });
});

describe('labels/sync gh outcome classification', () => {
  test('a zero exit is success', () => {
    expect(classifyGhResult({exitCode: 0, stderr: '', stdout: ''})).toBe('ok');
  });

  test('an HTTP 403 degrades rather than failing', () => {
    expect(
      classifyGhResult({
        exitCode: 1,
        stderr: 'HTTP 403: Resource not accessible by integration',
        stdout: '',
      })
    ).toBe('degraded');
  });

  test('any other non-zero exit stays a real failure', () => {
    expect(
      classifyGhResult({
        exitCode: 1,
        stderr: 'HTTP 404: Not Found',
        stdout: '',
      })
    ).toBe('failed');
  });

  test('a degraded mutation still names the exact manual command', () => {
    const action: SyncAction = {
      entry: {
        audience: 'adopter',
        axis: 'type',
        blocked: false,
        color: 'ededed',
        deprecated: false,
        description: 'Out-of-scope review finding, tracked for a later drain',
        features: ['tech-debt'],
        managed: true,
        name: 'tech-debt',
        reason: null,
        renamedFrom: [],
      },
      kind: 'create',
    };

    expect(mutationFor(action, NO_FLAGS)).toEqual([
      'label',
      'create',
      'tech-debt',
      '--color',
      'ededed',
      '--description',
      'Out-of-scope review finding, tracked for a later drain',
    ]);
  });
});
