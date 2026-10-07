import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {mkdirSync, mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import {findBrokenLinks, run} from './broken-links.js';

type Sandbox = {
  cleanup: () => void;
  root: string;
  writeFile: (relativePath: string, contents: string) => void;
};

const setupSandbox = (): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-wiki-broken-links-'));

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

const EXISTING_PAGE = [
  '---',
  'type: concept',
  '---',
  '# Existing Title',
  '',
  '## Heading',
  '',
].join('\n');

describe('wiki broken-links', () => {
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

  const brokenTargets = (relativePath: string, body: string): string[] => {
    sandbox.writeFile('wiki/concepts/Existing.md', EXISTING_PAGE);
    sandbox.writeFile(relativePath, body);

    return findBrokenLinks(sandbox.root).broken.map((link) => link.target);
  };

  test('reports exactly the dangling links of the full fixture, as compact JSON', () => {
    sandbox.writeFile('wiki/concepts/Existing.md', EXISTING_PAGE);
    sandbox.writeFile('wiki/overview.md', '# Overview\n');
    sandbox.writeFile('wiki/meta/Meta Note.md', '# Meta Note\n');
    sandbox.writeFile('wiki/_archived/Archived Page.md', '# Archived Page\n');
    sandbox.writeFile(
      'wiki/concepts/Links.md',
      [
        '---',
        'type: concept',
        'depends_on: [[Missing Dep]]',
        '---',
        '[[Existing Title]]',
        '[[existing]]',
        '[[Existing Title|alias]]',
        '[[Existing Title#Heading]]',
        '[[concepts/Existing]]',
        '[[overview]]',
        '[[Meta Note]]',
        '[[Missing Page]]',
        '[[#Heading]]',
        '[[Archived Page]]',
        String.raw`| a | [[Existing Title\|alias]] |`,
        '`[[Missing In Code]]`',
        '```',
        '[[Missing In Fence]]',
        '```',
        '',
      ].join('\n')
    );
    sandbox.writeFile('wiki/meta/x.md', '[[Missing Exempt]]\n');
    sandbox.writeFile('wiki/log.md', '[[Missing Exempt]]\n');
    sandbox.writeFile('wiki/hot.md', '[[Missing Exempt]]\n');
    sandbox.writeFile('wiki/_archived/y.md', '[[Missing Exempt]]\n');

    const exit = run(['--json'], {cwd: sandbox.root});

    expect(exit).toBe(EXIT_CODES.OK);
    expect(stdio.outputs.join('')).toBe(
      '{"broken":[{"path":"wiki/concepts/Links.md","line":3,"target":"Missing Dep"},{"path":"wiki/concepts/Links.md","line":12,"target":"Missing Page"},{"path":"wiki/concepts/Links.md","line":14,"target":"Archived Page"}]}\n'
    );
  });

  describe('resolution by link form', () => {
    test('slug match is case-insensitive', () => {
      expect(brokenTargets('wiki/a.md', '[[EXISTING]]\n')).toEqual([]);
    });

    test('H1 title match is case-insensitive', () => {
      expect(brokenTargets('wiki/a.md', '[[existing title]]\n')).toEqual([]);
    });

    test('an alias is dropped before matching', () => {
      expect(brokenTargets('wiki/a.md', '[[Existing Title|shown]]\n')).toEqual(
        []
      );
      expect(brokenTargets('wiki/a.md', '[[Gone|Existing Title]]\n')).toEqual([
        'Gone',
      ]);
    });

    test('an anchor is dropped before matching', () => {
      expect(brokenTargets('wiki/a.md', '[[Existing Title#Nope]]\n')).toEqual(
        []
      );
      expect(brokenTargets('wiki/a.md', '[[Gone#Heading]]\n')).toEqual([
        'Gone',
      ]);
    });

    test('an escaped table pipe separates the alias', () => {
      expect(
        brokenTargets('wiki/a.md', '| x | [[Existing Title\\|shown]] |\n')
      ).toEqual([]);
      expect(brokenTargets('wiki/a.md', '| x | [[Gone\\|shown]] |\n')).toEqual([
        'Gone',
      ]);
    });

    test('a folder prefix resolves by its final segment and reports the full target', () => {
      expect(brokenTargets('wiki/a.md', '[[concepts/Existing]]\n')).toEqual([]);
      expect(brokenTargets('wiki/a.md', '[[concepts/Gone]]\n')).toEqual([
        'concepts/Gone',
      ]);
    });

    test('a wiki-root page and a wiki/meta page are valid targets', () => {
      sandbox.writeFile('wiki/overview.md', 'no title here\n');
      sandbox.writeFile('wiki/meta/Meta Note.md', '# Meta Note\n');

      expect(
        brokenTargets('wiki/a.md', '[[overview]] [[Meta Note]]\n')
      ).toEqual([]);
    });

    test('a same-page anchor is neither reported nor counted', () => {
      sandbox.writeFile('wiki/a.md', '[[#Heading]]\n');

      expect(findBrokenLinks(sandbox.root)).toEqual({
        broken: [],
        scannedLinkCount: 0,
      });
    });

    test('an inline code span is ignored, and a link after it still counts', () => {
      expect(
        brokenTargets(
          'wiki/a.md',
          '`[[Gone]]` and ``[[Gone Too]]`` [[Real Gone]]\n'
        )
      ).toEqual(['Real Gone']);
    });

    test('a backtick fence and a tilde fence each hide their lines', () => {
      expect(
        brokenTargets(
          'wiki/a.md',
          [
            '```',
            '[[Gone In Backticks]]',
            '```',
            '~~~',
            '[[Gone In Tildes]]',
            '~~~',
            '[[Gone After]]',
            '',
          ].join('\n')
        )
      ).toEqual(['Gone After']);
    });

    test('a frontmatter link is reported with its file line', () => {
      sandbox.writeFile('wiki/concepts/Existing.md', EXISTING_PAGE);
      sandbox.writeFile(
        'wiki/a.md',
        ['---', 'type: concept', 'related: [[Gone]]', '---', ''].join('\n')
      );

      expect(findBrokenLinks(sandbox.root).broken).toEqual([
        {line: 3, path: 'wiki/a.md', target: 'Gone'},
      ]);
    });

    test('a link into wiki/_archived is broken', () => {
      sandbox.writeFile('wiki/_archived/Old.md', '# Old\n');

      expect(brokenTargets('wiki/a.md', '[[Old]]\n')).toEqual(['Old']);
    });

    test('links inside exempt files are not reported', () => {
      sandbox.writeFile('wiki/meta/x.md', '[[Gone]]\n');
      sandbox.writeFile('wiki/log.md', '[[Gone]]\n');
      sandbox.writeFile('wiki/hot.md', '[[Gone]]\n');
      sandbox.writeFile('wiki/_archived/y.md', '[[Gone]]\n');

      expect(findBrokenLinks(sandbox.root)).toEqual({
        broken: [],
        scannedLinkCount: 0,
      });
    });
  });

  test('orders links by column within a line and files by path', () => {
    sandbox.writeFile('wiki/b.md', '[[Zed]]\n');
    sandbox.writeFile('wiki/a.md', 'x [[Second]] y [[Third]]\n[[Fourth]]\n');

    expect(
      findBrokenLinks(sandbox.root).broken.map(
        (link) => `${link.path}:${link.line}:${link.target}`
      )
    ).toEqual([
      'wiki/a.md:1:Second',
      'wiki/a.md:1:Third',
      'wiki/a.md:2:Fourth',
      'wiki/b.md:1:Zed',
    ]);
  });

  test('human mode prints one path:line  target line per entry', () => {
    sandbox.writeFile('wiki/a.md', '[[One]]\n\n[[Two]]\n');

    const exit = run([], {cwd: sandbox.root});

    expect(exit).toBe(EXIT_CODES.OK);
    expect(stdio.outputs.join('')).toBe('wiki/a.md:1  One\nwiki/a.md:3  Two\n');
  });

  test('human mode prints nothing when clean', () => {
    sandbox.writeFile('wiki/concepts/Existing.md', EXISTING_PAGE);
    sandbox.writeFile('wiki/a.md', '[[Existing Title]]\n');

    const exit = run([], {cwd: sandbox.root});

    expect(exit).toBe(EXIT_CODES.OK);
    expect(stdio.outputs.join('')).toBe('');
  });

  test('counts every non-skipped link', () => {
    sandbox.writeFile('wiki/concepts/Existing.md', EXISTING_PAGE);
    sandbox.writeFile(
      'wiki/a.md',
      [
        '[[Existing Title]]',
        '[[Gone]]',
        '[[#Heading]]',
        '`[[Code]]`',
        '```',
        '[[Fence]]',
        '```',
        '[[Existing Title|alias]]',
        '',
      ].join('\n')
    );
    sandbox.writeFile('wiki/log.md', '[[Exempt]]\n');

    expect(findBrokenLinks(sandbox.root).scannedLinkCount).toBe(3);
  });

  test('an unknown flag is an invalid_arguments error', () => {
    const exit = run(['--bogus'], {cwd: sandbox.root});

    expect(exit).toBe(EXIT_CODES.UNKNOWN_SUBCOMMAND);
    expect(stdio.errors.join('')).toContain('invalid_arguments');
  });

  test('an absent wiki directory yields an empty report', () => {
    const exit = run(['--json'], {cwd: sandbox.root});

    expect(exit).toBe(EXIT_CODES.OK);
    expect(stdio.outputs.join('')).toBe('{"broken":[]}\n');
  });
});
