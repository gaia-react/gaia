import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
/**
 * Tests for `gaia init configure-i18n`.
 */
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {run} from './configure-i18n.js';
import {readState} from './util/state.js';

type Sandbox = {
  cleanup: () => void;
  root: string;
};

const LANGUAGES_INDEX_TEMPLATE = `import en from './en';

export const LANGUAGES = ['en'];

export type Language = 'en';

export default {en} as const;
`;

const I18N_TEMPLATE = `import resources, {LANGUAGES} from '~/languages';

const i18n = {
  defaultNS: 'common',
  fallbackLng: 'en',
  fallbackNS: ['common'],
  resources,
  supportedLngs: LANGUAGES,
};

export default i18n;
`;

const setupSandbox = (): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-init-configure-i18n-'));
  mkdirSync(path.join(root, 'app', 'languages'), {recursive: true});
  writeFileSync(
    path.join(root, 'app', 'languages', 'index.ts'),
    LANGUAGES_INDEX_TEMPLATE,
    'utf8'
  );
  writeFileSync(path.join(root, 'app', 'i18n.ts'), I18N_TEMPLATE, 'utf8');

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

describe('init configure-i18n', () => {
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

  test('--strip false expands LANGUAGES + Language union, updates fallback', () => {
    sandbox = setupSandbox();

    const exit = run(['--locales', 'en,es,ja', '--strip', 'false'], {
      cwd: sandbox.root,
    });
    expect(exit).toBe(0);

    const indexAfter = readFileSync(
      path.join(sandbox.root, 'app', 'languages', 'index.ts'),
      'utf8'
    );
    expect(indexAfter).toContain("import en from './en';");
    expect(indexAfter).toContain("import es from './es';");
    expect(indexAfter).toContain("import ja from './ja';");
    expect(indexAfter).toContain(
      "export const LANGUAGES = ['en', 'es', 'ja'];"
    );
    expect(indexAfter).toContain("export type Language = 'en' | 'es' | 'ja';");
    expect(indexAfter).toContain('export default {en, es, ja}');

    const i18nAfter = readFileSync(
      path.join(sandbox.root, 'app', 'i18n.ts'),
      'utf8'
    );
    expect(i18nAfter).toContain("fallbackLng: 'en'");

    const state = readState(sandbox.root);
    expect(state.completed_steps).toContain('configure-i18n');
    expect(state.step_args['configure-i18n']).toEqual({
      locales: ['en', 'es', 'ja'],
      strip: false,
    });
  });

  test('--strip true skips edits but records state', () => {
    sandbox = setupSandbox();
    const before = readFileSync(
      path.join(sandbox.root, 'app', 'languages', 'index.ts'),
      'utf8'
    );

    const exit = run(['--locales', 'en', '--strip', 'true'], {
      cwd: sandbox.root,
    });
    expect(exit).toBe(0);

    const after = readFileSync(
      path.join(sandbox.root, 'app', 'languages', 'index.ts'),
      'utf8'
    );
    expect(after).toBe(before);

    const state = readState(sandbox.root);
    expect(state.step_args['configure-i18n']).toEqual({
      locales: ['en'],
      strip: true,
    });
  });

  test('idempotent: re-running with same args is a no-op on file content', () => {
    sandbox = setupSandbox();
    run(['--locales', 'en,es', '--strip', 'false'], {cwd: sandbox.root});
    const first = readFileSync(
      path.join(sandbox.root, 'app', 'languages', 'index.ts'),
      'utf8'
    );

    const second = run(['--locales', 'en,es', '--strip', 'false'], {
      cwd: sandbox.root,
    });
    expect(second).toBe(0);
    const after = readFileSync(
      path.join(sandbox.root, 'app', 'languages', 'index.ts'),
      'utf8'
    );
    expect(after).toBe(first);
  });

  test('exit 1 on missing flags', () => {
    sandbox = setupSandbox();
    expect(run(['--locales', 'en'], {cwd: sandbox.root})).toBe(1);
    expect(run(['--strip', 'true'], {cwd: sandbox.root})).toBe(1);
  });

  test('exit 1 on invalid --strip value', () => {
    sandbox = setupSandbox();
    const exit = run(['--locales', 'en', '--strip', 'yes'], {
      cwd: sandbox.root,
    });
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('--strip must be');
  });

  test('exit 1 on invalid --locales list', () => {
    sandbox = setupSandbox();
    const exit = run(['--locales', '???', '--strip', 'false'], {
      cwd: sandbox.root,
    });
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('invalid --locales');
  });
});
