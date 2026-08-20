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

const repoRoot = resolveRepoRootFromImportMeta(import.meta.url);
const registry = readRegistry(repoRoot);

const names = (
  audience: 'adopter' | 'maintainer',
  features: ('forensics' | 'gaia-ci' | 'tech-debt')[]
): string[] =>
  creatableEntries(registry, audience, features)
    .map((entry) => entry.name)
    .toSorted((a, b) => a.localeCompare(b));

describe('labels/registry readRegistry', () => {
  test('parses the committed .gaia/labels.json', () => {
    expect(registry.version).toBe(1);
    expect(registry.labels).toHaveLength(31);
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
  test('every feature on yields the twenty adopter-role entries', () => {
    expect(names('adopter', ['tech-debt', 'gaia-ci', 'forensics'])).toEqual([
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

  test('GAIA CI off drops only the two labels its workflows own', () => {
    expect(names('adopter', ['tech-debt', 'forensics'])).toEqual([
      'bug',
      'debt:in-progress',
      'debt:spec-pending',
      'difficulty:easy',
      'difficulty:hard',
      'difficulty:medium',
      'enhancement',
      'fold:required',
      'handler:plan',
      'handler:prompt',
      'handler:spec',
      'needs-human',
      'run-audit',
      'severity:critical',
      'severity:important',
      'severity:suggestion',
      'tech-debt',
      'wontfix',
    ]);
  });

  test('tech-debt off leaves the always-on set plus the GAIA CI set', () => {
    expect(names('adopter', ['gaia-ci', 'forensics'])).toEqual([
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

  test('a maintainer entry never reaches an adopter creatable set', () => {
    const maintainerNames = new Set(
      registry.labels
        .filter((entry) => entry.audience === 'maintainer')
        .map((entry) => entry.name)
    );
    const adopterNames = names('adopter', [
      'tech-debt',
      'gaia-ci',
      'forensics',
    ]);

    expect(adopterNames.filter((name) => maintainerNames.has(name))).toEqual(
      []
    );
  });

  test('the maintainer set is the adopter set plus the maintainer entries', () => {
    expect(names('maintainer', ['tech-debt', 'gaia-ci', 'forensics'])).toEqual([
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

  test('the maintainer set still excludes the deprecated, unmanaged entry', () => {
    expect(
      names('maintainer', ['tech-debt', 'gaia-ci', 'forensics'])
    ).not.toContain('debt:pre-provenance');
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

  test('an automation config turns GAIA CI on', () => {
    mkdirSync(path.join(fixture, '.gaia'), {recursive: true});
    writeFileSync(path.join(fixture, '.gaia', 'automation.json'), '{}', 'utf8');

    expect(resolveFeatures(fixture)).toEqual(['tech-debt', 'gaia-ci']);
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
