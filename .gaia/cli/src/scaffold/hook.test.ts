import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {execGaiaGit} from '../util/git-env.js';
import {run} from './hook.js';

type Sandbox = {
  cleanup: () => void;
  repoRoot: string;
};

const setupSandbox = (): Sandbox => {
  const repoRoot = mkdtempSync(path.join(tmpdir(), 'gaia-scaffold-hook-'));

  return {
    cleanup: () => {
      rmSync(repoRoot, {force: true, recursive: true});
    },
    repoRoot,
  };
};

const read = (filePath: string): string => readFileSync(filePath, 'utf8');

const captureStdout = (): {restore: () => void; written: string[]} => {
  const written: string[] = [];
  const original = process.stdout.write.bind(process.stdout);
  const spy = vi
    .spyOn(process.stdout, 'write')
    .mockImplementation((chunk: unknown): boolean => {
      written.push(typeof chunk === 'string' ? chunk : String(chunk));

      return true;
    });

  return {
    restore: () => {
      spy.mockRestore();
      // restore original binding to be safe across tests
      process.stdout.write = original;
    },
    written,
  };
};

const captureStderr = (): {restore: () => void; written: string[]} => {
  const written: string[] = [];
  const original = process.stderr.write.bind(process.stderr);
  const spy = vi
    .spyOn(process.stderr, 'write')
    .mockImplementation((chunk: unknown): boolean => {
      written.push(typeof chunk === 'string' ? chunk : String(chunk));

      return true;
    });

  return {
    restore: () => {
      spy.mockRestore();
      process.stderr.write = original;
    },
    written,
  };
};

describe('gaia scaffold hook', () => {
  let sandbox: Sandbox;

  beforeEach(() => {
    sandbox = setupSandbox();
  });

  afterEach(() => {
    sandbox.cleanup();
  });

  test('emits hook + test for a bare name', () => {
    const stdout = captureStdout();

    try {
      const code = run(['useFoo'], {repoRoot: sandbox.repoRoot});

      expect(code).toBe(0);
    } finally {
      stdout.restore();
    }

    const hookPath = path.join(sandbox.repoRoot, 'app/hooks/useFoo.ts');
    const testPath = path.join(
      sandbox.repoRoot,
      'app/hooks/tests/useFoo.test.ts'
    );

    expect(read(hookPath)).toBe(
      [
        'export const useFoo = () => {',
        '  // TODO: implement useFoo',
        '};',
        '',
      ].join('\n')
    );

    expect(read(testPath)).toBe(
      [
        "import {renderHook} from '@testing-library/react';",
        "import {describe, expect, test} from 'vitest';",
        "import {useFoo} from '../useFoo';",
        '',
        "describe('useFoo', () => {",
        "  test('renders without crashing', () => {",
        '    const {result} = renderHook(() => useFoo());',
        '',
        '    expect(result.current).toBeDefined();',
        '  });',
        '});',
        '',
      ].join('\n')
    );
  });

  test('renders typed params from --params', () => {
    const stdout = captureStdout();

    try {
      const code = run(['useFoo', '--params', 'id:string,count:number'], {
        repoRoot: sandbox.repoRoot,
      });

      expect(code).toBe(0);
    } finally {
      stdout.restore();
    }

    const hookContents = read(
      path.join(sandbox.repoRoot, 'app/hooks/useFoo.ts')
    );

    expect(hookContents).toContain(
      'export const useFoo = (id: string, count: number) => {'
    );

    const testContents = read(
      path.join(sandbox.repoRoot, 'app/hooks/tests/useFoo.test.ts')
    );

    expect(testContents).toContain("renderHook(() => useFoo('', 0))");
  });

  test('renders return-type annotation from --returns', () => {
    const stdout = captureStdout();

    try {
      const code = run(['useFoo', '--returns', 'string'], {
        repoRoot: sandbox.repoRoot,
      });

      expect(code).toBe(0);
    } finally {
      stdout.restore();
    }

    const hookContents = read(
      path.join(sandbox.repoRoot, 'app/hooks/useFoo.ts')
    );

    expect(hookContents).toContain('export const useFoo = (): string => {');
  });

  test('combines --params and --returns', () => {
    const stdout = captureStdout();

    try {
      const code = run(
        ['useFoo', '--params', 'id:string', '--returns', 'boolean'],
        {repoRoot: sandbox.repoRoot}
      );

      expect(code).toBe(0);
    } finally {
      stdout.restore();
    }

    const hookContents = read(
      path.join(sandbox.repoRoot, 'app/hooks/useFoo.ts')
    );

    expect(hookContents).toContain(
      'export const useFoo = (id: string): boolean => {'
    );
  });

  test('rejects names that do not start with `use`', () => {
    const stderr = captureStderr();

    try {
      const code = run(['foo'], {repoRoot: sandbox.repoRoot});

      expect(code).toBe(1);
    } finally {
      stderr.restore();
    }

    const payload = JSON.parse(stderr.written.join('').trim()) as {
      code: string;
    };

    expect(payload.code).toBe('invalid_hook_name');
  });

  test('rejects names that start with `use` but are not camelCase', () => {
    const stderr = captureStderr();

    try {
      // `usefoo` is lowercase after the prefix; must be `useF...`.
      const code = run(['usefoo'], {repoRoot: sandbox.repoRoot});

      expect(code).toBe(1);
    } finally {
      stderr.restore();
    }

    const payload = JSON.parse(stderr.written.join('').trim()) as {
      code: string;
    };

    expect(payload.code).toBe('invalid_hook_name');
  });

  test('rejects when no name is supplied', () => {
    const stderr = captureStderr();

    try {
      const code = run([], {repoRoot: sandbox.repoRoot});

      expect(code).toBe(1);
    } finally {
      stderr.restore();
    }

    const payload = JSON.parse(stderr.written.join('').trim()) as {
      code: string;
    };

    expect(payload.code).toBe('missing_argument');
  });

  test('is idempotent: second invocation reports skipped', () => {
    const stdoutA = captureStdout();

    try {
      run(['useFoo'], {repoRoot: sandbox.repoRoot});
    } finally {
      stdoutA.restore();
    }

    const stdoutB = captureStdout();
    let code = -1;

    try {
      code = run(['useFoo', '--json'], {repoRoot: sandbox.repoRoot});
    } finally {
      stdoutB.restore();
    }

    expect(code).toBe(0);
    const payload = JSON.parse(stdoutB.written.join('').trim()) as {
      edited: string[];
      skipped: string[];
      written: string[];
    };

    expect(payload.written).toEqual([]);
    expect(payload.edited).toEqual([]);
    expect(payload.skipped).toHaveLength(2);
  });

  test('refuses to overwrite a customized file', () => {
    const hookPath = path.join(sandbox.repoRoot, 'app/hooks/useFoo.ts');
    const stdoutA = captureStdout();

    try {
      run(['useFoo'], {repoRoot: sandbox.repoRoot});
    } finally {
      stdoutA.restore();
    }
    // user customizes the file
    writeFileSync(hookPath, '// hand-edited\n', 'utf8');

    const stderr = captureStderr();
    let code = -1;

    try {
      code = run(['useFoo'], {repoRoot: sandbox.repoRoot});
    } finally {
      stderr.restore();
    }

    expect(code).toBe(11);
    const payload = JSON.parse(stderr.written.join('').trim()) as {
      code: string;
    };

    expect(payload.code).toBe('scaffold_failed');
    // original customization survives
    expect(read(hookPath)).toBe('// hand-edited\n');
  });

  test('--json prints a single ScaffoldResult line on stdout', () => {
    const stdout = captureStdout();
    let code = -1;

    try {
      code = run(['useFoo', '--json'], {repoRoot: sandbox.repoRoot});
    } finally {
      stdout.restore();
    }

    expect(code).toBe(0);
    const raw = stdout.written.join('');
    expect(raw.endsWith('\n')).toBe(true);
    const lines = raw.trim().split('\n');
    expect(lines).toHaveLength(1);
    const payload = JSON.parse(lines[0] ?? '') as {
      edited: string[];
      skipped: string[];
      written: string[];
    };

    expect(payload.written).toHaveLength(2);
    expect(payload.edited).toEqual([]);
    expect(payload.skipped).toEqual([]);

    for (const file of payload.written) {
      expect(path.isAbsolute(file)).toBe(true);
    }
  });

  test('rejects unknown flags', () => {
    const stderr = captureStderr();
    let code = -1;

    try {
      code = run(['useFoo', '--bogus'], {repoRoot: sandbox.repoRoot});
    } finally {
      stderr.restore();
    }

    expect(code).toBe(1);
    const payload = JSON.parse(stderr.written.join('').trim()) as {
      code: string;
    };

    expect(payload.code).toBe('invalid_flag');
  });
});

/**
 * Root resolution when the caller passes no `repoRoot`. Every test above
 * supplies one, so the default path -- the only path the shipped binary ever
 * takes -- had no coverage at all, and a refusal added to it reached the
 * release harness before anything caught it.
 */
describe('gaia scaffold hook root resolution', () => {
  let cwdBefore: string;
  let scratch: string[];

  beforeEach(() => {
    cwdBefore = process.cwd();
    scratch = [];
  });

  afterEach(() => {
    process.chdir(cwdBefore);

    for (const dir of scratch) {
      rmSync(dir, {force: true, recursive: true});
    }
  });

  // `os.tmpdir()` is a symlink on macOS, and `process.cwd()` reports the
  // physically resolved path, so the expectations below only line up against a
  // realpath'd root.
  const newScratchDir = (): string => {
    const dir = realpathSync(
      mkdtempSync(path.join(tmpdir(), 'gaia-hook-root-'))
    );
    scratch.push(dir);

    return dir;
  };

  test('scaffolds into the current directory outside a git repository', () => {
    const root = newScratchDir();
    const stdout = captureStdout();
    let code = -1;

    process.chdir(root);

    try {
      code = run(['useFoo']);
    } finally {
      stdout.restore();
    }

    expect(code).toBe(0);
    expect(existsSync(path.join(root, 'app/hooks/useFoo.ts'))).toBe(true);
    expect(existsSync(path.join(root, 'app/hooks/tests/useFoo.test.ts'))).toBe(
      true
    );
  });

  test('scaffolds into the working tree root, not the calling subdirectory', () => {
    const root = newScratchDir();
    // Through the chokepoint, not a bare `execFileSync('git', ...)`: an
    // ambient GIT_DIR would send `git init` at the directory that variable
    // names, leaving `root` without a `.git` and this assertion measuring
    // nothing.
    execGaiaGit(['init', '-q', '-b', 'main'], root);
    const inner = path.join(root, 'packages', 'inner');
    mkdirSync(inner, {recursive: true});
    const stdout = captureStdout();
    let code = -1;

    process.chdir(inner);

    try {
      code = run(['useBar']);
    } finally {
      stdout.restore();
    }

    expect(code).toBe(0);
    expect(existsSync(path.join(root, 'app/hooks/useBar.ts'))).toBe(true);
    expect(existsSync(path.join(inner, 'app/hooks/useBar.ts'))).toBe(false);
  });
});
