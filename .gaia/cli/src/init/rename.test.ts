/**
 * Tests for `gaia init rename`.
 */
import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {
  copyFileSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {runInNewContext} from 'node:vm';
import {resolveRepoRootFromImportMeta} from '../util/repo-root-fixture.js';
import {claudeMdHasH1, run} from './rename.js';
import {readState} from './util/state.js';

type Sandbox = {
  cleanup: () => void;
  root: string;
};

const PACKAGE_JSON = JSON.stringify({name: 'gaia', version: '1.0.0'}, null, 2);

const CLAUDE_MD = `# GAIA React

When reporting information to me, be extremely concise.

## Section

Body
`;

const COMMON_TS = `export default {
  meta: {
    siteName: 'GAIA',
  },
  someOtherKey: 'untouched',
};
`;

const PAGE_INDEX_TS = `export default {
  heroTitle: 'Start with something solid.',
  meta: {
    description: 'Description of the index page',
    title: 'Index Page',
  },
  title: 'Old Title',
};
`;

const setupSandbox = (): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-init-rename-'));
  writeFileSync(path.join(root, 'package.json'), `${PACKAGE_JSON}\n`, 'utf8');
  writeFileSync(path.join(root, 'CLAUDE.md'), CLAUDE_MD, 'utf8');
  mkdirSync(path.join(root, 'app', 'languages', 'en', 'pages'), {
    recursive: true,
  });
  writeFileSync(
    path.join(root, 'app', 'languages', 'en', 'common.ts'),
    COMMON_TS,
    'utf8'
  );
  writeFileSync(
    path.join(root, 'app', 'languages', 'en', 'pages', '_index.ts'),
    PAGE_INDEX_TS,
    'utf8'
  );

  return {
    cleanup: () => {
      rmSync(root, {force: true, recursive: true});
    },
    root,
  };
};

/**
 * The seeded language file's default export, evaluated by the JavaScript
 * engine.
 *
 * A substring assertion cannot tell a correctly escaped literal from a broken
 * one: `siteName: 'Steve'` is a prefix of both the intended value and the
 * unterminated literal a naive rewrite emits. Parsing the file is the oracle
 * that separates them, and reading the property back proves the value survived
 * rather than merely that the file compiles.
 *
 * Evaluating the generated source is therefore the assertion rather than a
 * hazard: the input is a fixture this file defines, rewritten by the subject
 * under test inside a temp sandbox, and it runs in a fresh context with no
 * access to this module's scope.
 */
const evaluateDefaultExport = (source: string): Record<string, unknown> => {
  const expression = source
    .replace(/^export default\s*/mu, '')
    .trim()
    .replace(/;$/u, '');

  // eslint-disable-next-line sonarjs/code-eval -- fixture text this file defines, evaluated in a fresh context with no access to this module's scope
  return runInNewContext(`(${expression})`) as Record<string, unknown>;
};

// The two titles both tables below assert on. Named so the idempotency rows
// cannot drift into covering a different shape from the parse rows they were
// chosen to follow up.
const APOSTROPHE_TITLE = "Steve's App";
const MATCH_REF_TITLE = 'Tom $& Co';

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

describe('init rename', () => {
  let sandbox: Sandbox;
  let stdio: ReturnType<typeof captureStdio>;

  beforeEach(() => {
    stdio = captureStdio();
  });

  afterEach(() => {
    stdio.restore();
    sandbox.cleanup();
    vi.restoreAllMocks();
  });

  test('rewrites package.json + CLAUDE.md heading + locale strings', () => {
    sandbox = setupSandbox();

    const exit = run(['--title', 'Hello World', '--kebab', 'hello-world'], {
      cwd: sandbox.root,
    });
    expect(exit).toBe(0);

    const pkg = JSON.parse(
      readFileSync(path.join(sandbox.root, 'package.json'), 'utf8')
    ) as {name: string};
    expect(pkg.name).toBe('hello-world');

    const claude = readFileSync(path.join(sandbox.root, 'CLAUDE.md'), 'utf8');
    expect(claude.startsWith('# Hello World\n')).toBe(true);
    expect(claude).toContain('When reporting information');

    const common = readFileSync(
      path.join(sandbox.root, 'app', 'languages', 'en', 'common.ts'),
      'utf8'
    );
    expect(common).toContain("siteName: 'Hello World'");
    expect(common).toContain("someOtherKey: 'untouched'");

    const page = readFileSync(
      path.join(sandbox.root, 'app', 'languages', 'en', 'pages', '_index.ts'),
      'utf8'
    );
    expect(page).toContain("heroTitle: 'Hello World'");
    expect(page).toContain("title: 'Hello World'");
    // The nested meta.title was rewritten too.
    expect(page.match(/title: 'Hello World'/gu)?.length).toBeGreaterThanOrEqual(
      2
    );

    const state = readState(sandbox.root);
    expect(state.completed_steps).toContain('rename');
    expect(state.step_args.rename).toEqual({
      kebab: 'hello-world',
      title: 'Hello World',
    });
  });

  test('idempotent: re-running with same args is a no-op', () => {
    sandbox = setupSandbox();
    run(['--title', 'Hello World', '--kebab', 'hello-world'], {
      cwd: sandbox.root,
    });
    const claudeFirst = readFileSync(
      path.join(sandbox.root, 'CLAUDE.md'),
      'utf8'
    );
    const pageFirst = readFileSync(
      path.join(sandbox.root, 'app', 'languages', 'en', 'pages', '_index.ts'),
      'utf8'
    );

    const second = run(['--title', 'Hello World', '--kebab', 'hello-world'], {
      cwd: sandbox.root,
    });
    expect(second).toBe(0);

    expect(readFileSync(path.join(sandbox.root, 'CLAUDE.md'), 'utf8')).toBe(
      claudeFirst
    );
    expect(
      readFileSync(
        path.join(sandbox.root, 'app', 'languages', 'en', 'pages', '_index.ts'),
        'utf8'
      )
    ).toBe(pageFirst);
  });

  test('does not clobber unrelated `title` properties in diverged _index.ts', () => {
    sandbox = setupSandbox();
    // Simulate a user whose _index.ts has diverged from the seed: extra
    // route data with its own nested `title` properties that are NOT the
    // project title and must be preserved verbatim.
    const diverged = `export default {
  heroTitle: 'Start with something solid.',
  meta: {
    description: 'Description of the index page',
    title: 'Index Page',
  },
  title: 'Old Title',
  routes: {
    about: {
      title: 'About Us',
    },
    contact: {
      title: 'Contact',
    },
  },
};
`;
    writeFileSync(
      path.join(sandbox.root, 'app', 'languages', 'en', 'pages', '_index.ts'),
      diverged,
      'utf8'
    );

    const exit = run(['--title', 'Hello World', '--kebab', 'hello-world'], {
      cwd: sandbox.root,
    });
    expect(exit).toBe(0);

    const page = readFileSync(
      path.join(sandbox.root, 'app', 'languages', 'en', 'pages', '_index.ts'),
      'utf8'
    );
    // Seed identity keys rewritten.
    expect(page).toContain("heroTitle: 'Hello World'");
    expect(page).toContain("title: 'Hello World'");
    // meta.title rewritten.
    const helloMatches = page.match(/title: 'Hello World'/gu)?.length ?? 0;
    expect(helloMatches).toBe(2);
    // Unrelated route titles preserved.
    expect(page).toContain("title: 'About Us'");
    expect(page).toContain("title: 'Contact'");
  });

  test.each([
    ['first heading is an `##`', '## Response style\n\nBody\n'],
    // `# ` opens a bash comment as well as a heading, so a scan blind to
    // fences finds one here, reports success with no title written, and
    // rewrites a line of the adopter's own shell example.
    [
      'the only `# ` line is inside a fence',
      '## Setup\n\n```bash\n# install deps\npnpm install\n```\n',
    ],
    // Nested and mismatched fences are why the scan stops at the first fence
    // instead of pairing openers with closers: a tracker that toggles would
    // read the inner opener as the outer one's closer and walk back in.
    [
      'the `# ` line is inside a nested fence',
      '## Setup\n\n````md\n```bash\n# install deps\n```\n````\n',
    ],
    [
      'a `~~~` fence opens inside a backtick block',
      '## Setup\n\n```md\n~~~sh\n# install deps\n~~~\n```\n',
    ],
    ['the only heading sits below a fence', '```sh\n# x\n```\n\n# Title\n'],
    // Scanned per line, so the `\s` after `#` cannot match the line ending
    // and pull the blank line below into the rewrite.
    ['a bare `#` with nothing after it', '#\n\nBody\n'],
    // Same, on a CRLF checkout, where `\s` would otherwise match the `\r`
    // that survives the split.
    ['a bare `#` on CRLF', '#\r\n\r\nBody\r\n'],
  ])('exit 1 when CLAUDE.md has no usable H1: %s', (_label, content) => {
    sandbox = setupSandbox();
    writeFileSync(path.join(sandbox.root, 'CLAUDE.md'), content, 'utf8');

    const exit = run(['--title', 'Hello World', '--kebab', 'hello-world'], {
      cwd: sandbox.root,
    });
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('claude_md_heading_missing');
    expect(readFileSync(path.join(sandbox.root, 'CLAUDE.md'), 'utf8')).toBe(
      content
    );
    // The precondition is checked before the first write, so nothing else was
    // renamed either, and the step is not recorded as completed. Recovery is
    // to add a heading and re-run this command; `gaia init resume` cannot
    // replay it, because the args it would need are recorded only on success.
    const pkg = JSON.parse(
      readFileSync(path.join(sandbox.root, 'package.json'), 'utf8')
    ) as {name: string};
    expect(pkg.name).toBe('gaia');
    expect(readState(sandbox.root).completed_steps).not.toContain('rename');
  });

  test('rewrites the heading above a fence and leaves the fence alone', () => {
    sandbox = setupSandbox();
    const content = '# GAIA React\n\n```sh\n# not a heading\n```\n\nBody\n';
    writeFileSync(path.join(sandbox.root, 'CLAUDE.md'), content, 'utf8');

    expect(
      run(['--title', 'Hello World', '--kebab', 'hello-world'], {
        cwd: sandbox.root,
      })
    ).toBe(0);

    expect(readFileSync(path.join(sandbox.root, 'CLAUDE.md'), 'utf8')).toBe(
      '# Hello World\n\n```sh\n# not a heading\n```\n\nBody\n'
    );
  });

  test('keeps CRLF endings on the line it rewrites', () => {
    sandbox = setupSandbox();
    writeFileSync(
      path.join(sandbox.root, 'CLAUDE.md'),
      '# GAIA React\r\n\r\nBody\r\n',
      'utf8'
    );

    expect(
      run(['--title', 'Hello World', '--kebab', 'hello-world'], {
        cwd: sandbox.root,
      })
    ).toBe(0);

    expect(readFileSync(path.join(sandbox.root, 'CLAUDE.md'), 'utf8')).toBe(
      '# Hello World\r\n\r\nBody\r\n'
    );
  });

  test('exit 1 when package.json missing', () => {
    sandbox = setupSandbox();
    rmSync(path.join(sandbox.root, 'package.json'));

    const exit = run(['--title', 'X', '--kebab', 'x'], {cwd: sandbox.root});
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('package_json_missing');
  });

  test('exit 1 on invalid kebab', () => {
    sandbox = setupSandbox();
    const exit = run(['--title', 'X', '--kebab', 'NotKebab'], {
      cwd: sandbox.root,
    });
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('--kebab must be');
  });

  // A title carrying a line ending splits the heading in two, and the
  // idempotency guard then compares only the first of those lines against the
  // rebuilt heading, so it never matches and every re-run appends again.
  // Refused in `parseFlags`, ahead of the first write.
  test.each([
    ['a newline', 'Bad\nInjected'],
    ['a carriage return', 'Bad\rInjected'],
    ['a trailing newline', 'Bad\n'],
  ])('exit 1 on a multi-line title: %s', (_label, title) => {
    sandbox = setupSandbox();

    const exit = run(['--title', title, '--kebab', 'hello-world'], {
      cwd: sandbox.root,
    });
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('--title must be a single line');

    expect(readFileSync(path.join(sandbox.root, 'CLAUDE.md'), 'utf8')).toBe(
      CLAUDE_MD
    );
    const pkg = JSON.parse(
      readFileSync(path.join(sandbox.root, 'package.json'), 'utf8')
    ) as {name: string};
    expect(pkg.name).toBe('gaia');
    expect(readState(sandbox.root).completed_steps).not.toContain('rename');
  });

  // A blank title writes `# ` as the heading, a CLAUDE.md carrying no title,
  // which is the state the missing-H1 precondition refuses, reached through the
  // flag rather than through the file.
  test.each([
    ['empty', ''],
    ['whitespace only', ' '.repeat(3)],
  ])('exit 1 on a blank title: %s', (_label, title) => {
    sandbox = setupSandbox();

    const exit = run(['--title', title, '--kebab', 'hello-world'], {
      cwd: sandbox.root,
    });
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('--title must not be blank');

    expect(readFileSync(path.join(sandbox.root, 'CLAUDE.md'), 'utf8')).toBe(
      CLAUDE_MD
    );
    // `renamePackageJson` is the first write `run` performs, so this is what
    // pins the refusal ahead of it: without it, moving the blank rule below
    // that call leaves the whole suite green.
    const pkg = JSON.parse(
      readFileSync(path.join(sandbox.root, 'package.json'), 'utf8')
    ) as {name: string};
    expect(pkg.name).toBe('gaia');
    expect(readState(sandbox.root).completed_steps).not.toContain('rename');
  });

  test('exit 1 on missing flags', () => {
    sandbox = setupSandbox();
    expect(run(['--title', 'X'], {cwd: sandbox.root})).toBe(1);
    expect(run(['--kebab', 'x'], {cwd: sandbox.root})).toBe(1);
  });

  // Ordinary titles that the sinks, not the flag boundary, have to handle:
  // `$1` and `$&` are match references in a replacement string, and an
  // apostrophe closes the literal the value is being written into. Asserted
  // through the engine rather than through a substring, so the test proves the
  // seeded file still parses and the key still holds the title the adopter
  // asked for.
  test.each([
    ['a `$n` match reference', 'Q1 $1 Report'],
    ['a `$&` whole-match reference', MATCH_REF_TITLE],
    ['a doubled `$$`', 'Cost $$ Plus'],
    ['an apostrophe', APOSTROPHE_TITLE],
    ['a backslash', String.raw`Path\To App`],
    ['both a quote and a `$`', "Steve's $1 App"],
  ])(
    'writes a parseable language file for a title with %s',
    (_label, title) => {
      sandbox = setupSandbox();

      const exit = run(['--title', title, '--kebab', 'hello-world'], {
        cwd: sandbox.root,
      });
      expect(exit).toBe(0);

      const common = evaluateDefaultExport(
        readFileSync(
          path.join(sandbox.root, 'app', 'languages', 'en', 'common.ts'),
          'utf8'
        )
      );
      expect((common.meta as Record<string, unknown>).siteName).toBe(title);
      expect(common.someOtherKey).toBe('untouched');

      const page = evaluateDefaultExport(
        readFileSync(
          path.join(
            sandbox.root,
            'app',
            'languages',
            'en',
            'pages',
            '_index.ts'
          ),
          'utf8'
        )
      );
      expect(page.heroTitle).toBe(title);
      expect(page.title).toBe(title);
      expect((page.meta as Record<string, unknown>).title).toBe(title);

      // The markdown sink takes the value verbatim: a heading needs no escaping,
      // so an escape leaking out of a language-file sink would show up here.
      expect(
        readFileSync(path.join(sandbox.root, 'CLAUDE.md'), 'utf8')
      ).toContain(`# ${title}\n`);
    }
  );

  // Every seeded value is single-quoted, so the escaping above only ever runs
  // against `'`. A file whose values are double-quoted drives the other arm:
  // there the wrapping `"` is what needs escaping and the apostrophe is what
  // passes through bare, which is the claim the escaper's docblock makes.
  test('escapes for the quote the file uses, not a fixed one', () => {
    sandbox = setupSandbox();
    writeFileSync(
      path.join(sandbox.root, 'app', 'languages', 'en', 'pages', '_index.ts'),
      'export default {\n  heroTitle: "Start with something solid.",\n  title: "Old Title",\n};\n',
      'utf8'
    );

    expect(
      run(['--title', 'Steve\'s "Hi" App', '--kebab', 'hello-world'], {
        cwd: sandbox.root,
      })
    ).toBe(0);

    const raw = readFileSync(
      path.join(sandbox.root, 'app', 'languages', 'en', 'pages', '_index.ts'),
      'utf8'
    );
    const page = evaluateDefaultExport(raw);
    expect(page.heroTitle).toBe('Steve\'s "Hi" App');
    expect(page.title).toBe('Steve\'s "Hi" App');
    // The apostrophe reaches a double-quoted sink unescaped, and the `"` does
    // not: asserted on the bytes, since both spellings parse to the same value.
    expect(raw).toContain(String.raw`title: "Steve's \"Hi\" App"`);
  });

  // The seed is single-quoted, so every test above drives a literal whose
  // wrapping quote is the only quote in it. A literal wrapped in one quote and
  // holding the other bare is still a valid literal, and a content class that
  // spells both quotes out cannot match it: the rewriter finds nothing, writes
  // nothing, and exits 0 with the file untouched.
  test('rewrites a double-quoted value holding a bare apostrophe', () => {
    sandbox = setupSandbox();
    const target = path.join(
      sandbox.root,
      'app',
      'languages',
      'en',
      'common.ts'
    );
    // The seed with only its `siteName` quoting changed, so the `someOtherKey`
    // assertion below stays anchored to the shape the fixture actually ships.
    writeFileSync(
      target,
      COMMON_TS.replace("'GAIA'", '"Steve\'s Template"'),
      'utf8'
    );

    expect(
      run(['--title', 'Hello World', '--kebab', 'hello-world'], {
        cwd: sandbox.root,
      })
    ).toBe(0);

    const common = evaluateDefaultExport(readFileSync(target, 'utf8'));
    expect((common.meta as Record<string, unknown>).siteName).toBe(
      'Hello World'
    );
    expect(common.someOtherKey).toBe('untouched');
  });

  // The same class applied to this command's own output. The escaper leaves the
  // non-wrapping quote bare, because it needs no escape, so a first rename can
  // write a literal the second rename is then unable to match.
  test('re-renames a value holding the quote its literal is not wrapped in', () => {
    sandbox = setupSandbox();
    const target = path.join(
      sandbox.root,
      'app',
      'languages',
      'en',
      'common.ts'
    );

    expect(
      run(['--title', 'Say "Hi" App', '--kebab', 'hello-world'], {
        cwd: sandbox.root,
      })
    ).toBe(0);
    // Written into a single-quoted seed, so the `"` lands bare: this is the
    // input the second run has to match, asserted on the bytes so the test
    // fails here rather than downstream if the escaper ever changes.
    expect(readFileSync(target, 'utf8')).toContain(
      'siteName: \'Say "Hi" App\''
    );

    expect(
      run(['--title', 'Second Title', '--kebab', 'hello-world'], {
        cwd: sandbox.root,
      })
    ).toBe(0);

    const common = evaluateDefaultExport(readFileSync(target, 'utf8'));
    expect((common.meta as Record<string, unknown>).siteName).toBe(
      'Second Title'
    );
  });

  test.each([
    ['an apostrophe', APOSTROPHE_TITLE],
    ['a `$&` whole-match reference', MATCH_REF_TITLE],
  ])(
    're-running with the same awkward title is still a no-op: %s',
    (_label, title) => {
      sandbox = setupSandbox();
      const args = ['--title', title, '--kebab', 'hello-world'];
      run(args, {cwd: sandbox.root});
      const first = readFileSync(
        path.join(sandbox.root, 'app', 'languages', 'en', 'common.ts'),
        'utf8'
      );

      expect(run(args, {cwd: sandbox.root})).toBe(0);
      expect(
        readFileSync(
          path.join(sandbox.root, 'app', 'languages', 'en', 'common.ts'),
          'utf8'
        )
      ).toBe(first);
    }
  );

  // A key the rewriter cannot match is a precondition failure, the answer this
  // module already settled for the missing `CLAUDE.md` heading. Exiting 0 over
  // an untouched file reports a rename that did not happen, and the adopter
  // finds out from the running app rather than from the command.
  test.each([
    ['a template literal', 'siteName: `GAIA`,'],
    ['a computed value', 'siteName: buildSiteName(),'],
  ])(
    'exit 1 when common.ts `siteName` is not a rewritable literal: %s',
    (_label, line) => {
      sandbox = setupSandbox();
      const target = path.join(
        sandbox.root,
        'app',
        'languages',
        'en',
        'common.ts'
      );
      const content = `export default {\n  meta: {\n    ${line}\n  },\n};\n`;
      writeFileSync(target, content, 'utf8');

      const exit = run(['--title', 'Hello World', '--kebab', 'hello-world'], {
        cwd: sandbox.root,
      });
      expect(exit).toBe(1);
      expect(stdio.errors.join('')).toContain('language_value_not_rewritable');
      expect(stdio.errors.join('')).toContain('siteName');

      // Checked ahead of the first write, so a refused run renamed nothing and
      // the step is not recorded as completed.
      expect(readFileSync(target, 'utf8')).toBe(content);
      const pkg = JSON.parse(
        readFileSync(path.join(sandbox.root, 'package.json'), 'utf8')
      ) as {name: string};
      expect(pkg.name).toBe('gaia');
      expect(readState(sandbox.root).completed_steps).not.toContain('rename');
    }
  );

  test('exit 1 when a seeded _index.ts key is not a rewritable literal', () => {
    sandbox = setupSandbox();
    const target = path.join(
      sandbox.root,
      'app',
      'languages',
      'en',
      'pages',
      '_index.ts'
    );
    writeFileSync(
      target,
      'export default {\n  heroTitle: buildHero(),\n  title: 1,\n};\n',
      'utf8'
    );

    expect(
      run(['--title', 'Hello World', '--kebab', 'hello-world'], {
        cwd: sandbox.root,
      })
    ).toBe(1);
    expect(stdio.errors.join('')).toContain('language_value_not_rewritable');
    expect(stdio.errors.join('')).toContain('heroTitle');
    expect(readState(sandbox.root).completed_steps).not.toContain('rename');
  });

  // The keys are optional, not required: the shipped `_index.ts` carries only
  // `meta.title`, so a file missing `heroTitle` and a top-level `title`
  // entirely has to stay a clean pass. Only a key that is present and
  // unmatchable fails.
  test('a language file missing the optional keys still succeeds', () => {
    sandbox = setupSandbox();
    const target = path.join(
      sandbox.root,
      'app',
      'languages',
      'en',
      'pages',
      '_index.ts'
    );
    writeFileSync(
      target,
      "export default {\n  meta: {\n    description: 'Description of the index page',\n    title: 'Index Page',\n  },\n};\n",
      'utf8'
    );

    expect(
      run(['--title', 'Hello World', '--kebab', 'hello-world'], {
        cwd: sandbox.root,
      })
    ).toBe(0);

    const page = evaluateDefaultExport(readFileSync(target, 'utf8'));
    expect((page.meta as Record<string, unknown>).title).toBe('Hello World');
  });
});

/**
 * `gaia init rename` refuses when `CLAUDE.md` carries no heading, so the
 * shipped template has to carry one or every adopter scaffold fails the
 * step. Nothing that runs on a CLAUDE.md-only change asserts that, which is
 * how the heading was dropped unnoticed.
 *
 * Asserted through `claudeMdHasH1`, the predicate the step itself uses, so
 * tightening the production rule cannot leave this pinning the older, looser
 * shape.
 *
 * Its own `describe`: the suite above tears down a sandbox after every test
 * and this one allocates none.
 */
describe('CLAUDE.md template invariant', () => {
  test('the shipped CLAUDE.md carries an H1 for rename to rewrite', () => {
    const repoRoot = resolveRepoRootFromImportMeta(import.meta.url);
    const claudeMd = readFileSync(path.join(repoRoot, 'CLAUDE.md'), 'utf8');

    expect(claudeMdHasH1(claudeMd)).toBe(true);
  });
});

/**
 * The same invariant for the other sink: the shipped language files have to
 * come back actually renamed, or every adopter scaffold finishes Step 6 of
 * `/gaia-init` still carrying GAIA's title. Every test above writes its own
 * fixture, so nothing else reads the files that ship.
 *
 * Asserted by renaming the real files rather than by asking the precondition
 * about them, because the two fail on different things and only one of them is
 * the invariant. The precondition reports a key it can see but cannot rewrite,
 * so it is silent on a key it cannot see at all: reindenting `_index.ts`, or
 * nesting `meta` a level deeper, moves `meta.title` out of the anchored pattern
 * and the precondition returns "nothing wrong" for a file nothing will rewrite.
 * Running the step and reading the values back fails on that, on a
 * non-rewritable value, and on the file going missing alike.
 */
describe('language template invariant', () => {
  test('the shipped language files come back carrying the new title', () => {
    const repoRoot = resolveRepoRootFromImportMeta(import.meta.url);
    const root = mkdtempSync(path.join(tmpdir(), 'gaia-init-rename-shipped-'));

    try {
      writeFileSync(
        path.join(root, 'package.json'),
        `${PACKAGE_JSON}\n`,
        'utf8'
      );
      writeFileSync(path.join(root, 'CLAUDE.md'), CLAUDE_MD, 'utf8');
      mkdirSync(path.join(root, 'app', 'languages', 'en', 'pages'), {
        recursive: true,
      });
      copyFileSync(
        path.join(repoRoot, 'app', 'languages', 'en', 'common.ts'),
        path.join(root, 'app', 'languages', 'en', 'common.ts')
      );
      copyFileSync(
        path.join(repoRoot, 'app', 'languages', 'en', 'pages', '_index.ts'),
        path.join(root, 'app', 'languages', 'en', 'pages', '_index.ts')
      );

      expect(
        run(['--title', 'Hello World', '--kebab', 'hello-world'], {cwd: root})
      ).toBe(0);

      const common = evaluateDefaultExport(
        readFileSync(path.join(root, 'app', 'languages', 'en', 'common.ts'), {
          encoding: 'utf8',
        })
      );
      expect((common.meta as Record<string, unknown>).siteName).toBe(
        'Hello World'
      );

      const page = evaluateDefaultExport(
        readFileSync(
          path.join(root, 'app', 'languages', 'en', 'pages', '_index.ts'),
          {encoding: 'utf8'}
        )
      );
      expect((page.meta as Record<string, unknown>).title).toBe('Hello World');
    } finally {
      rmSync(root, {force: true, recursive: true});
    }
  });
});
