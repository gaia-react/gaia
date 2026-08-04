import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
/**
 * Tests for `gaia init strip-branding`.
 */
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {run} from './strip-branding.js';
import {readState} from './util/state.js';

type Sandbox = {
  cleanup: () => void;
  root: string;
};

const TEMPLATE_README =
  '# {{PROJECT_TITLE}}\n\nWelcome to {{PROJECT_TITLE}}!\n';

const PREVIEW_BEFORE = `import type {Preview} from '@storybook/react-vite';
import {themes} from 'storybook/theming';
import '~/styles/tailwind.css';

const BRAND = {
  brandTarget: '_blank',
  brandTitle: 'GAIA',
  brandUrl: 'https://gaiareact.com/docs/',
};

const preview: Preview = {
  parameters: {
    darkMode: {
      dark: {...themes.dark, ...BRAND},
      light: {...themes.light, ...BRAND},
    },
  },
};

export default preview;
`;

const setupSandbox = (): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-init-strip-branding-'));
  mkdirSync(path.join(root, '.github'), {recursive: true});
  writeFileSync(
    path.join(root, '.github', 'FUNDING.yml'),
    'github: gaia\n',
    'utf8'
  );
  mkdirSync(path.join(root, '.gaia', 'templates'), {recursive: true});
  writeFileSync(
    path.join(root, '.gaia', 'templates', 'README.md'),
    TEMPLATE_README,
    'utf8'
  );
  writeFileSync(path.join(root, 'README.md'), '# GAIA stale\n', 'utf8');
  mkdirSync(path.join(root, '.storybook'), {recursive: true});
  writeFileSync(
    path.join(root, '.storybook', 'preview.ts'),
    PREVIEW_BEFORE,
    'utf8'
  );

  return {
    cleanup: () => {
      rmSync(root, {force: true, recursive: true});
    },
    root,
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

/**
 * Assert a refused run wrote nothing at all.
 *
 * `removeIfPresent(FUNDING_PATH)` is the first write `run` performs, so the
 * FUNDING assertion is what pins the refusal ahead of it: without it, moving a
 * rule below that call leaves the whole suite green.
 */
const expectNothingWritten = (root: string): void => {
  expect(existsSync(path.join(root, '.github', 'FUNDING.yml'))).toBe(true);
  expect(readFileSync(path.join(root, 'README.md'), 'utf8')).toBe(
    '# GAIA stale\n'
  );
  expect(
    readFileSync(path.join(root, '.storybook', 'preview.ts'), 'utf8')
  ).toBe(PREVIEW_BEFORE);
  expect(readState(root).completed_steps).not.toContain('strip-branding');
};

describe('init strip-branding', () => {
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

  test('removes FUNDING, replaces README, personalizes Storybook brand, records state', () => {
    sandbox = setupSandbox();

    const exit = run(['--title', 'Hello World'], {cwd: sandbox.root});
    expect(exit).toBe(0);
    expect(stdio.outputs.join('')).toBe('');
    expect(stdio.errors.join('')).toBe('');

    expect(existsSync(path.join(sandbox.root, '.github', 'FUNDING.yml'))).toBe(
      false
    );

    const readme = readFileSync(path.join(sandbox.root, 'README.md'), 'utf8');
    expect(readme).toBe('# Hello World\n\nWelcome to Hello World!\n');

    const preview = readFileSync(
      path.join(sandbox.root, '.storybook', 'preview.ts'),
      'utf8'
    );
    expect(preview).not.toContain("brandTitle: 'GAIA'");
    expect(preview).not.toContain('gaiareact.com');
    expect(preview).toContain("brandTitle: 'Hello World'");

    const state = readState(sandbox.root);
    expect(state.completed_steps).toContain('strip-branding');
    expect(state.step_args['strip-branding']).toEqual({title: 'Hello World'});
  });

  test('idempotent: re-running is a no-op', () => {
    sandbox = setupSandbox();

    const first = run(['--title', 'Hello World'], {cwd: sandbox.root});
    expect(first).toBe(0);

    const previewAfter = readFileSync(
      path.join(sandbox.root, '.storybook', 'preview.ts'),
      'utf8'
    );

    const second = run(['--title', 'Hello World'], {cwd: sandbox.root});
    expect(second).toBe(0);

    const previewSecond = readFileSync(
      path.join(sandbox.root, '.storybook', 'preview.ts'),
      'utf8'
    );
    expect(previewSecond).toBe(previewAfter);

    const state = readState(sandbox.root);
    const stripCount = state.completed_steps.filter(
      (step) => step === 'strip-branding'
    ).length;
    expect(stripCount).toBe(1);
  });

  test('exit 1 when --title missing', () => {
    sandbox = setupSandbox();
    const exit = run([], {cwd: sandbox.root});
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('--title is required');
  });

  // A title carrying a line ending is spliced into a single-quoted JavaScript
  // string literal in `.storybook/preview.ts`, which emits an unterminated
  // literal and leaves the adopter's fresh scaffold unable to build Storybook.
  // Refused in `parseFlags`, ahead of the first write.
  test.each([
    ['a newline', 'Bad\nInjected'],
    ['a carriage return', 'Bad\rInjected'],
    ['a trailing newline', 'Bad\n'],
  ])('exit 1 on a multi-line title: %s', (_label, title) => {
    sandbox = setupSandbox();

    const exit = run(['--title', title], {cwd: sandbox.root});
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('--title must be a single line');

    expectNothingWritten(sandbox.root);
  });

  // A blank title writes `# ` as the README heading, because the template's
  // first line is `# {{PROJECT_TITLE}}`: a README carrying a heading and no
  // title, the same state `rename` refuses in CLAUDE.md.
  test.each([
    ['empty', ''],
    ['whitespace only', ' '.repeat(3)],
  ])('exit 1 on a blank title: %s', (_label, title) => {
    sandbox = setupSandbox();

    const exit = run(['--title', title], {cwd: sandbox.root});
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('--title must not be blank');

    expectNothingWritten(sandbox.root);
  });

  // A title carrying a quote, a backslash or a `$` is an ordinary title and is
  // escaped rather than refused, which is the other half of the policy the two
  // refusal rules above encode. Scoped to this command's own sink: these rows
  // assert what `debrandStorybook` does, and say nothing about any other sink.
  test.each([
    ['an apostrophe', "Steve's App", String.raw`Steve\'s App`],
    ['a backslash', String.raw`A\B`, String.raw`A\\B`],
    ['a dollar token', 'Q1 $1 Report', 'Q1 $1 Report'],
  ])('accepts a title carrying %s', (_label, title, expected) => {
    sandbox = setupSandbox();

    const exit = run(['--title', title], {cwd: sandbox.root});
    expect(exit).toBe(0);

    const preview = readFileSync(
      path.join(sandbox.root, '.storybook', 'preview.ts'),
      'utf8'
    );
    expect(preview).toContain(`brandTitle: '${expected}',`);
  });

  test('exit 1 when README template missing', () => {
    sandbox = setupSandbox();
    rmSync(path.join(sandbox.root, '.gaia', 'templates', 'README.md'));

    const exit = run(['--title', 'X'], {cwd: sandbox.root});
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('template_missing');
  });

  test('rejects unknown flags', () => {
    sandbox = setupSandbox();
    const exit = run(['--bogus'], {cwd: sandbox.root});
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('unknown flag');
  });
});
