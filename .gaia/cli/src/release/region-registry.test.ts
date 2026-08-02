import {afterEach, beforeEach, describe, expect, test} from 'vitest';
/**
 * Tests for `region-registry.ts`: the hand-authored region declarations and
 * `rosterAgentPaths`, the roster-derived `rewrites` set for the `audit-remit`
 * entry.
 *
 * Fixtures are built in a temp dir, not against the real repo, so the roster-
 * shape cases are hermetic.
 */
import {mkdirSync, mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {REGION_REGISTRY, rosterAgentPaths} from './region-registry.js';

type Sandbox = {cleanup: () => void; root: string};

const setupSandbox = (): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-region-registry-'));

  return {
    cleanup: () => rmSync(root, {force: true, recursive: true}),
    root,
  };
};

const writeRoster = (root: string, contents: string): void => {
  const rosterPath = path.join(root, '.gaia/audit-ci.yml');
  mkdirSync(path.dirname(rosterPath), {recursive: true});
  writeFileSync(rosterPath, contents, 'utf8');
};

describe('rosterAgentPaths', () => {
  let sandbox: Sandbox;

  beforeEach(() => {
    sandbox = setupSandbox();
  });

  afterEach(() => {
    sandbox.cleanup();
  });

  test('reads each auditors[].name into .claude/agents/<name>.md', () => {
    writeRoster(
      sandbox.root,
      [
        'auditors:',
        '  - name: code-audit-frontend',
        '    globs:',
        '      - "app/**"',
        '    scope: adopter',
        '    default: true',
        '  - name: code-audit-maintainer-node',
        '    globs:',
        '      - ".gaia/cli/src/**/*.ts"',
        '    scope: maintainer-only',
        '',
      ].join('\n')
    );

    expect(rosterAgentPaths(sandbox.root)).toEqual(
      new Set([
        '.claude/agents/code-audit-frontend.md',
        '.claude/agents/code-audit-maintainer-node.md',
      ])
    );
  });

  test('roster file absent → empty set', () => {
    expect(rosterAgentPaths(sandbox.root)).toEqual(new Set());
  });

  test('unparseable YAML throws, naming the roster and carrying the parser message', () => {
    writeRoster(sandbox.root, 'auditors: [\n  - unterminated\n');

    expect(() => rosterAgentPaths(sandbox.root)).toThrow(
      /\.gaia\/audit-ci\.yml is not valid YAML/
    );
    // js-yaml's own text, including its (line:column) mark, is what makes the
    // syntax error findable. Without it the maintainer is sent to edit roster
    // membership instead.
    expect(() => rosterAgentPaths(sandbox.root)).toThrow(
      /missed comma between flow collection entries \(2:3\)/
    );
  });

  test('a roster that exists but cannot be read throws, and does not claim a syntax error', () => {
    // A directory at the roster path passes existsSync and fails readFileSync
    // with EISDIR, so the read arm is exercised without chmod (which does not
    // hold as root). EISDIR's own message names no path, hence the prefix.
    mkdirSync(path.join(sandbox.root, '.gaia/audit-ci.yml'), {recursive: true});

    expect(() => rosterAgentPaths(sandbox.root)).toThrow(
      /\.gaia\/audit-ci\.yml could not be read/
    );
    expect(() => rosterAgentPaths(sandbox.root)).not.toThrow(/valid YAML/);
  });

  test('a roster with no top-level mapping throws rather than declaring no auditors', () => {
    // js-yaml parses every one of these successfully, so they reach the shape
    // check rather than the parse arm: an empty, truncated, or comment-only
    // file yields undefined, and a bare scalar or a top-level list yields
    // something that cannot carry an `auditors` key. All are broken sources.
    const {root} = sandbox;

    for (const contents of [
      '',
      '   \n\n',
      '# comment only\n',
      'garbage text\n',
      '- a\n- b\n',
    ]) {
      writeRoster(root, contents);

      expect(() => rosterAgentPaths(root)).toThrow(
        /\.gaia\/audit-ci\.yml has no top-level YAML mapping/
      );
    }
  });

  test('auditors key absent or not a list → empty set', () => {
    writeRoster(sandbox.root, 'gate_label: null\n');
    expect(rosterAgentPaths(sandbox.root)).toEqual(new Set());

    writeRoster(sandbox.root, 'auditors: "not-a-list"\n');
    expect(rosterAgentPaths(sandbox.root)).toEqual(new Set());
  });

  test('entries with no name, or a non-string name, are skipped rather than crashing', () => {
    writeRoster(
      sandbox.root,
      [
        'auditors:',
        '  - globs:',
        '      - "app/**"',
        '  - name: 7',
        '  - name: real-member',
        '',
      ].join('\n')
    );

    expect(rosterAgentPaths(sandbox.root)).toEqual(
      new Set(['.claude/agents/real-member.md'])
    );
  });
});

describe('REGION_REGISTRY', () => {
  test('carries exactly one entry: the roster-derived audit-remit region', () => {
    expect(REGION_REGISTRY).toHaveLength(1);
    const [entry] = REGION_REGISTRY;
    expect(entry).toMatchObject({
      args: [],
      endMarker: '<!-- gaia:audit-remit:end -->',
      id: 'audit-remit',
      interpreter: 'bash',
      operand: '.gaia/scripts/write-audit-remits.sh',
      startMarker: '<!-- gaia:audit-remit:start -->',
    });
    expect(entry.rewrites).toBe(rosterAgentPaths);
  });
});
