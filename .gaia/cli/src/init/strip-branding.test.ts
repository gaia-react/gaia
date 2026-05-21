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
import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {run} from './strip-branding.js';
import {readState} from './util/state.js';

type Sandbox = {
  cleanup: () => void;
  root: string;
};

const HEADER_BEFORE = `import type {FC} from 'react';
import {useTranslation} from 'react-i18next';
import {Link} from 'react-router';
import GaiaLogo from '~/components/GaiaLogo';

const Header: FC = () => {
  const {t} = useTranslation('common');

  return (
    <header>
      <Link aria-label={t('meta.siteName')} to="/">
        <GaiaLogo className="h-6 sm:h-7" />
      </Link>
    </header>
  );
};

export default Header;
`;

const TEMPLATE_README =
  '# {{PROJECT_TITLE}}\n\nWelcome to {{PROJECT_TITLE}}!\n';

const setupSandbox = (): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-init-strip-branding-'));
  mkdirSync(path.join(root, '.github'), {recursive: true});
  writeFileSync(path.join(root, '.github', 'FUNDING.yml'), 'github: gaia\n', 'utf8');
  mkdirSync(path.join(root, 'app', 'components', 'GaiaLogo'), {recursive: true});
  writeFileSync(
    path.join(root, 'app', 'components', 'GaiaLogo', 'index.tsx'),
    'export default () => null;\n',
    'utf8'
  );
  mkdirSync(path.join(root, 'app', 'components', 'Header'), {recursive: true});
  writeFileSync(
    path.join(root, 'app', 'components', 'Header', 'index.tsx'),
    HEADER_BEFORE,
    'utf8'
  );
  mkdirSync(path.join(root, '.gaia', 'templates'), {recursive: true});
  writeFileSync(
    path.join(root, '.gaia', 'templates', 'README.md'),
    TEMPLATE_README,
    'utf8'
  );
  writeFileSync(path.join(root, 'README.md'), '# GAIA stale\n', 'utf8');

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

  test('removes branding files, replaces README, edits Header, records state', () => {
    sandbox = setupSandbox();

    const exit = run(['--title', 'Hello World'], {cwd: sandbox.root});
    expect(exit).toBe(0);
    expect(stdio.outputs.join('')).toBe('');
    expect(stdio.errors.join('')).toBe('');

    expect(existsSync(path.join(sandbox.root, '.github', 'FUNDING.yml'))).toBe(false);
    expect(existsSync(path.join(sandbox.root, 'app', 'components', 'GaiaLogo'))).toBe(
      false
    );

    const readme = readFileSync(path.join(sandbox.root, 'README.md'), 'utf8');
    expect(readme).toBe('# Hello World\n\nWelcome to Hello World!\n');

    const header = readFileSync(
      path.join(sandbox.root, 'app', 'components', 'Header', 'index.tsx'),
      'utf8'
    );
    expect(header).not.toContain('GaiaLogo');
    expect(header).toContain(
      "<span className=\"text-body text-xl font-bold\">{t('meta.siteName')}</span>"
    );

    const state = readState(sandbox.root);
    expect(state.completed_steps).toContain('strip-branding');
    expect(state.step_args['strip-branding']).toEqual({title: 'Hello World'});
  });

  test('idempotent: re-running is a no-op', () => {
    sandbox = setupSandbox();

    const first = run(['--title', 'Hello World'], {cwd: sandbox.root});
    expect(first).toBe(0);

    const headerAfter = readFileSync(
      path.join(sandbox.root, 'app', 'components', 'Header', 'index.tsx'),
      'utf8'
    );

    const second = run(['--title', 'Hello World'], {cwd: sandbox.root});
    expect(second).toBe(0);

    const headerSecond = readFileSync(
      path.join(sandbox.root, 'app', 'components', 'Header', 'index.tsx'),
      'utf8'
    );
    expect(headerSecond).toBe(headerAfter);

    const state = readState(sandbox.root);
    const stripCount = state.completed_steps.filter((step) => step === 'strip-branding')
      .length;
    expect(stripCount).toBe(1);
  });

  test('replaces a paired <GaiaLogo>…</GaiaLogo> element', () => {
    sandbox = setupSandbox();
    const pairedHeader = `import GaiaLogo from '~/components/GaiaLogo';

const Header = () => (
  <header>
    <GaiaLogo className="h-6 sm:h-7">brand</GaiaLogo>
  </header>
);

export default Header;
`;
    writeFileSync(
      path.join(sandbox.root, 'app', 'components', 'Header', 'index.tsx'),
      pairedHeader,
      'utf8'
    );

    const exit = run(['--title', 'Hello World'], {cwd: sandbox.root});
    expect(exit).toBe(0);

    const header = readFileSync(
      path.join(sandbox.root, 'app', 'components', 'Header', 'index.tsx'),
      'utf8'
    );
    expect(header).not.toContain('GaiaLogo');
    expect(header).toContain(
      "<span className=\"text-body text-xl font-bold\">{t('meta.siteName')}</span>"
    );
  });

  test('exit 1 when --title missing', () => {
    sandbox = setupSandbox();
    const exit = run([], {cwd: sandbox.root});
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('--title is required');
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
