import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
/**
 * Tests for `gaia-maintainer release runtime-deps`.
 */
import {mkdirSync, mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {extractPathRefs, run} from './runtime-deps.js';

type Sandbox = {
  cleanup: () => void;
  rootDir: string;
  writeFile: (relativePath: string, contents: string) => void;
  writeManifest: (
    files: Record<string, 'owned' | 'shared' | 'wiki-owned'>
  ) => void;
};

const setupSandbox = (): Sandbox => {
  const rootDir = mkdtempSync(path.join(tmpdir(), 'gaia-runtime-deps-'));

  return {
    cleanup: () => {
      rmSync(rootDir, {force: true, recursive: true});
    },
    rootDir,
    writeFile: (relativePath, contents) => {
      const absolute = path.join(rootDir, relativePath);
      mkdirSync(path.dirname(absolute), {recursive: true});
      writeFileSync(absolute, contents, 'utf8');
    },
    writeManifest: (files) => {
      const absolute = path.join(rootDir, '.gaia', 'manifest.json');
      mkdirSync(path.dirname(absolute), {recursive: true});
      writeFileSync(
        absolute,
        `${JSON.stringify(
          {
            files,
            generated: '2026-05-08T00:00:00Z',
            version: '1.0.0',
          },
          null,
          2
        )}\n`,
        'utf8'
      );
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

describe('extractPathRefs', () => {
  test('extracts repo-relative paths from variable assignments', () => {
    const refs = extractPathRefs(
      '.gaia/statusline/foo.sh',
      'CHECK_SCRIPT="$PROJECT_ROOT/.gaia/scripts/check-updates.sh"\n'
    );
    expect(refs.map((r) => r.path)).toContain('.gaia/scripts/check-updates.sh');
  });

  test('skips line-leading comments', () => {
    const refs = extractPathRefs(
      '.gaia/statusline/foo.sh',
      '# A reference to .gaia/scripts/check-updates.sh in a comment.\nbash .gaia/cli/gaia\n'
    );
    expect(refs.map((r) => r.path)).toEqual(['.gaia/cli/gaia']);
  });

  test('handles bare path tokens in conditionals', () => {
    const refs = extractPathRefs(
      '.claude/hooks/foo.sh',
      'if [ -x .gaia/cli/gaia ]; then\n  .gaia/cli/gaia run\nfi\n'
    );
    expect(refs.map((r) => r.path)).toEqual([
      '.gaia/cli/gaia',
      '.gaia/cli/gaia',
    ]);
  });

  test('does not match substrings inside larger paths', () => {
    const refs = extractPathRefs(
      '.claude/hooks/foo.sh',
      'echo "not-a-leak/.gaia/cli/foo"\n'
    );
    expect(refs).toEqual([]);
  });

  test('trims trailing punctuation', () => {
    const refs = extractPathRefs(
      '.claude/hooks/foo.sh',
      'echo .gaia/cli/gaia.\n'
    );
    expect(refs.map((r) => r.path)).toEqual(['.gaia/cli/gaia']);
  });

  test('extracts multiple occurrences on the same line', () => {
    const refs = extractPathRefs(
      '.gaia/statusline/foo.sh',
      'cp .gaia/cli/gaia .claude/hooks/x.sh\n'
    );
    expect(refs.map((r) => r.path)).toEqual([
      '.gaia/cli/gaia',
      '.claude/hooks/x.sh',
    ]);
  });

  test('skips prose-allowlisted directory tokens in user-facing strings', () => {
    // pr-merge-audit-check.sh names `.github/workflows/` as an example
    // in-scope path inside a multi-line `reason="..."` error string. It is
    // descriptive prose shown to the operator, not a runtime invocation, so
    // the scan must not treat it as a runtime-dependency leak.
    const refs = extractPathRefs(
      '.claude/hooks/pr-merge-audit-check.sh',
      '                     .github/workflows/), not a wiki/docs/.gaia-only diff\n'
    );
    expect(refs.map((r) => r.path)).not.toContain('.github/workflows');
  });

  test('still flags a genuine file leak under an allowlisted directory', () => {
    // The allowlist is exact-token. A real invocation of a file under
    // .github/workflows/ is a distinct, longer token and must still flag,
    // guarding against the allowlist over-suppressing genuine leaks.
    const refs = extractPathRefs(
      '.gaia/statusline/foo.sh',
      'bash .github/workflows/deploy.yml\n'
    );
    expect(refs.map((r) => r.path)).toContain('.github/workflows/deploy.yml');
  });

  test('skips the allowlisted audit-workflow path constant', () => {
    // pr-merge-audit-check.sh's check_self_mod_only_update_pr() assigns the
    // audit workflow path to compare against the PR diff and template blob; it
    // never sources or executes the file. The path is release-excluded, so the
    // exact full-path token is allowlisted as a non-dependency.
    const refs = extractPathRefs(
      '.claude/hooks/pr-merge-audit-check.sh',
      'audit_wf=".github/workflows/code-review-audit.yml"\n'
    );
    expect(refs.map((r) => r.path)).not.toContain(
      '.github/workflows/code-review-audit.yml'
    );
  });

  test('skips the allowlisted shell-snapshots regex-literal token', () => {
    // spec-session-lock.sh assigns Claude Code's snapshot-wrapper directory to
    // a regex literal that a `ps` command line is matched against; it is never
    // sourced or executed, so the exact token is allowlisted.
    const refs = extractPathRefs(
      '.specify/extensions/gaia/lib/spec-session-lock.sh',
      "SNAPSHOT_WRAPPER_PATTERN='\\.claude/shell-snapshots/'\n"
    );
    expect(refs.map((r) => r.path)).not.toContain('.claude/shell-snapshots');
  });

  test('still flags a genuine file leak under the shell-snapshots directory', () => {
    // Exact-token allowlisting again: a real invocation of a file beneath the
    // allowlisted directory is a longer token and must still flag.
    const refs = extractPathRefs(
      '.gaia/statusline/foo.sh',
      'bash .claude/shell-snapshots/snapshot-zsh.sh\n'
    );
    expect(refs.map((r) => r.path)).toContain(
      '.claude/shell-snapshots/snapshot-zsh.sh'
    );
  });
});

describe('release runtime-deps CLI', () => {
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

  test('passes when shipped scripts only reference manifested paths', () => {
    sandbox.writeManifest({
      '.gaia/cli/gaia': 'owned',
      '.gaia/scripts/check-updates.sh': 'owned',
      '.gaia/statusline/gaia-statusline.sh': 'owned',
    });
    sandbox.writeFile(
      '.gaia/statusline/gaia-statusline.sh',
      [
        '#!/usr/bin/env bash',
        'CHECK_SCRIPT="$PROJECT_ROOT/.gaia/scripts/check-updates.sh"',
        'if [ -x .gaia/cli/gaia ]; then bash "$CHECK_SCRIPT"; fi',
        '',
      ].join('\n')
    );

    const exit = run([], {cwd: sandbox.rootDir});
    expect(exit).toBe(0);
    expect(stdio.outputs.join('')).toContain('runtime-dependency leaks: none');
  });

  test('flags references to release-excluded paths', () => {
    // Manifest excludes .gaia/scripts/; that directory is release-excluded.
    // The scanned script itself must ship, or bare mode correctly skips it.
    sandbox.writeManifest({
      '.gaia/cli/gaia': 'owned',
      '.gaia/statusline/gaia-statusline.sh': 'owned',
    });
    sandbox.writeFile(
      '.gaia/statusline/gaia-statusline.sh',
      [
        '#!/usr/bin/env bash',
        'CHECK_SCRIPT="$PROJECT_ROOT/.gaia/scripts/check-updates.sh"',
        'bash "$CHECK_SCRIPT"',
        '',
      ].join('\n')
    );

    const exit = run([], {cwd: sandbox.rootDir});
    expect(exit).toBe(1);

    const out = stdio.outputs.join('');
    expect(out).toContain('.gaia/scripts/check-updates.sh');
    expect(out).toContain('.gaia/statusline/gaia-statusline.sh:2');
  });

  test('allowlists adopter-owned sentinels', () => {
    sandbox.writeManifest({
      '.claude/hooks/wiki-session-start.sh': 'owned',
      '.gaia/cli/gaia': 'owned',
    });
    sandbox.writeFile(
      '.claude/hooks/wiki-session-start.sh',
      [
        '#!/usr/bin/env bash',
        'cat .gaia/manifest.json',
        'cat .gaia/VERSION',
        'cat wiki/hot.md',
        'cat wiki/log.md',
        '',
      ].join('\n')
    );

    const exit = run([], {cwd: sandbox.rootDir});
    expect(exit).toBe(0);
  });

  test('allowlists runtime-allocated prefixes (.gaia/local)', () => {
    sandbox.writeManifest({
      '.claude/hooks/wiki-session-start.sh': 'owned',
      '.gaia/cli/gaia': 'owned',
    });
    sandbox.writeFile(
      '.claude/hooks/wiki-session-start.sh',
      [
        '#!/usr/bin/env bash',
        'rm -f .gaia/local/cache/shared/update-check.json',
        'STATE_FILE="$PROJECT_ROOT/.gaia/local/setup-state.json"',
        '',
      ].join('\n')
    );

    const exit = run([], {cwd: sandbox.rootDir});
    expect(exit).toBe(0);
  });

  test('allowlists per-session marker files', () => {
    sandbox.writeManifest({
      '.claude/hooks/check-i18n-strings.sh': 'owned',
    });
    sandbox.writeFile(
      '.claude/hooks/check-i18n-strings.sh',
      [
        '#!/usr/bin/env bash',
        'marker=".claude/i18n-strings-checked"',
        'touch ".claude/wiki-drift-checked"',
        'echo > ".claude/wiki-safety-checked"',
        '',
      ].join('\n')
    );

    const exit = run([], {cwd: sandbox.rootDir});
    expect(exit).toBe(0);
  });

  test('resolves a bare directory token as shipped when manifest entries exist beneath it', () => {
    // Mirrors a shell array glob like `SCAN_GLOB=(.claude/hooks/*.sh)`: the
    // extractor's path-body character class stops at `*`, yielding the bare
    // directory token `.claude/hooks`. That token isn't itself a manifest
    // entry, but files ship beneath it on a real adopter clone, so it must
    // resolve as shipped rather than flag as a leak.
    sandbox.writeManifest({
      '.claude/hooks/wiki-session-start.sh': 'owned',
      '.gaia/scripts/lint-hook-array-guard.sh': 'owned',
    });
    sandbox.writeFile(
      '.gaia/scripts/lint-hook-array-guard.sh',
      ['#!/usr/bin/env bash', 'SCAN_GLOB=(.claude/hooks/*.sh)', ''].join('\n')
    );

    const exit = run([], {cwd: sandbox.rootDir});
    expect(exit).toBe(0);
    expect(stdio.outputs.join('')).toContain('runtime-dependency leaks: none');
  });

  test('still flags a bare directory token as a leak when no manifest entries exist beneath it', () => {
    // `.gaia/scripts/tests` is release-excluded end-to-end: zero manifest
    // entries live beneath it, so a bare-directory reference must still
    // flag, guarding against the new directory rule over-rescuing a
    // genuinely leaked directory.
    sandbox.writeManifest({
      '.gaia/cli/gaia': 'owned',
      '.gaia/scripts/run-tests.sh': 'owned',
    });
    sandbox.writeFile(
      '.gaia/scripts/run-tests.sh',
      ['#!/usr/bin/env bash', 'SCAN_GLOB=(.gaia/scripts/tests/*.sh)', ''].join(
        '\n'
      )
    );

    const exit = run([], {cwd: sandbox.rootDir});
    expect(exit).toBe(1);
    expect(stdio.outputs.join('')).toContain('.gaia/scripts/tests');
  });

  test('does not rescue an unmanifested file merely because its directory ships other files', () => {
    // The new directory rule must stay scoped to bare directory tokens. A
    // specific file path that happens to sit under a shipped directory but
    // isn't itself a manifest entry is still a genuine leak, unchanged from
    // before the directory rule existed.
    sandbox.writeManifest({
      '.claude/hooks/wiki-session-start.sh': 'owned',
      '.gaia/statusline/foo.sh': 'owned',
    });
    sandbox.writeFile(
      '.gaia/statusline/foo.sh',
      'bash .claude/hooks/not-a-real-hook.sh\n'
    );

    const exit = run([], {cwd: sandbox.rootDir});
    expect(exit).toBe(1);
    expect(stdio.outputs.join('')).toContain(
      '.claude/hooks/not-a-real-hook.sh'
    );
  });

  test('terminates on a manifest key that is an absolute path', () => {
    // Guards the fixed-point break in `computeShippedDirs`'s ancestor walk.
    // Manifest keys are repo-relative by construction and drain to `.`, but
    // `loadManifest` reads `Object.keys` off unvalidated JSON, so a corrupt
    // manifest can carry an absolute key. `path.dirname('/')` is `'/'`, so
    // such a key never reaches `.` and the walk must be bounded explicitly.
    // Removing that break turns this into a synchronous infinite loop, which
    // hangs the release gate instead of failing it.
    sandbox.writeManifest({
      '.gaia/cli/gaia': 'owned',
      '.gaia/statusline/foo.sh': 'owned',
      '/absolute/path/oops.sh': 'owned',
    });
    sandbox.writeFile('.gaia/statusline/foo.sh', 'echo hi\n');

    const exit = run([], {cwd: sandbox.rootDir});
    expect(exit).toBe(0);
  });

  test('scans nested scripts under .github/actions', () => {
    // The CI composite-action scripts live two directories deep
    // (.github/actions/<action>/lib/*.sh); the walk must recurse to reach
    // them. They ship (manifest "owned") and reference no maintainer paths,
    // so a clean scan is the expected steady state.
    sandbox.writeManifest({
      '.github/actions/gaia-ci-merge-and-watch/lib/wait-for-ci.sh': 'owned',
    });
    sandbox.writeFile(
      '.github/actions/gaia-ci-merge-and-watch/lib/wait-for-ci.sh',
      ['#!/usr/bin/env bash', 'gh pr checks "$PR_NUMBER"', ''].join('\n')
    );

    const exit = run(['--json'], {cwd: sandbox.rootDir});
    expect(exit).toBe(0);

    const parsed = JSON.parse(stdio.outputs.join('')) as {
      leaks: readonly unknown[];
      scanned_files: readonly string[];
    };
    expect(parsed.scanned_files).toContain(
      '.github/actions/gaia-ci-merge-and-watch/lib/wait-for-ci.sh'
    );
    expect(parsed.leaks).toHaveLength(0);
  });

  test('flags a release-excluded reference in a nested .github/actions script', () => {
    // Recursion-and-leak guard: a maintainer-only path referenced inside a
    // deeply nested composite-action script must still flag, proving the new
    // scan scope walks the tree rather than only its top level.
    sandbox.writeManifest({
      '.github/actions/gaia-ci-merge-and-watch/lib/render-issue.sh': 'owned',
    });
    sandbox.writeFile(
      '.github/actions/gaia-ci-merge-and-watch/lib/render-issue.sh',
      ['#!/usr/bin/env bash', 'bash .gaia/cli/src/release/scrub.ts', ''].join(
        '\n'
      )
    );

    const exit = run([], {cwd: sandbox.rootDir});
    expect(exit).toBe(1);
    expect(stdio.outputs.join('')).toContain('.gaia/cli/src/release/scrub.ts');
  });

  test('--json emits structured report', () => {
    sandbox.writeManifest({
      '.gaia/cli/gaia': 'owned',
      '.gaia/statusline/foo.sh': 'owned',
    });
    sandbox.writeFile(
      '.gaia/statusline/foo.sh',
      'bash .gaia/scripts/missing.sh\n'
    );

    const exit = run(['--json'], {cwd: sandbox.rootDir});
    expect(exit).toBe(1);

    const parsed = JSON.parse(stdio.outputs.join('')) as {
      leaks: readonly {file: string; line: number; path: string}[];
      scanned_files: readonly string[];
    };
    expect(parsed.leaks).toHaveLength(1);
    expect(parsed.leaks[0]?.path).toBe('.gaia/scripts/missing.sh');
    expect(parsed.scanned_files).toContain('.gaia/statusline/foo.sh');
  });

  test('exits 0 when there are no shipped script directories', () => {
    sandbox.writeManifest({});

    const exit = run([], {cwd: sandbox.rootDir});
    expect(exit).toBe(0);
  });

  test('exits 2 when manifest is missing', () => {
    sandbox.writeFile('.gaia/statusline/foo.sh', 'bash .gaia/cli/gaia\n');

    const exit = run([], {cwd: sandbox.rootDir});
    expect(exit).toBe(2);
    expect(stdio.errors.join('')).toContain('manifest_load_failed');
  });

  test('--staging scans inside the staging dir', () => {
    const stagingDir = path.join(sandbox.rootDir, 'staging');
    mkdirSync(stagingDir, {recursive: true});
    mkdirSync(path.join(stagingDir, '.gaia'), {recursive: true});
    writeFileSync(
      path.join(stagingDir, '.gaia/manifest.json'),
      `${JSON.stringify(
        {
          files: {'.gaia/cli/gaia': 'owned'},
          generated: '2026-05-08T00:00:00Z',
          version: '1.0.0',
        },
        null,
        2
      )}\n`,
      'utf8'
    );
    mkdirSync(path.join(stagingDir, '.gaia/statusline'), {recursive: true});
    writeFileSync(
      path.join(stagingDir, '.gaia/statusline/foo.sh'),
      'bash .gaia/cli/gaia\n',
      'utf8'
    );

    const exit = run(['--staging', stagingDir], {cwd: sandbox.rootDir});
    expect(exit).toBe(0);
  });

  test('rejects unknown flags', () => {
    sandbox.writeManifest({});
    const exit = run(['--bogus'], {cwd: sandbox.rootDir});
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('unknown flag');
  });

  test('agrees with staging mode: a reference inside a maintainer-only block is not a leak', () => {
    // Regression for #661: bare mode (no --staging) used to be marker-unaware,
    // so a .gaia/cli/src reference wrapped in a
    // `# gaia:maintainer-only:start` / `:end` block (which the scrub's
    // `**/*.sh` marker-strip transform removes before --staging ever scans
    // it) false-positived as a leak. Bare mode must now strip the same
    // blocks in-memory so it agrees with the authoritative staging run.
    sandbox.writeManifest({
      '.gaia/cli/gaia': 'owned',
      '.gaia/scripts/resolve-audit-members.sh': 'owned',
    });
    sandbox.writeFile(
      '.gaia/scripts/resolve-audit-members.sh',
      [
        '#!/usr/bin/env bash',
        '# gaia:maintainer-only:start',
        'echo .gaia/cli/src',
        '# gaia:maintainer-only:end',
        '',
      ].join('\n')
    );

    const exit = run([], {cwd: sandbox.rootDir});
    expect(exit).toBe(0);
    expect(stdio.outputs.join('')).toContain('runtime-dependency leaks: none');
  });

  test('still flags the same kind of reference outside a maintainer-only block', () => {
    // Control for the regression above: the marker strip must not disable
    // leak detection wholesale, only the wrapped block.
    sandbox.writeManifest({
      '.gaia/cli/gaia': 'owned',
      '.gaia/scripts/resolve-audit-members.sh': 'owned',
    });
    sandbox.writeFile(
      '.gaia/scripts/resolve-audit-members.sh',
      ['#!/usr/bin/env bash', 'echo .gaia/cli/src', ''].join('\n')
    );

    const exit = run([], {cwd: sandbox.rootDir});
    expect(exit).toBe(1);
    expect(stdio.outputs.join('')).toContain('.gaia/cli/src');
  });

  test('skips self-references', () => {
    sandbox.writeManifest({
      '.gaia/statusline/preferred-base.sh': 'owned',
    });
    sandbox.writeFile(
      '.gaia/statusline/preferred-base.sh',
      [
        '#!/usr/bin/env bash',
        '# This file is .gaia/statusline/preferred-base.sh',
        'echo .gaia/statusline/preferred-base.sh',
        '',
      ].join('\n')
    );

    const exit = run([], {cwd: sandbox.rootDir});
    expect(exit).toBe(0);
  });

  test('bare mode does not scan a release-excluded script', () => {
    // Bare mode walks the repo root, which holds scripts the staging tree
    // never has. A release-excluded script (no manifest entry) that names a
    // maintainer-only workflow in a TRAILING comment surfaced as a leak:
    // `stripCommentSuffix` strips only line-leading `#` by design, so the
    // reference survived. Scanning a file that never ships can only ever
    // produce a phantom, so the scan surface is the manifest.
    sandbox.writeManifest({
      '.gaia/cli/gaia': 'owned',
    });
    sandbox.writeFile(
      '.gaia/scripts/verify-required-checks.sh',
      [
        '#!/usr/bin/env bash',
        'REQUIRED_CONTEXTS=(',
        '  "Audit CI Tests"   # .github/workflows/audit-ci-tests.yml',
        ')',
        '',
      ].join('\n')
    );

    const exit = run([], {cwd: sandbox.rootDir});
    expect(exit).toBe(0);
    expect(stdio.outputs.join('')).toContain('runtime-dependency leaks: none');
  });

  test('bare mode reports only manifest-backed scripts as scanned', () => {
    // The scan surface itself is the contract: bare mode must agree with the
    // authoritative post-scrub staging run, which only ever sees shipped
    // files. A release-excluded sibling must not inflate the scanned count.
    sandbox.writeManifest({
      '.claude/hooks/ships.sh': 'owned',
    });
    sandbox.writeFile('.claude/hooks/ships.sh', 'echo hi\n');
    sandbox.writeFile('.gaia/scripts/excluded.sh', 'echo hi\n');

    const exit = run(['--json'], {cwd: sandbox.rootDir});
    expect(exit).toBe(0);

    const parsed = JSON.parse(stdio.outputs.join('')) as {
      scanned_files: readonly string[];
    };
    expect(parsed.scanned_files).toEqual(['.claude/hooks/ships.sh']);
  });

  test('bare mode still flags a leak in a manifest-backed script', () => {
    // Control for the two tests above: narrowing the scan surface must not
    // disable leak detection for the files that DO ship.
    sandbox.writeManifest({
      '.gaia/statusline/foo.sh': 'owned',
    });
    sandbox.writeFile(
      '.gaia/statusline/foo.sh',
      'bash .gaia/scripts/missing.sh\n'
    );

    const exit = run([], {cwd: sandbox.rootDir});
    expect(exit).toBe(1);
    expect(stdio.outputs.join('')).toContain('.gaia/scripts/missing.sh');
  });

  test('--staging scans every script present in the tarball', () => {
    // Staging is the ground truth for what ships: it scans the extracted
    // tarball unfiltered, so a shipped-but-unmanifested script still gets
    // scanned there and a packaging bug stays visible to the release gate.
    const stagingDir = path.join(sandbox.rootDir, 'staging');
    mkdirSync(path.join(stagingDir, '.gaia'), {recursive: true});
    writeFileSync(
      path.join(stagingDir, '.gaia/manifest.json'),
      `${JSON.stringify(
        {
          files: {'.gaia/cli/gaia': 'owned'},
          generated: '2026-05-08T00:00:00Z',
          version: '1.0.0',
        },
        null,
        2
      )}\n`,
      'utf8'
    );
    mkdirSync(path.join(stagingDir, '.gaia/statusline'), {recursive: true});
    writeFileSync(
      path.join(stagingDir, '.gaia/statusline/unmanifested.sh'),
      'bash .gaia/scripts/missing.sh\n',
      'utf8'
    );

    const exit = run(['--staging', stagingDir], {cwd: sandbox.rootDir});
    expect(exit).toBe(1);
    expect(stdio.outputs.join('')).toContain('.gaia/scripts/missing.sh');
  });
});
