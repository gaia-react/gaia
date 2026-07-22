import {describe, expect, test} from 'vitest';
/**
 * Tests for `region-scan.ts`'s `scanRegionDeclarations`.
 *
 * Fixtures are built in a temp dir with a fabricated registry entry (not the
 * real `audit-remit` markers), so these cases are hermetic and independent
 * of `.gaia/audit-ci.yml` / `region-registry.ts`, which has its own suite.
 */
import {mkdirSync, mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import type {RegionRegistryEntry} from './region-registry.js';
import {scanRegionDeclarations} from './region-scan.js';

const START = '<!-- gaia:test-region:start -->';
const END = '<!-- gaia:test-region:end -->';

type Sandbox = {cleanup: () => void; root: string};

const setupSandbox = (): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-region-scan-'));

  return {
    cleanup: () => rmSync(root, {force: true, recursive: true}),
    root,
  };
};

const writeFile = (root: string, relPath: string, content: string): void => {
  const absPath = path.join(root, relPath);
  mkdirSync(path.dirname(absPath), {recursive: true});
  writeFileSync(absPath, content, 'utf8');
};

const buildEntry = (
  overrides: Partial<RegionRegistryEntry> = {}
): RegionRegistryEntry => ({
  args: [],
  endMarker: END,
  id: 'test-region',
  interpreter: 'bash',
  operand: 'test-regen.sh',
  rewrites: () => new Set(),
  startMarker: START,
  ...overrides,
});

describe('scanRegionDeclarations', () => {
  test('a shipped path carrying the pair, present in rewrites → declared', () => {
    const sandbox = setupSandbox();

    try {
      writeFile(sandbox.root, 'a.md', [START, 'body', END].join('\n'));
      const entry = buildEntry({rewrites: () => new Set(['a.md'])});

      const [declaration] = scanRegionDeclarations(
        sandbox.root,
        {'a.md': 'owned'},
        [entry]
      );

      expect(declaration).toEqual({
        endMarker: END,
        id: 'test-region',
        paths: ['a.md'],
        regenerate: {args: [], interpreter: 'bash', operand: 'test-regen.sh'},
        startMarker: START,
      });
    } finally {
      sandbox.cleanup();
    }
  });

  test('a path carrying the pair but absent from shippedFiles is not declared', () => {
    const sandbox = setupSandbox();

    try {
      writeFile(sandbox.root, 'withheld.md', [START, 'body', END].join('\n'));
      const entry = buildEntry({rewrites: () => new Set(['withheld.md'])});

      const [declaration] = scanRegionDeclarations(sandbox.root, {}, [entry]);

      expect(declaration.paths).toEqual([]);
    } finally {
      sandbox.cleanup();
    }
  });

  test('a shipped path carrying the pair that is not in rewrites throws, naming the path', () => {
    const sandbox = setupSandbox();

    try {
      writeFile(sandbox.root, 'orphan.md', [START, 'body', END].join('\n'));
      const entry = buildEntry({rewrites: () => new Set()});

      expect(() =>
        scanRegionDeclarations(sandbox.root, {'orphan.md': 'owned'}, [entry])
      ).toThrow(/orphan\.md/);
    } finally {
      sandbox.cleanup();
    }
  });

  test('marker text as a substring of longer prose is not declared', () => {
    const sandbox = setupSandbox();

    try {
      writeFile(
        sandbox.root,
        'prose.md',
        `Use the \`${START}\` marker to delimit it.\n`
      );
      const entry = buildEntry({rewrites: () => new Set(['prose.md'])});

      const [declaration] = scanRegionDeclarations(
        sandbox.root,
        {'prose.md': 'owned'},
        [entry]
      );

      expect(declaration.paths).toEqual([]);
    } finally {
      sandbox.cleanup();
    }
  });

  test('duplicated markers throw naming the malformation', () => {
    const sandbox = setupSandbox();

    try {
      writeFile(
        sandbox.root,
        'dup.md',
        [START, 'a', START, 'b', END].join('\n')
      );
      const entry = buildEntry({rewrites: () => new Set(['dup.md'])});

      expect(() =>
        scanRegionDeclarations(sandbox.root, {'dup.md': 'owned'}, [entry])
      ).toThrow(/duplicate-start/);
    } finally {
      sandbox.cleanup();
    }
  });

  test('paths are sorted with localeCompare', () => {
    const sandbox = setupSandbox();

    try {
      writeFile(sandbox.root, 'z.md', [START, 'body', END].join('\n'));
      writeFile(sandbox.root, 'a.md', [START, 'body', END].join('\n'));
      const entry = buildEntry({rewrites: () => new Set(['a.md', 'z.md'])});

      const [declaration] = scanRegionDeclarations(
        sandbox.root,
        {'a.md': 'owned', 'z.md': 'owned'},
        [entry]
      );

      expect(declaration.paths).toEqual(['a.md', 'z.md']);
    } finally {
      sandbox.cleanup();
    }
  });

  test('a registry entry finding no carrying shipped path declares paths: [] without throwing', () => {
    const sandbox = setupSandbox();

    try {
      writeFile(sandbox.root, 'plain.md', 'nothing here\n');
      const entry = buildEntry({rewrites: () => new Set()});

      const declarations = scanRegionDeclarations(
        sandbox.root,
        {'plain.md': 'owned'},
        [entry]
      );

      expect(declarations).toEqual([
        {
          endMarker: END,
          id: 'test-region',
          paths: [],
          regenerate: {
            args: [],
            interpreter: 'bash',
            operand: 'test-regen.sh',
          },
          startMarker: START,
        },
      ]);
    } finally {
      sandbox.cleanup();
    }
  });

  test('a shippedFiles path missing from disk is skipped, not thrown', () => {
    const sandbox = setupSandbox();

    try {
      const entry = buildEntry({rewrites: () => new Set()});

      const declarations = scanRegionDeclarations(
        sandbox.root,
        {'ghost.md': 'owned'},
        [entry]
      );

      expect(declarations[0]?.paths).toEqual([]);
    } finally {
      sandbox.cleanup();
    }
  });

  test('defaults to REGION_REGISTRY when no registry override is passed', () => {
    const sandbox = setupSandbox();

    try {
      const declarations = scanRegionDeclarations(sandbox.root, {});
      expect(declarations.map((declaration) => declaration.id)).toEqual([
        'audit-remit',
      ]);
    } finally {
      sandbox.cleanup();
    }
  });
});
