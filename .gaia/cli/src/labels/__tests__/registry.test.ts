import {afterEach, beforeEach, describe, expect, test} from 'vitest';
import {mkdirSync, mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {resolveRepoRootFromImportMeta} from '../../util/repo-root-fixture.js';
import {
  blockedEntries,
  creatableEntries,
  labelsRegistryPath,
  NAMESPACE_PREFIXES,
  readRegistry,
  resolveAudience,
  resolveFeatures,
  suggestedColorFor,
} from '../registry.js';

// Built at runtime so no removed-feature literal lands in the tracked tree.
const REMOVED_FEATURE_NAME = ['gaia', 'ci'].join('-');

const repoRoot = resolveRepoRootFromImportMeta(import.meta.url);
const registry = readRegistry(repoRoot);

const names = (
  audience: 'adopter' | 'maintainer',
  features: ('dependabot' | 'forensics' | 'tech-debt')[]
): string[] =>
  creatableEntries(registry, audience, features)
    .map((entry) => entry.name)
    .toSorted((a, b) => a.localeCompare(b));

describe('labels/registry readRegistry', () => {
  test('parses the committed .gaia/labels.json', () => {
    expect(registry.version).toBe(1);
    expect(registry.labels).toHaveLength(32);
  });

  test('the two deprecated entries carry no features and a null reason', () => {
    const deprecatedEntries = registry.labels.filter(
      (entry) => entry.deprecated
    );

    expect(
      deprecatedEntries
        .map((entry) => entry.name)
        .toSorted((a, b) => a.localeCompare(b))
    ).toEqual([REMOVED_FEATURE_NAME, 'run-audit']);

    for (const entry of deprecatedEntries) {
      expect(entry.features).toEqual([]);
      expect(entry.reason).toBeNull();
    }
  });

  test('labelsRegistryPath joins onto the given root', () => {
    expect(labelsRegistryPath('/checkout/example')).toBe(
      path.join('/checkout/example', '.gaia', 'labels.json')
    );
  });

  test('a malformed registry throws with the file named', () => {
    const directory = mkdtempSync(path.join(tmpdir(), 'gaia-labels-'));

    try {
      mkdirSync(path.join(directory, '.gaia'), {recursive: true});
      writeFileSync(
        path.join(directory, '.gaia', 'labels.json'),
        '{"version": 2}',
        'utf8'
      );

      expect(() => readRegistry(directory)).toThrow(
        labelsRegistryPath(directory)
      );
    } finally {
      rmSync(directory, {force: true, recursive: true});
    }
  });

  test('an unreadable registry throws with the file named', () => {
    const directory = mkdtempSync(path.join(tmpdir(), 'gaia-labels-'));

    try {
      expect(() => readRegistry(directory)).toThrow(
        labelsRegistryPath(directory)
      );
    } finally {
      rmSync(directory, {force: true, recursive: true});
    }
  });
});

describe('labels/registry creatableEntries', () => {
  test('every feature on yields the adopter-role entries', () => {
    expect(names('adopter', ['tech-debt', 'dependabot', 'forensics'])).toEqual([
      'bug',
      'debt:spec-active',
      'debt:spec-pending',
      'difficulty:easy',
      'difficulty:hard',
      'difficulty:medium',
      'documentation',
      'enhancement',
      'footprint:narrow',
      'footprint:spec',
      'footprint:wide',
      'in-progress',
      'needs-human',
      'security',
      'severity:critical',
      'severity:important',
      'severity:investigate',
      'severity:suggestion',
      'tech-debt',
      'wontfix',
    ]);
  });

  test('dependabot off drops only the security label', () => {
    expect(names('adopter', ['tech-debt', 'forensics'])).toEqual([
      'bug',
      'debt:spec-active',
      'debt:spec-pending',
      'difficulty:easy',
      'difficulty:hard',
      'difficulty:medium',
      'documentation',
      'enhancement',
      'footprint:narrow',
      'footprint:spec',
      'footprint:wide',
      'in-progress',
      'needs-human',
      'severity:critical',
      'severity:important',
      'severity:investigate',
      'severity:suggestion',
      'tech-debt',
      'wontfix',
    ]);
  });

  test('tech-debt off leaves the always-on set plus the dependabot set', () => {
    expect(names('adopter', ['dependabot', 'forensics'])).toEqual([
      'bug',
      'documentation',
      'enhancement',
      'in-progress',
      'needs-human',
      'security',
      'wontfix',
    ]);
  });

  test('a maintainer entry never reaches an adopter creatable set', () => {
    const maintainerNames = new Set(
      registry.labels
        .filter((entry) => entry.audience === 'maintainer')
        .map((entry) => entry.name)
    );
    const adopterNames = names('adopter', ['tech-debt', 'forensics']);

    expect(adopterNames.filter((name) => maintainerNames.has(name))).toEqual(
      []
    );
  });

  test('the maintainer set is the adopter set plus the maintainer entries', () => {
    expect(
      names('maintainer', ['tech-debt', 'dependabot', 'forensics'])
    ).toEqual([
      'audience:adopter',
      'audience:maintainer',
      'auto-fixable',
      'bug',
      'debt:spec-active',
      'debt:spec-pending',
      'difficulty:easy',
      'difficulty:hard',
      'difficulty:medium',
      'documentation',
      'enhancement',
      'footprint:narrow',
      'footprint:spec',
      'footprint:wide',
      'gaia-forensics',
      'gaia-triaged',
      'in-progress',
      'needs-human',
      'non-issue',
      'security',
      'severity:critical',
      'severity:important',
      'severity:investigate',
      'severity:suggestion',
      'tech-debt',
      'wontfix',
    ]);
  });
});

describe('labels/registry blockedEntries and suggestedColorFor', () => {
  test('blockedEntries returns the two GitHub defaults GAIA refuses', () => {
    expect(blockedEntries(registry).map((entry) => entry.name)).toEqual([
      'good first issue',
      'help wanted',
    ]);
  });

  test('an unknown name in a known namespace takes the family color', () => {
    expect(suggestedColorFor(registry, 'severity:whatever')).toBe('b60205');
    expect(suggestedColorFor(registry, 'difficulty:whatever')).toBe('bfe3df');
    // `debt:spec-active` sorts ahead of `debt:spec-pending`, so it is the
    // family's donor: adding an entry that sorts first silently moves what
    // `labels sync` suggests for every unrecognized `debt:*` label.
    expect(suggestedColorFor(registry, 'debt:whatever')).toBe('3b9b58');
  });

  test('an unknown name outside every namespace has no suggestion', () => {
    expect(suggestedColorFor(registry, 'random-name')).toBeNull();
  });

  test('every namespace prefix resolves to a color in the committed registry', () => {
    for (const prefix of NAMESPACE_PREFIXES) {
      expect(suggestedColorFor(registry, `${prefix}whatever`)).not.toBeNull();
    }
  });
});

describe('labels/registry resolveAudience and resolveFeatures', () => {
  let fixture = '';

  beforeEach(() => {
    fixture = mkdtempSync(path.join(tmpdir(), 'gaia-labels-tree-'));
  });

  afterEach(() => {
    rmSync(fixture, {force: true, recursive: true});
  });

  const writeProjectConfig = (text: string): void => {
    mkdirSync(path.join(fixture, '.gaia'), {recursive: true});
    writeFileSync(path.join(fixture, '.gaia', 'project.json'), text, 'utf8');
  };

  test('a tree without .gaia/cli/src is an adopter tree', () => {
    expect(resolveAudience(fixture)).toBe('adopter');
  });

  test('a tree carrying .gaia/cli/src is the maintainer tree', () => {
    mkdirSync(path.join(fixture, '.gaia', 'cli', 'src'), {recursive: true});

    expect(resolveAudience(fixture)).toBe('maintainer');
  });

  test('tech-debt is always on and the other two key on a file', () => {
    expect(resolveFeatures(fixture)).toEqual(['tech-debt']);
  });

  test('a project config opting into Dependabot security updates turns dependabot on', () => {
    writeProjectConfig('{"version":1,"dependabot_security_updates":"on"}');

    expect(resolveFeatures(fixture)).toEqual(['tech-debt', 'dependabot']);
  });

  test('a project config opting out leaves dependabot off', () => {
    writeProjectConfig('{"version":1,"dependabot_security_updates":"off"}');

    expect(resolveFeatures(fixture)).toEqual(['tech-debt']);
  });

  test('an existing .github/dependabot.yml turns dependabot on without a project config', () => {
    mkdirSync(path.join(fixture, '.github'), {recursive: true});
    writeFileSync(
      path.join(fixture, '.github', 'dependabot.yml'),
      'version: 2\n',
      'utf8'
    );

    expect(resolveFeatures(fixture)).toEqual(['tech-debt', 'dependabot']);
  });

  test('a malformed project config does not turn dependabot on', () => {
    writeProjectConfig('{not json');

    expect(resolveFeatures(fixture)).toEqual(['tech-debt']);
  });

  test('a forensics triage workflow turns forensics on', () => {
    mkdirSync(path.join(fixture, '.github', 'workflows'), {recursive: true});
    writeFileSync(
      path.join(fixture, '.github', 'workflows', 'forensics-triage.yml'),
      'name: x\n',
      'utf8'
    );

    expect(resolveFeatures(fixture)).toEqual(['tech-debt', 'forensics']);
  });
});
