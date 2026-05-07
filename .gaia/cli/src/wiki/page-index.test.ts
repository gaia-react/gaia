/**
 * Tests for `gaia wiki page-index`.
 */
import {execFileSync} from 'node:child_process';
import {
  mkdirSync,
  mkdtempSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {run, type PageIndex} from './page-index.js';

type Sandbox = {
  cleanup: () => void;
  root: string;
  writePage: (relativePath: string, contents: string) => void;
};

const setupSandbox = (): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-wiki-page-index-'));
  execFileSync('git', ['init', '-q'], {cwd: root});
  mkdirSync(path.join(root, 'wiki'), {recursive: true});

  return {
    cleanup: () => {
      rmSync(root, {force: true, recursive: true});
    },
    root,
    writePage: (relativePath, contents) => {
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

describe('wiki page-index', () => {
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

  test('parses frontmatter and counts links across pages', () => {
    sandbox.writePage(
      'wiki/concepts/Foo.md',
      `---
type: concept
status: active
tags: [a, b]
---

# Foo

Refers to [[Bar]] and [[Baz]].
`
    );
    sandbox.writePage(
      'wiki/concepts/Bar.md',
      `---
type: concept
status: active
tags: []
---

# Bar

Mentions [[Foo|the foo]] twice: [[Foo]].
`
    );
    sandbox.writePage(
      'wiki/decisions/Baz.md',
      `---
type: decision
status: active
---

# Baz

No outbound links.
`
    );

    const exit = run(['--json'], {cwd: sandbox.root});
    expect(exit).toBe(0);

    const index = JSON.parse(stdio.outputs.join('').trim()) as PageIndex;
    const byTitle = new Map(index.pages.map((page) => [page.title, page]));
    const foo = byTitle.get('Foo');
    expect(foo).toBeDefined();
    expect(foo?.domain).toBe('concepts');
    expect(foo?.tags).toEqual(['a', 'b']);
    expect(foo?.outbound_links).toBe(2);
    // Bar references Foo twice → inbound_links === 2.
    expect(foo?.inbound_links).toBe(2);

    const bar = byTitle.get('Bar');
    expect(bar?.outbound_links).toBe(2);
    // Foo references Bar once.
    expect(bar?.inbound_links).toBe(1);

    const baz = byTitle.get('Baz');
    // Foo references Baz once.
    expect(baz?.inbound_links).toBe(1);
    expect(baz?.outbound_links).toBe(0);
    expect(baz?.type).toBe('decision');
  });

  test('skips per-domain _index.md and pages starting with _', () => {
    sandbox.writePage('wiki/concepts/_index.md', '# Index\n');
    sandbox.writePage('wiki/concepts/_draft.md', '# Draft\n');
    sandbox.writePage(
      'wiki/concepts/Real.md',
      '---\ntype: concept\n---\n\n# Real\n'
    );

    const exit = run(['--json'], {cwd: sandbox.root});
    expect(exit).toBe(0);
    const index = JSON.parse(stdio.outputs.join('').trim()) as PageIndex;
    const titles = index.pages.map((page) => page.title);
    expect(titles).toContain('Real');
    expect(titles).not.toContain('Index');
    expect(titles).not.toContain('Draft');
  });

  test('handles pages with no frontmatter', () => {
    sandbox.writePage('wiki/concepts/Bare.md', '# Bare\n\nNo frontmatter.');

    const exit = run(['--json'], {cwd: sandbox.root});
    expect(exit).toBe(0);
    const index = JSON.parse(stdio.outputs.join('').trim()) as PageIndex;
    const bare = index.pages.find((page) => page.title === 'Bare');
    expect(bare).toBeDefined();
    expect(bare?.tags).toEqual([]);
    expect(bare?.type).toBeNull();
  });

  test('falls back to slug when no H1 is present', () => {
    sandbox.writePage(
      'wiki/concepts/no-heading.md',
      '---\ntype: concept\n---\n\nbody only, no H1\n'
    );

    const exit = run(['--json'], {cwd: sandbox.root});
    expect(exit).toBe(0);
    const index = JSON.parse(stdio.outputs.join('').trim()) as PageIndex;
    const found = index.pages.find((page) => page.title === 'no-heading');
    expect(found).toBeDefined();
  });

  test('without --json, prints a tabular summary', () => {
    sandbox.writePage(
      'wiki/concepts/Foo.md',
      '---\ntype: concept\n---\n\n# Foo\n'
    );

    const exit = run([], {cwd: sandbox.root});
    expect(exit).toBe(0);
    expect(stdio.outputs.join('')).toContain('Foo');
  });

  test('rejects unknown flags', () => {
    const exit = run(['--bogus'], {cwd: sandbox.root});
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('unknown flag');
  });
});
