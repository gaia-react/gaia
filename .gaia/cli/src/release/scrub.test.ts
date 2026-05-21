/**
 * Tests for `gaia-maintainer release scrub`.
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
import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {globToRegex, parseKeyPath, run} from './scrub.js';

const JSON_STRIP_CONFIG = `
transforms:
  - type: json-strip
    paths:
      - "package.json"
    keys:
      - "bin"
      - "scripts.test:forensics"
`;

type Sandbox = {
  cleanup: () => void;
  configPath: string;
  rootDir: string;
  stagingDir: string;
  writeStaged: (relativePath: string, contents: string) => void;
};

type SandboxOptions = {
  config: string;
};

const setupSandbox = (options: SandboxOptions): Sandbox => {
  const rootDir = mkdtempSync(path.join(tmpdir(), 'gaia-release-scrub-'));
  const stagingDir = path.join(rootDir, 'staging');
  mkdirSync(stagingDir, {recursive: true});
  mkdirSync(path.join(rootDir, '.gaia'), {recursive: true});
  const configPath = path.join(rootDir, '.gaia', 'release-scrub.yml');
  writeFileSync(configPath, options.config, 'utf8');

  return {
    cleanup: () => {
      rmSync(rootDir, {force: true, recursive: true});
    },
    configPath,
    rootDir,
    stagingDir,
    writeStaged: (relativePath, contents) => {
      const absolute = path.join(stagingDir, relativePath);
      mkdirSync(path.dirname(absolute), {recursive: true});
      writeFileSync(absolute, contents, 'utf8');
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

const MARKER_ONLY_CONFIG = `
transforms:
  - type: marker-strip
    paths:
      - "wiki/**/*.md"
      - ".claude/**/*.md"
    start: "<!-- gaia:maintainer-only:start -->"
    end: "<!-- gaia:maintainer-only:end -->"
`;

const LEAK_ONLY_CONFIG = `
transforms:
  - type: leak-check
    checks:
      - id: uat-narrative
        pattern: "UAT-[0-9]{3}"
        scope:
          - ".claude/**"
        line-allowlist:
          - "uat[-_]id"
      - id: maintainer-paths
        pattern: "\\\\.gaia/cli/src/"
        scope:
          - ".claude/**"
          - "wiki/**"
        path-allowlist:
          - "wiki/decisions/Allowed Page.md"
`;

const FULL_CONFIG = `
transforms:
  - type: marker-strip
    paths:
      - "wiki/**/*.md"
    start: "<!-- gaia:maintainer-only:start -->"
    end: "<!-- gaia:maintainer-only:end -->"

  - type: leak-check
    checks:
      - id: uat-narrative
        pattern: "UAT-[0-9]{3}"
        scope:
          - "wiki/**"
`;

describe('globToRegex', () => {
  test('matches single-segment files', () => {
    expect(globToRegex('CLAUDE.md').test('CLAUDE.md')).toBe(true);
    expect(globToRegex('CLAUDE.md').test('foo/CLAUDE.md')).toBe(false);
  });

  test('** matches zero or more segments', () => {
    const re = globToRegex('wiki/**/*.md');
    expect(re.test('wiki/foo.md')).toBe(true);
    expect(re.test('wiki/sub/foo.md')).toBe(true);
    expect(re.test('wiki/a/b/c/foo.md')).toBe(true);
    expect(re.test('other/foo.md')).toBe(false);
  });

  test('trailing /** matches everything below the prefix', () => {
    const re = globToRegex('.claude/**');
    expect(re.test('.claude/skills/foo.md')).toBe(true);
    expect(re.test('.claude/rules/wiki-style.md')).toBe(true);
    expect(re.test('app/components/Foo.tsx')).toBe(false);
  });

  test('* matches a single segment only', () => {
    const re = globToRegex('wiki/*.md');
    expect(re.test('wiki/foo.md')).toBe(true);
    expect(re.test('wiki/sub/foo.md')).toBe(false);
  });
});

describe('release scrub CLI', () => {
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

  test('strips a multi-line maintainer-only block', () => {
    sandbox = setupSandbox({config: MARKER_ONLY_CONFIG});
    sandbox.writeStaged(
      'wiki/index.md',
      [
        '# Index',
        '',
        '## Public',
        '',
        '- thing',
        '',
        '<!-- gaia:maintainer-only:start -->',
        '## Maintainer-only',
        '',
        '- secret',
        '<!-- gaia:maintainer-only:end -->',
        '',
        '## More public',
        '',
      ].join('\n')
    );

    const exit = run([sandbox.stagingDir], {cwd: sandbox.rootDir});
    expect(exit).toBe(0);

    const after = readFileSync(
      path.join(sandbox.stagingDir, 'wiki/index.md'),
      'utf8'
    );
    expect(after).not.toContain('Maintainer-only');
    expect(after).not.toContain('secret');
    expect(after).not.toContain('gaia:maintainer-only');
    expect(after).toContain('## Public');
    expect(after).toContain('## More public');
  });

  test('leaves files without markers untouched', () => {
    sandbox = setupSandbox({config: MARKER_ONLY_CONFIG});
    const original = '# Foo\n\nbody\n';
    sandbox.writeStaged('wiki/foo.md', original);

    const exit = run([sandbox.stagingDir], {cwd: sandbox.rootDir});
    expect(exit).toBe(0);

    const after = readFileSync(
      path.join(sandbox.stagingDir, 'wiki/foo.md'),
      'utf8'
    );
    expect(after).toBe(original);
  });

  test('refuses on unbalanced start without end', () => {
    sandbox = setupSandbox({config: MARKER_ONLY_CONFIG});
    sandbox.writeStaged(
      'wiki/broken.md',
      ['# Broken', '<!-- gaia:maintainer-only:start -->', 'never closed', ''].join('\n')
    );

    const exit = run([sandbox.stagingDir], {cwd: sandbox.rootDir});
    expect(exit).toBe(1);
    expect(stdio.outputs.join('')).toContain('start_without_end');
  });

  test('refuses on unbalanced end without start', () => {
    sandbox = setupSandbox({config: MARKER_ONLY_CONFIG});
    sandbox.writeStaged(
      'wiki/broken.md',
      ['# Broken', '', '<!-- gaia:maintainer-only:end -->', ''].join('\n')
    );

    const exit = run([sandbox.stagingDir], {cwd: sandbox.rootDir});
    expect(exit).toBe(1);
    expect(stdio.outputs.join('')).toContain('end_without_start');
  });

  test('flags UAT-NNN narrative in shipped instruction surfaces', () => {
    sandbox = setupSandbox({config: LEAK_ONLY_CONFIG});
    sandbox.writeStaged(
      '.claude/skills/foo/SKILL.md',
      '# Foo\n\nImplements UAT-007 (working-doc reference).\n'
    );

    const exit = run([sandbox.stagingDir], {cwd: sandbox.rootDir});
    expect(exit).toBe(1);

    const out = stdio.outputs.join('');
    expect(out).toContain('uat-narrative');
    expect(out).toContain('UAT-007');
  });

  test('exempts lines with structural identifier fragments', () => {
    sandbox = setupSandbox({config: LEAK_ONLY_CONFIG});
    sandbox.writeStaged(
      '.claude/skills/foo/SKILL.md',
      '# Foo\n\nUse `--uat-id UAT-099` to filter; the `uat_id` field is required.\n'
    );

    const exit = run([sandbox.stagingDir], {cwd: sandbox.rootDir});
    expect(exit).toBe(0);
  });

  test('exempts allowlisted paths from leak-check', () => {
    sandbox = setupSandbox({config: LEAK_ONLY_CONFIG});
    sandbox.writeStaged(
      'wiki/decisions/Allowed Page.md',
      '# Allowed\n\nReferences `.gaia/cli/src/foo.ts` legitimately.\n'
    );
    sandbox.writeStaged(
      'wiki/decisions/Other.md',
      '# Other\n\nReferences `.gaia/cli/src/bar.ts` illegitimately.\n'
    );

    const exit = run([sandbox.stagingDir], {cwd: sandbox.rootDir});
    expect(exit).toBe(1);

    const out = stdio.outputs.join('');
    expect(out).toContain('wiki/decisions/Other.md');
    expect(out).not.toContain('wiki/decisions/Allowed Page.md');
  });

  test('--json emits structured report', () => {
    sandbox = setupSandbox({config: FULL_CONFIG});
    sandbox.writeStaged(
      'wiki/index.md',
      [
        '# Index',
        '',
        '<!-- gaia:maintainer-only:start -->',
        'Refers to UAT-007 inside the maintainer block.',
        '<!-- gaia:maintainer-only:end -->',
        '',
      ].join('\n')
    );

    const exit = run([sandbox.stagingDir, '--json'], {cwd: sandbox.rootDir});
    expect(exit).toBe(0);

    const parsed = JSON.parse(stdio.outputs.join('')) as {
      leaks: ReadonlyArray<{check: string; file: string; line: number}>;
      marker_strip: {
        blocks_stripped: number;
        files_touched: readonly string[];
      };
    };

    expect(parsed.marker_strip.blocks_stripped).toBe(1);
    expect(parsed.marker_strip.files_touched).toContain('wiki/index.md');
    expect(parsed.leaks).toHaveLength(0);
  });

  test('marker-strip happens before leak-check (block content not flagged)', () => {
    sandbox = setupSandbox({config: FULL_CONFIG});
    sandbox.writeStaged(
      'wiki/index.md',
      [
        '# Index',
        '',
        'Public content.',
        '<!-- gaia:maintainer-only:start -->',
        'UAT-001 maintainer reference.',
        '<!-- gaia:maintainer-only:end -->',
        '',
      ].join('\n')
    );

    const exit = run([sandbox.stagingDir], {cwd: sandbox.rootDir});
    expect(exit).toBe(0);
  });

  test('exits 1 when staging dir does not exist', () => {
    sandbox = setupSandbox({config: MARKER_ONLY_CONFIG});

    const exit = run([path.join(sandbox.rootDir, 'no-such')], {
      cwd: sandbox.rootDir,
    });
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('staging_dir_missing');
  });

  test('exits 1 when staging dir argument is missing', () => {
    sandbox = setupSandbox({config: MARKER_ONLY_CONFIG});

    const exit = run([], {cwd: sandbox.rootDir});
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('missing_staging_dir');
  });

  test('exits 2 on malformed config', () => {
    sandbox = setupSandbox({config: 'transforms:\n  - type: marker-strip\n'});
    sandbox.writeStaged('wiki/index.md', '# x\n');

    const exit = run([sandbox.stagingDir], {cwd: sandbox.rootDir});
    expect(exit).toBe(2);
    expect(stdio.errors.join('')).toContain('config_load_failed');
  });

  test('rejects unknown flags', () => {
    sandbox = setupSandbox({config: MARKER_ONLY_CONFIG});

    const exit = run([sandbox.stagingDir, '--bogus'], {cwd: sandbox.rootDir});
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('unknown flag');
  });
});

describe('json-strip transform', () => {
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

  test('removes a top-level key', () => {
    sandbox = setupSandbox({config: JSON_STRIP_CONFIG});
    sandbox.writeStaged(
      'package.json',
      JSON.stringify({bin: {gaia: './.gaia/cli/gaia'}, name: 'my-app', scripts: {}}, null, 2)
    );

    const exit = run([sandbox.stagingDir], {cwd: sandbox.rootDir});
    expect(exit).toBe(0);

    const after = JSON.parse(readFileSync(path.join(sandbox.stagingDir, 'package.json'), 'utf8'));
    expect(after).not.toHaveProperty('bin');
    expect(after.name).toBe('my-app');
  });

  test('removes a nested key via dot-notation', () => {
    sandbox = setupSandbox({config: JSON_STRIP_CONFIG});
    sandbox.writeStaged(
      'package.json',
      JSON.stringify({
        scripts: {
          build: 'react-router build',
          'test:forensics': 'bats .gaia/tests/forensics/unit.bats',
        },
      }, null, 2)
    );

    const exit = run([sandbox.stagingDir], {cwd: sandbox.rootDir});
    expect(exit).toBe(0);

    const after = JSON.parse(readFileSync(path.join(sandbox.stagingDir, 'package.json'), 'utf8'));
    expect(after.scripts).not.toHaveProperty('test:forensics');
    expect(after.scripts.build).toBe('react-router build');
  });

  test('removes multiple keys in one pass', () => {
    sandbox = setupSandbox({config: JSON_STRIP_CONFIG});
    sandbox.writeStaged(
      'package.json',
      JSON.stringify({
        bin: {gaia: './.gaia/cli/gaia'},
        name: 'my-app',
        scripts: {
          build: 'react-router build',
          'test:forensics': 'bats .gaia/tests/forensics/unit.bats',
        },
      }, null, 2)
    );

    const exit = run([sandbox.stagingDir], {cwd: sandbox.rootDir});
    expect(exit).toBe(0);

    const after = JSON.parse(readFileSync(path.join(sandbox.stagingDir, 'package.json'), 'utf8'));
    expect(after).not.toHaveProperty('bin');
    expect(after.scripts).not.toHaveProperty('test:forensics');
    expect(after.name).toBe('my-app');
    expect(after.scripts.build).toBe('react-router build');
  });

  test('no-ops when key does not exist', () => {
    sandbox = setupSandbox({config: JSON_STRIP_CONFIG});
    const original = JSON.stringify({name: 'my-app', scripts: {build: 'react-router build'}}, null, 2);
    sandbox.writeStaged('package.json', original);

    const exit = run([sandbox.stagingDir], {cwd: sandbox.rootDir});
    expect(exit).toBe(0);

    const after = readFileSync(path.join(sandbox.stagingDir, 'package.json'), 'utf8');
    expect(JSON.parse(after)).toEqual(JSON.parse(original));
  });

  test('only processes files matching the paths glob', () => {
    sandbox = setupSandbox({config: JSON_STRIP_CONFIG});
    const untouched = JSON.stringify({bin: {gaia: './.gaia/cli/gaia'}}, null, 2);
    sandbox.writeStaged('other.json', untouched);

    const exit = run([sandbox.stagingDir], {cwd: sandbox.rootDir});
    expect(exit).toBe(0);

    const after = readFileSync(path.join(sandbox.stagingDir, 'other.json'), 'utf8');
    expect(after).toBe(untouched);
  });

  test('exits 2 on invalid JSON', () => {
    sandbox = setupSandbox({config: JSON_STRIP_CONFIG});
    sandbox.writeStaged('package.json', 'not { valid json');

    const exit = run([sandbox.stagingDir], {cwd: sandbox.rootDir});
    expect(exit).toBe(2);
    expect(stdio.errors.join('')).toContain('transform_failed');
  });

  test('--json report includes json_strip section', () => {
    sandbox = setupSandbox({config: JSON_STRIP_CONFIG});
    sandbox.writeStaged(
      'package.json',
      JSON.stringify({bin: {gaia: './.gaia/cli/gaia'}, scripts: {}}, null, 2)
    );

    const exit = run([sandbox.stagingDir, '--json'], {cwd: sandbox.rootDir});
    expect(exit).toBe(0);

    const report = JSON.parse(stdio.outputs.join('')) as {
      json_strip: {files_touched: string[]; keys_removed: number};
    };
    expect(report.json_strip.keys_removed).toBe(1);
    expect(report.json_strip.files_touched).toContain('package.json');
  });

  test('no-op when no matching files produces zero counts', () => {
    sandbox = setupSandbox({config: JSON_STRIP_CONFIG});

    const exit = run([sandbox.stagingDir, '--json'], {cwd: sandbox.rootDir});
    expect(exit).toBe(0);

    const report = JSON.parse(stdio.outputs.join('')) as {
      json_strip: {files_touched: string[]; keys_removed: number};
    };
    expect(report.json_strip.keys_removed).toBe(0);
    expect(report.json_strip.files_touched).toHaveLength(0);
  });

  test('removes a key whose name contains a literal dot via \\. escape', () => {
    // YAML double-quote turns `\\.` into `\.`, which parseKeyPath reads as
    // a literal dot inside the key name. Key path: ['exports', './secret'].
    const dottedKeyConfig = `
transforms:
  - type: json-strip
    paths:
      - "package.json"
    keys:
      - "exports.\\\\./secret"
`;
    sandbox = setupSandbox({config: dottedKeyConfig});
    sandbox.writeStaged(
      'package.json',
      JSON.stringify(
        {exports: {'./public': './a.js', './secret': './b.js'}, name: 'app'},
        null,
        2
      )
    );

    const exit = run([sandbox.stagingDir], {cwd: sandbox.rootDir});
    expect(exit).toBe(0);

    const after = JSON.parse(
      readFileSync(path.join(sandbox.stagingDir, 'package.json'), 'utf8')
    );
    expect(after.exports).not.toHaveProperty('./secret');
    expect(after.exports).toHaveProperty('./public');
  });
});

describe('parseKeyPath', () => {
  test('splits on unescaped dots', () => {
    expect(parseKeyPath('scripts.test:forensics')).toEqual([
      'scripts',
      'test:forensics',
    ]);
  });

  test('treats an escaped dot as a literal in the key name', () => {
    expect(parseKeyPath(String.raw`scripts.foo\.bar`)).toEqual([
      'scripts',
      'foo.bar',
    ]);
  });

  test('handles a leading escaped-dot segment', () => {
    expect(parseKeyPath(String.raw`exports.\./feature`)).toEqual([
      'exports',
      './feature',
    ]);
  });

  test('returns a single segment for a plain key', () => {
    expect(parseKeyPath('bin')).toEqual(['bin']);
  });
});
