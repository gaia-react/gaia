/**
 * Tests for `region-registry.ts`: the hand-authored region declarations and
 * `rosterAgentPaths`, the roster-derived `rewrites` set for the `audit-remit`
 * entry.
 *
 * Fixtures are built in a temp dir, not against the real repo, so the roster-
 * shape cases are hermetic.
 */
import {afterEach, beforeEach, describe, expect, test} from 'vitest';
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

  // js-yaml parses every one of these successfully, so they reach the shape
  // check rather than the parse arm. An empty file yields `undefined`, a
  // whitespace- or comment-only file yields `null`, and the rest yield values
  // that cannot carry an `auditors` key. A top-level timestamp and a `!!binary`
  // are the two that are `typeof 'object'` under js-yaml's default schema, so
  // they are what a bare `typeof` test would wrongly admit.
  test.each([
    ['an empty file', ''],
    ['whitespace only', '   \n\n'],
    ['comments only', '# comment only\n'],
    ['a bare scalar', 'garbage text\n'],
    ['a top-level list', '- a\n- b\n'],
    ['a top-level timestamp', '2026-08-02\n'],
    ['top-level binary', '!!binary "aGk="\n'],
  ])(
    'a roster that is %s throws rather than declaring no auditors',
    (_label, contents) => {
      const {root} = sandbox;

      writeRoster(root, contents);

      expect(() => rosterAgentPaths(root)).toThrow(
        /\.gaia\/audit-ci\.yml has no top-level YAML mapping/
      );
    }
  );

  test('auditors key absent or not a list → empty set', () => {
    writeRoster(sandbox.root, 'gate_label: null\n');
    expect(rosterAgentPaths(sandbox.root)).toEqual(new Set());

    writeRoster(sandbox.root, 'auditors: "not-a-list"\n');
    expect(rosterAgentPaths(sandbox.root)).toEqual(new Set());
  });

  test('the remedy the not-a-mapping message advises actually works', () => {
    // That message tells a maintainer to delete the roster or give it a
    // top-level mapping such as `auditors: []`. Advice that did not itself
    // produce a clean empty set would be the same species of confident, wrong
    // instruction this module exists to stop handing out, so it is asserted
    // rather than assumed. The delete arm is covered by the absent-roster test.
    //
    // Both halves are asserted, because proving the shape works while nothing
    // pins the message to that shape lets the advice drift away from the only
    // shape known to work, silently and with every test still green.
    writeRoster(sandbox.root, '# comment only\n');
    expect(() => rosterAgentPaths(sandbox.root)).toThrow('auditors: []');

    writeRoster(sandbox.root, 'auditors: []\n');
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
