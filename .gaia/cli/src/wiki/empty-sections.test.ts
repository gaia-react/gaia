/**
 * Tests for `gaia wiki empty-sections`.
 */
import {execFileSync} from 'node:child_process';
import {mkdirSync, mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {findEmptySections, run} from './empty-sections.js';

type Sandbox = {
  cleanup: () => void;
  root: string;
  writeFile: (relativePath: string, contents: string) => void;
};

const setupSandbox = (): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-wiki-empty-sections-'));
  execFileSync('git', ['init', '-q'], {cwd: root});
  mkdirSync(path.join(root, 'wiki'), {recursive: true});

  return {
    cleanup: () => {
      rmSync(root, {force: true, recursive: true});
    },
    root,
    writeFile: (relativePath, contents) => {
      const absPath = path.join(root, relativePath);
      mkdirSync(path.dirname(absPath), {recursive: true});
      writeFileSync(absPath, contents, 'utf8');
    },
  };
};

const captureStdio = (): {
  errors: string[];
  outputs: string[];
  restore: () => void;
} => {
  const outputs: string[] = [];
  const errors: string[] = [];
  const stdoutSpy = vi
    .spyOn(process.stdout, 'write')
    .mockImplementation((chunk: unknown) => {
      outputs.push(typeof chunk === 'string' ? chunk : String(chunk));

      return true;
    });
  const stderrSpy = vi
    .spyOn(process.stderr, 'write')
    .mockImplementation((chunk: unknown) => {
      errors.push(typeof chunk === 'string' ? chunk : String(chunk));

      return true;
    });

  return {
    errors,
    outputs,
    restore: () => {
      stdoutSpy.mockRestore();
      stderrSpy.mockRestore();
    },
  };
};

describe('wiki empty-sections', () => {
  let sandbox: Sandbox;
  let stdio: ReturnType<typeof captureStdio>;

  beforeEach(() => {
    stdio = captureStdio();
    sandbox = setupSandbox();
  });

  afterEach(() => {
    stdio.restore();
    sandbox.cleanup();
    vi.restoreAllMocks();
  });

  test('flags a leaf heading followed by a sibling-level heading with no body', () => {
    sandbox.writeFile(
      'wiki/concepts/Foo.md',
      [
        '# Foo',
        '',
        'Intro.',
        '',
        '## Bar',
        '',
        '## Baz',
        '',
        'Content under baz.',
        '',
      ].join('\n')
    );

    const empty = findEmptySections(sandbox.root);
    expect(empty).toEqual([
      {heading: '## Bar', line: 5, path: 'wiki/concepts/Foo.md'},
    ]);
  });

  test('does not flag a parent heading whose child headings have content', () => {
    sandbox.writeFile(
      'wiki/concepts/Parent.md',
      [
        '# Accessibility',
        '',
        '## Static lint',
        '',
        'Lint catches issues.',
        '',
        '## Cross-references',
        '',
        'See the playbook.',
        '',
      ].join('\n')
    );

    expect(findEmptySections(sandbox.root)).toEqual([]);
  });

  test('does not flag a heading whose only span content is a deeper heading with content', () => {
    sandbox.writeFile(
      'wiki/concepts/Nested.md',
      [
        '# Runbook',
        '',
        '## Operator runbook',
        '',
        '### Halt a runaway run',
        '',
        'Press the stop button.',
        '',
      ].join('\n')
    );

    expect(findEmptySections(sandbox.root)).toEqual([]);
  });

  test('flags a leaf child while leaving its parent unflagged', () => {
    sandbox.writeFile(
      'wiki/concepts/Mixed.md',
      [
        '# Top',
        '',
        '## Parent',
        '',
        '### Filled',
        '',
        'Body here.',
        '',
        '### Empty',
        '',
        '## Sibling',
        '',
        'More body.',
        '',
      ].join('\n')
    );

    const empty = findEmptySections(sandbox.root);
    expect(empty).toEqual([
      {heading: '### Empty', line: 9, path: 'wiki/concepts/Mixed.md'},
    ]);
  });

  test('flags an EOF-terminated empty section', () => {
    sandbox.writeFile(
      'wiki/concepts/Foo.md',
      ['# Foo', '', 'Intro.', '', '## Trailing', '', ''].join('\n')
    );

    const empty = findEmptySections(sandbox.root);
    expect(empty).toEqual([
      {heading: '## Trailing', line: 5, path: 'wiki/concepts/Foo.md'},
    ]);
  });

  test('does not flag a heading that has body content', () => {
    sandbox.writeFile(
      'wiki/concepts/Foo.md',
      [
        '# Foo',
        '',
        'Body for foo.',
        '',
        '## Bar',
        '',
        'Body for bar.',
        '',
      ].join('\n')
    );

    expect(findEmptySections(sandbox.root)).toEqual([]);
  });

  test('ignores fake headings inside fenced code blocks', () => {
    sandbox.writeFile(
      'wiki/concepts/Code.md',
      [
        '# Code',
        '',
        'Intro.',
        '',
        '## Example',
        '',
        '```sh',
        '# this is a shell comment, not a heading',
        'echo hi',
        '```',
        '',
      ].join('\n')
    );

    expect(findEmptySections(sandbox.root)).toEqual([]);
  });

  test('treats fenced code content as satisfying the prior heading', () => {
    sandbox.writeFile(
      'wiki/concepts/Code.md',
      [
        '# Code',
        '',
        'Intro.',
        '',
        '## Snippet',
        '',
        '```ts',
        'const x = 1;',
        '```',
        '',
      ].join('\n')
    );

    expect(findEmptySections(sandbox.root)).toEqual([]);
  });

  test('reports the original line number despite frontmatter', () => {
    sandbox.writeFile(
      'wiki/concepts/Foo.md',
      [
        '---',
        'type: concept',
        'status: stable',
        '---',
        '',
        '# Foo',
        '',
        'Intro.',
        '',
        '## Empty',
        '',
        '## Next',
        '',
        'Content.',
        '',
      ].join('\n')
    );

    const empty = findEmptySections(sandbox.root);
    expect(empty).toEqual([
      {heading: '## Empty', line: 10, path: 'wiki/concepts/Foo.md'},
    ]);
  });

  test('skips wiki/meta/** audit artifacts', () => {
    sandbox.writeFile(
      'wiki/meta/report.md',
      ['# Report', '', '## Empty Heading', '', ''].join('\n')
    );

    expect(findEmptySections(sandbox.root)).toEqual([]);
  });

  test('skips the auto-managed sentinels wiki/hot.md and wiki/log.md', () => {
    sandbox.writeFile('wiki/hot.md', ['# Recent Context', '', ''].join('\n'));
    sandbox.writeFile('wiki/log.md', ['# Log', '', ''].join('\n'));

    expect(findEmptySections(sandbox.root)).toEqual([]);
  });

  test('CLI prints "path:line  heading" lines', () => {
    sandbox.writeFile(
      'wiki/concepts/Foo.md',
      [
        '# Foo',
        '',
        'Intro.',
        '',
        '## Bar',
        '',
        '## Baz',
        '',
        'Content.',
        '',
      ].join('\n')
    );

    const exit = run([], {cwd: sandbox.root});
    expect(exit).toBe(0);
    expect(stdio.outputs.join('').trim()).toBe(
      'wiki/concepts/Foo.md:5  ## Bar'
    );
  });

  test('CLI prints a clean message when there are no empty sections', () => {
    sandbox.writeFile(
      'wiki/concepts/Foo.md',
      ['# Foo', '', 'All good.', ''].join('\n')
    );

    const exit = run([], {cwd: sandbox.root});
    expect(exit).toBe(0);
    expect(stdio.outputs.join('').trim()).toBe('No empty sections found.');
  });

  test('--json emits a structured empty object', () => {
    sandbox.writeFile(
      'wiki/concepts/Foo.md',
      [
        '# Foo',
        '',
        'Intro.',
        '',
        '## Bar',
        '',
        '## Baz',
        '',
        'Content.',
        '',
      ].join('\n')
    );

    const exit = run(['--json'], {cwd: sandbox.root});
    expect(exit).toBe(0);

    const parsed = JSON.parse(stdio.outputs.join('')) as {
      empty: ReadonlyArray<{heading: string; line: number; path: string}>;
    };
    expect(parsed.empty).toEqual([
      {heading: '## Bar', line: 5, path: 'wiki/concepts/Foo.md'},
    ]);
  });

  test('rejects unknown flags', () => {
    const exit = run(['--bogus'], {cwd: sandbox.root});
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('unknown flag');
  });

  test('exits 0 when there is no wiki/ directory', () => {
    rmSync(path.join(sandbox.root, 'wiki'), {force: true, recursive: true});

    const exit = run([], {cwd: sandbox.root});
    expect(exit).toBe(0);
    expect(stdio.outputs.join('').trim()).toBe('No empty sections found.');
  });
});
