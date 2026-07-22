import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
/**
 * Tests for the `gaia-maintainer release manifest --check` path: drift
 * reporting (missing/extra/class/version drift), classifier-set overlap and
 * scan-scope lint surfacing, and the malformed/missing-manifest error cases.
 *
 * The emit/answer-gate tests (`--ship`/`--withhold`/`--allow-undecided`,
 * `--out`/`--stdout`) live in `manifest-cli.test.ts`. The flag-grammar tests
 * live in `manifest-cli-args.test.ts`.
 */
import {execFileSync} from 'node:child_process';
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {run} from './manifest-cli.js';

type Sandbox = {
  cleanup: () => void;
  commit: (message: string, files: Record<string, string>) => string;
  root: string;
};

const setupSandbox = (): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-release-manifest-'));
  execFileSync('git', ['init', '-q', '-b', 'main'], {cwd: root});
  execFileSync('git', ['config', 'user.email', 'test@example.com'], {
    cwd: root,
  });
  execFileSync('git', ['config', 'user.name', 'Test'], {cwd: root});
  execFileSync('git', ['config', 'commit.gpgsign', 'false'], {cwd: root});

  const commit = (message: string, files: Record<string, string>): string => {
    for (const [relativePath, contents] of Object.entries(files)) {
      const absPath = path.join(root, relativePath);
      mkdirSync(path.dirname(absPath), {recursive: true});
      writeFileSync(absPath, contents, 'utf8');
    }
    execFileSync('git', ['add', '-A'], {cwd: root});
    execFileSync('git', ['commit', '-q', '-m', message], {cwd: root});

    return execFileSync('git', ['rev-parse', 'HEAD'], {
      cwd: root,
      encoding: 'utf8',
    }).trim();
  };

  return {
    cleanup: () => {
      rmSync(root, {force: true, recursive: true});
    },
    commit,
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

type ManifestDriftJson = {
  drift: {actual: string; expected: string; file: string}[];
  extra: {actual: string; file: string}[];
  missing: {expected: string; file: string}[];
};

describe('run --check', () => {
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

  const seedAndGenerate = (extraFiles: Record<string, string> = {}): void => {
    sandbox.commit('seed', {
      '.gaia/release-exclude': '# none\n',
      '.gaia/VERSION': '1.0.0\n',
      'app/foo.ts': 'export {};\n',
      'CLAUDE.md': '# CLAUDE\n',
      'wiki/concepts/Bar.md': '# bar\n',
      'wiki/index.md': '# index\n',
      ...extraFiles,
    });

    // No committed manifest yet, so every classified path is unanswered; the
    // escape hatch is how a manifest gets bootstrapped from nothing.
    const exit = run(['--allow-undecided'], {
      cwd: sandbox.root,
      generatedAt: '2026-05-07T00:00:00.000Z',
    });
    expect(exit).toBe(0);
    stdio.outputs.length = 0;
  };

  test('clean case: exits 0 with empty diff', () => {
    seedAndGenerate();

    const exit = run(['--check'], {
      cwd: sandbox.root,
      generatedAt: '2026-05-07T00:00:00.000Z',
    });

    expect(exit).toBe(0);
    expect(stdio.outputs.join('')).toContain('clean');
    expect(stdio.errors.join('')).toBe('');
  });

  test('missing entry: exits non-zero and names the missing file', () => {
    seedAndGenerate();

    const manifestPath = path.join(sandbox.root, '.gaia/manifest.json');
    const manifest = JSON.parse(readFileSync(manifestPath, 'utf8')) as {
      files: Record<string, unknown>;
    };
    delete manifest.files['app/foo.ts'];
    writeFileSync(
      manifestPath,
      `${JSON.stringify(manifest, null, 2)}\n`,
      'utf8'
    );

    const exit = run(['--check'], {
      cwd: sandbox.root,
      generatedAt: '2026-05-07T00:00:00.000Z',
    });

    expect(exit).toBe(1);
    const out = stdio.outputs.join('');
    expect(out).toContain('newly ship');
    expect(out).toContain('app/foo.ts');
    expect(out).toContain('--ship');
    expect(out).toContain('--withhold');
    expect(out).toContain('does not withhold');
  });

  test('extra entry: exits non-zero and names the extra file', () => {
    seedAndGenerate();

    const manifestPath = path.join(sandbox.root, '.gaia/manifest.json');
    const manifest = JSON.parse(readFileSync(manifestPath, 'utf8')) as {
      files: Record<string, string>;
    };
    manifest.files['app/ghost.ts'] = 'owned';
    writeFileSync(
      manifestPath,
      `${JSON.stringify(manifest, null, 2)}\n`,
      'utf8'
    );

    const exit = run(['--check'], {
      cwd: sandbox.root,
      generatedAt: '2026-05-07T00:00:00.000Z',
    });

    expect(exit).toBe(1);
    const out = stdio.outputs.join('');
    expect(out).toContain('extra in manifest');
    expect(out).toContain('app/ghost.ts');
  });

  test('classification drift: exits non-zero and names the drift', () => {
    seedAndGenerate();

    const manifestPath = path.join(sandbox.root, '.gaia/manifest.json');
    const manifest = JSON.parse(readFileSync(manifestPath, 'utf8')) as {
      files: Record<string, string>;
    };
    manifest.files['app/foo.ts'] = 'shared';
    writeFileSync(
      manifestPath,
      `${JSON.stringify(manifest, null, 2)}\n`,
      'utf8'
    );

    const exit = run(['--check'], {
      cwd: sandbox.root,
      generatedAt: '2026-05-07T00:00:00.000Z',
    });

    expect(exit).toBe(1);
    const out = stdio.outputs.join('');
    expect(out).toContain('class drift');
    expect(out).toContain('app/foo.ts');
    expect(out).toContain('shared → owned');
  });

  test('version drift: exits non-zero and names both versions', () => {
    seedAndGenerate();

    const manifestPath = path.join(sandbox.root, '.gaia/manifest.json');
    const manifest = JSON.parse(readFileSync(manifestPath, 'utf8')) as {
      files: Record<string, string>;
      version: string;
    };
    manifest.version = '0.9.0';
    writeFileSync(
      manifestPath,
      `${JSON.stringify(manifest, null, 2)}\n`,
      'utf8'
    );

    const exit = run(['--check'], {
      cwd: sandbox.root,
      generatedAt: '2026-05-07T00:00:00.000Z',
    });

    expect(exit).toBe(1);
    const out = stdio.outputs.join('');
    expect(out).toContain('version drift');
    expect(out).toContain('0.9.0');
    expect(out).toContain('1.0.0');
  });

  test('malformed manifest (not an object): exits 2 with a parse error', () => {
    seedAndGenerate();

    const manifestPath = path.join(sandbox.root, '.gaia/manifest.json');
    writeFileSync(manifestPath, '["not", "a", "manifest"]\n', 'utf8');

    const exit = run(['--check'], {
      cwd: sandbox.root,
      generatedAt: '2026-05-07T00:00:00.000Z',
    });

    expect(exit).toBe(2);
    expect(stdio.errors.join('')).toContain('manifest_parse_failed');
    expect(stdio.errors.join('')).toContain('malformed');
  });

  test('malformed manifest (bad class value): exits 2 with a parse error', () => {
    seedAndGenerate();

    const manifestPath = path.join(sandbox.root, '.gaia/manifest.json');
    const manifest = JSON.parse(readFileSync(manifestPath, 'utf8')) as {
      files: Record<string, string>;
    };
    manifest.files['app/foo.ts'] = 'bogus-class';
    writeFileSync(
      manifestPath,
      `${JSON.stringify(manifest, null, 2)}\n`,
      'utf8'
    );

    const exit = run(['--check'], {
      cwd: sandbox.root,
      generatedAt: '2026-05-07T00:00:00.000Z',
    });

    expect(exit).toBe(2);
    expect(stdio.errors.join('')).toContain('manifest_parse_failed');
  });

  test('glob-shaped release-exclude line: exits 2 loudly instead of silently mis-excluding', () => {
    seedAndGenerate();

    writeFileSync(
      path.join(sandbox.root, '.gaia/release-exclude'),
      'app/foo*\n',
      'utf8'
    );

    const exit = run(['--check'], {
      cwd: sandbox.root,
      generatedAt: '2026-05-07T00:00:00.000Z',
    });

    expect(exit).toBe(2);
    expect(stdio.errors.join('')).toContain('manifest_build_failed');
    expect(stdio.errors.join('')).toContain('literal');
  });

  test('indented release-exclude line: exits 2 loudly', () => {
    seedAndGenerate();

    writeFileSync(
      path.join(sandbox.root, '.gaia/release-exclude'),
      '  app/foo\n',
      'utf8'
    );

    const exit = run(['--check'], {
      cwd: sandbox.root,
      generatedAt: '2026-05-07T00:00:00.000Z',
    });

    expect(exit).toBe(2);
    expect(stdio.errors.join('')).toContain('manifest_build_failed');
  });

  test('missing manifest file: exits non-zero with manifest_missing error', () => {
    sandbox.commit('seed', {
      '.gaia/release-exclude': '# none\n',
      '.gaia/VERSION': '1.0.0\n',
      'app/foo.ts': 'export {};\n',
    });

    const exit = run(['--check'], {cwd: sandbox.root});
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('manifest_missing');
    // The remedy it names must be one that actually works: the bare command
    // refuses on any tree carrying a classified file.
    expect(stdio.errors.join('')).toContain(
      'gaia-maintainer release manifest --allow-undecided'
    );
  });

  test('--check --json emits structured report', () => {
    seedAndGenerate();

    const manifestPath = path.join(sandbox.root, '.gaia/manifest.json');
    const manifest = JSON.parse(readFileSync(manifestPath, 'utf8')) as {
      files: Record<string, string>;
    };
    manifest.files['app/extra.ts'] = 'owned';
    writeFileSync(
      manifestPath,
      `${JSON.stringify(manifest, null, 2)}\n`,
      'utf8'
    );

    const exit = run(['--check', '--json'], {
      cwd: sandbox.root,
      generatedAt: '2026-05-07T00:00:00.000Z',
    });

    expect(exit).toBe(1);
    const parsed = JSON.parse(stdio.outputs.join('')) as ManifestDriftJson;
    expect(parsed.extra).toEqual([{actual: 'owned', file: 'app/extra.ts'}]);
    expect(parsed.missing).toEqual([]);
    expect(parsed.drift).toEqual([]);
  });

  test('classifier-set overlap: exits non-zero and names the overlap', () => {
    sandbox.commit('seed', {
      // CLAUDE.md is in the SHARED classifier set; if release-exclude
      // also matches it, the SHARED entry is dead code.
      '.gaia/release-exclude': 'CLAUDE.md\n',
      '.gaia/VERSION': '1.0.0\n',
      'app/foo.ts': 'export {};\n',
      'CLAUDE.md': '# CLAUDE\n',
    });

    const exit = run(['--allow-undecided'], {
      cwd: sandbox.root,
      generatedAt: '2026-05-07T00:00:00.000Z',
    });
    expect(exit).toBe(0);
    stdio.outputs.length = 0;

    const checkExit = run(['--check'], {
      cwd: sandbox.root,
      generatedAt: '2026-05-07T00:00:00.000Z',
    });

    expect(checkExit).toBe(1);
    const out = stdio.outputs.join('');
    expect(out).toContain('classifier-set overlaps');
    expect(out).toContain('SHARED');
    expect(out).toContain('CLAUDE.md');
  });

  test('scan-scope gap: exits non-zero and names the uncovered directory', () => {
    sandbox.commit('seed', {
      '.gaia/release-exclude': '# none\n',
      // .gaia/scripts is a real runtime-deps SCAN_GLOBS entry, but this
      // maintainer-paths scope omits it, so it's covered on one side only.
      '.gaia/release-scrub.yml': [
        'transforms:',
        '  - type: leak-check',
        '    checks:',
        '      - id: maintainer-paths',
        '        description: test',
        '        pattern: "test"',
        '        scope:',
        '          - "CLAUDE.md"',
        '',
      ].join('\n'),
      '.gaia/scripts/foo.sh': '#!/bin/sh\n',
      '.gaia/VERSION': '1.0.0\n',
      'CLAUDE.md': '# CLAUDE\n',
    });

    const exit = run(['--allow-undecided'], {
      cwd: sandbox.root,
      generatedAt: '2026-05-07T00:00:00.000Z',
    });
    expect(exit).toBe(0);
    stdio.outputs.length = 0;

    const checkExit = run(['--check'], {
      cwd: sandbox.root,
      generatedAt: '2026-05-07T00:00:00.000Z',
    });

    expect(checkExit).toBe(1);
    const out = stdio.outputs.join('');
    expect(out).toContain('.sh-bearing directories outside a leak-check scope');
    expect(out).toContain('.gaia/scripts');
    expect(out).toContain('maintainer-paths scope');
  });

  test('scan-scope clean: covered .sh directory does not trip the check', () => {
    sandbox.commit('seed', {
      '.gaia/release-exclude': '# none\n',
      '.gaia/release-scrub.yml': [
        'transforms:',
        '  - type: leak-check',
        '    checks:',
        '      - id: maintainer-paths',
        '        description: test',
        '        pattern: "test"',
        '        scope:',
        '          - ".gaia/scripts/**"',
        '',
      ].join('\n'),
      '.gaia/scripts/foo.sh': '#!/bin/sh\n',
      '.gaia/VERSION': '1.0.0\n',
    });

    const exit = run(['--allow-undecided'], {
      cwd: sandbox.root,
      generatedAt: '2026-05-07T00:00:00.000Z',
    });
    expect(exit).toBe(0);
    stdio.outputs.length = 0;

    const checkExit = run(['--check'], {
      cwd: sandbox.root,
      generatedAt: '2026-05-07T00:00:00.000Z',
    });

    expect(checkExit).toBe(0);
    expect(stdio.outputs.join('')).toContain('clean');
  });

  test('region drift only (no file drift): exits non-zero and names the offending path', () => {
    sandbox.commit('seed', {
      '.claude/agents/test-auditor.md': [
        '# Test Auditor',
        '',
        '## Remit and self-skip',
        '',
        '<!-- gaia:audit-remit:start -->',
        '- `app/**`',
        '',
        'Filter the changed-file list against the globs above.',
        '<!-- gaia:audit-remit:end -->',
        '',
      ].join('\n'),
      '.gaia/audit-ci.yml': [
        'auditors:',
        '  - name: test-auditor',
        '    globs:',
        '      - "app/**"',
        '    scope: adopter',
        '    default: true',
        '',
      ].join('\n'),
      '.gaia/release-exclude': '# none\n',
      '.gaia/VERSION': '1.0.0\n',
      'app/foo.ts': 'export {};\n',
    });

    const exit = run(['--allow-undecided'], {
      cwd: sandbox.root,
      generatedAt: '2026-05-07T00:00:00.000Z',
    });
    expect(exit).toBe(0);
    stdio.outputs.length = 0;

    // Hand-edit the committed manifest so its region declaration disagrees
    // with a fresh scan of the repo, with no file-level drift at all.
    const manifestPath = path.join(sandbox.root, '.gaia/manifest.json');
    const manifest = JSON.parse(readFileSync(manifestPath, 'utf8')) as {
      regions: {id: string; paths: string[]}[];
    };
    manifest.regions = manifest.regions.map((region) =>
      region.id === 'audit-remit' ? {...region, paths: []} : region
    );
    writeFileSync(
      manifestPath,
      `${JSON.stringify(manifest, null, 2)}\n`,
      'utf8'
    );

    const checkExit = run(['--check'], {
      cwd: sandbox.root,
      generatedAt: '2026-05-07T00:00:00.000Z',
    });

    expect(checkExit).toBe(1);
    const out = stdio.outputs.join('');
    expect(out).toContain('region declaration drift');
    expect(out).toContain('.claude/agents/test-auditor.md');
  });
});
