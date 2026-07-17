import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
/**
 * Tests for `gaia update merge-audit-ci`.
 *
 * Strategy: write three temporary `.gaia/audit-ci.yml` files (baseline /
 * latest / current), run the handler, and assert the JSON verdict report. The
 * command is a read-only verdict oracle: it never writes the YAML, so there are
 * no on-disk side effects to assert (the `/update-gaia` skill applies
 * `applied[]` via the Edit tool to preserve comments and order).
 */
import {mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {run} from './merge-audit-ci.js';
import type {AuditCiMergeReport} from './merge-audit-ci.js';

type Sandbox = {
  baselinePath: string;
  cleanup: () => void;
  currentPath: string;
  latestPath: string;
  root: string;
  write: (which: 'baseline' | 'current' | 'latest', contents: string) => void;
};

const setupSandbox = (): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-merge-audit-ci-'));
  const baselinePath = path.join(root, 'baseline.yaml');
  const latestPath = path.join(root, 'latest.yaml');
  const currentPath = path.join(root, 'current.yaml');

  return {
    baselinePath,
    cleanup: () => {
      rmSync(root, {force: true, recursive: true});
    },
    currentPath,
    latestPath,
    root,
    write: (which, contents): void => {
      const target =
        which === 'baseline' ? baselinePath
        : which === 'latest' ? latestPath
        : currentPath;
      writeFileSync(target, contents, 'utf8');
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

const parseJson = (outputs: readonly string[]): AuditCiMergeReport =>
  JSON.parse(outputs.join('').trim()) as AuditCiMergeReport;

const argv = (sandbox: Sandbox): string[] => [
  '--baseline',
  sandbox.baselinePath,
  '--latest',
  sandbox.latestPath,
  '--current',
  sandbox.currentPath,
  '--json',
];

describe('update merge-audit-ci', () => {
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

  test('version-only release: managed keys identical → all buckets empty', () => {
    const yaml = 'default_mode: ci\noverride_label: run-audit\nmax_turns: 60\n';
    sandbox.write('baseline', yaml);
    sandbox.write('latest', yaml);
    sandbox.write('current', yaml);

    const exit = run(argv(sandbox));
    expect(exit).toBe(0);

    const report = parseJson(stdio.outputs);
    expect(report.applied).toEqual([]);
    expect(report.conflicts).toEqual([]);
    expect(report.suggestions).toEqual([]);
  });

  test('preserves an adopter-only audit_authors entry untouched', () => {
    // Baseline / latest ship only stevensacks; the adopter committed alice + bob.
    sandbox.write('baseline', 'audit_authors: "stevensacks=local"\n');
    sandbox.write('latest', 'audit_authors: "stevensacks=local"\n');
    sandbox.write(
      'current',
      'audit_authors: "stevensacks=local alice=local bob=ci"\n'
    );

    const exit = run(argv(sandbox));
    expect(exit).toBe(0);

    const report = parseJson(stdio.outputs);
    // alice and bob are adopter-only logins: never visited, so they appear in
    // no bucket and are left exactly as the adopter committed them.
    const touchedLogins = [
      ...report.applied,
      ...report.conflicts,
      ...report.suggestions,
    ]
      .filter((item) => item.section === 'audit_authors')
      .map((item) => item.key);
    expect(touchedLogins).not.toContain('alice');
    expect(touchedLogins).not.toContain('bob');
    // stevensacks is unchanged baseline→latest, so it is a no-op too.
    expect(report.applied).toEqual([]);
    expect(report.conflicts).toEqual([]);
    expect(report.suggestions).toEqual([]);
  });

  test('applies an upstream scalar delta the adopter kept at baseline', () => {
    sandbox.write('baseline', 'override_label: run-audit\n');
    sandbox.write('latest', 'override_label: audit-now\n');
    sandbox.write('current', 'override_label: run-audit\n');

    const exit = run(argv(sandbox));
    expect(exit).toBe(0);

    const report = parseJson(stdio.outputs);
    expect(report.applied).toEqual([
      {
        adopter: 'run-audit',
        baseline: 'run-audit',
        key: 'override_label',
        kind: 'key',
        latest: 'audit-now',
      },
    ]);
    expect(report.conflicts).toEqual([]);
    expect(report.suggestions).toEqual([]);
  });

  test('conflicts a key the adopter diverged that upstream also changed', () => {
    sandbox.write('baseline', 'default_mode: ci\n');
    sandbox.write('latest', 'default_mode: local\n');
    sandbox.write('current', 'default_mode: off\n');

    const exit = run(argv(sandbox));
    expect(exit).toBe(0);

    const report = parseJson(stdio.outputs);
    expect(report.applied).toEqual([]);
    expect(report.conflicts).toEqual([
      {
        adopter: 'off',
        baseline: 'ci',
        key: 'default_mode',
        kind: 'key',
        latest: 'local',
      },
    ]);
    expect(report.suggestions).toEqual([]);
  });

  test('never returns a whole-file conflict patch for an audit_authors-only divergence', () => {
    // The only divergence is the adopter's committed audit_authors entries;
    // every managed scalar is identical baseline→latest→current. The result is
    // field-level (zero items), never a whole-file conflict.
    sandbox.write('baseline', 'default_mode: ci\noverride_label: run-audit\n');
    sandbox.write('latest', 'default_mode: ci\noverride_label: run-audit\n');
    sandbox.write(
      'current',
      'default_mode: ci\noverride_label: run-audit\naudit_authors: "alice=local bob=ci"\n'
    );

    const exit = run(argv(sandbox));
    expect(exit).toBe(0);

    const report = parseJson(stdio.outputs);
    expect(report.applied).toEqual([]);
    expect(report.conflicts).toEqual([]);
    expect(report.suggestions).toEqual([]);
  });

  test('applies an upstream audit_authors mode change the adopter kept at baseline', () => {
    // GAIA flips stevensacks ci→local; the adopter still has the baseline ci and
    // has added their own alice entry (adopter-only, untouched).
    sandbox.write('baseline', 'audit_authors: "stevensacks=ci"\n');
    sandbox.write('latest', 'audit_authors: "stevensacks=local"\n');
    sandbox.write('current', 'audit_authors: "stevensacks=ci alice=local"\n');

    const exit = run(argv(sandbox));
    expect(exit).toBe(0);

    const report = parseJson(stdio.outputs);
    expect(report.applied).toEqual([
      {
        adopter: 'ci',
        baseline: 'ci',
        key: 'stevensacks',
        kind: 'entry',
        latest: 'local',
        section: 'audit_authors',
      },
    ]);
    expect(report.conflicts).toEqual([]);
    expect(report.suggestions).toEqual([]);
  });

  test('login comparison is case-insensitive (display casing does not split an entry)', () => {
    // The adopter spelled the login StevenSacks; GAIA's baseline/latest use
    // lowercase. They are the same login, so GAIA's mode change applies.
    sandbox.write('baseline', 'audit_authors: "stevensacks=ci"\n');
    sandbox.write('latest', 'audit_authors: "stevensacks=local"\n');
    sandbox.write('current', 'audit_authors: "StevenSacks=ci"\n');

    const exit = run(argv(sandbox));
    expect(exit).toBe(0);

    const report = parseJson(stdio.outputs);
    expect(report.applied).toHaveLength(1);
    expect(report.applied[0]).toMatchObject({
      adopter: 'ci',
      baseline: 'ci',
      kind: 'entry',
      latest: 'local',
      section: 'audit_authors',
    });
    expect(report.conflicts).toEqual([]);
  });

  test('a new GAIA-authored roster member the adopter never saw lands in applied[], not suggestions[]', () => {
    // The exact FC-2 scenario this task exists for: code-audit-github-workflows
    // ships in latest and was never in the adopter's baseline or current file.
    const frontendOnly = [
      'auditors:',
      '  - name: code-audit-frontend',
      '    globs:',
      '      - "app/**"',
      '    scope: adopter',
      '    push_fixes: true',
      '    default: true',
      '',
    ].join('\n');
    const withWorkflows = `${frontendOnly}  - name: code-audit-github-workflows
    globs:
      - ".github/workflows/*.yml"
    scope: adopter
    push_fixes: false
`;

    sandbox.write('baseline', frontendOnly);
    sandbox.write('latest', withWorkflows);
    sandbox.write('current', frontendOnly);

    const exit = run(argv(sandbox));
    expect(exit).toBe(0);

    const report = parseJson(stdio.outputs);
    expect(report.suggestions).toEqual([]);
    expect(report.conflicts).toEqual([]);
    expect(report.applied).toEqual([
      {
        key: 'code-audit-github-workflows',
        kind: 'entry',
        latest: {
          globs: ['.github/workflows/*.yml'],
          push_fixes: false,
          scope: 'adopter',
        },
        section: 'auditors',
      },
    ]);
  });

  test('an adopter-added roster member is never visited by an unrelated release change', () => {
    sandbox.write(
      'baseline',
      `auditors:
  - name: code-audit-frontend
    globs:
      - "app/**"
    scope: adopter
    push_fixes: true
    default: true
`
    );
    sandbox.write(
      'latest',
      `auditors:
  - name: code-audit-frontend
    globs:
      - "app/**"
      - "test/**"
    scope: adopter
    push_fixes: true
    default: true
`
    );
    sandbox.write(
      'current',
      `auditors:
  - name: code-audit-frontend
    globs:
      - "app/**"
    scope: adopter
    push_fixes: true
    default: true
  - name: my-custom-auditor
    globs:
      - "custom/**"
    scope: adopter
    push_fixes: false
`
    );

    const exit = run(argv(sandbox));
    expect(exit).toBe(0);

    const report = parseJson(stdio.outputs);
    const touchedNames = [
      ...report.applied,
      ...report.conflicts,
      ...report.suggestions,
    ]
      .filter((item) => item.section === 'auditors')
      .map((item) => item.key);
    // The adopter's own member is never visited: not in any bucket at all.
    expect(touchedNames).not.toContain('my-custom-auditor');
    // code-audit-frontend's globs changed upstream and the adopter kept the
    // baseline value, so the clean delta applies.
    expect(report.applied).toEqual([
      {
        adopter: {
          default: true,
          globs: ['app/**'],
          push_fixes: true,
          scope: 'adopter',
        },
        baseline: {
          default: true,
          globs: ['app/**'],
          push_fixes: true,
          scope: 'adopter',
        },
        key: 'code-audit-frontend',
        kind: 'entry',
        latest: {
          default: true,
          globs: ['app/**', 'test/**'],
          push_fixes: true,
          scope: 'adopter',
        },
        section: 'auditors',
      },
    ]);
  });

  test('an adopter-edited roster member globs upstream also changed lands in conflicts[]', () => {
    sandbox.write(
      'baseline',
      `auditors:
  - name: code-audit-frontend
    globs:
      - "app/**"
    scope: adopter
    push_fixes: true
`
    );
    sandbox.write(
      'latest',
      `auditors:
  - name: code-audit-frontend
    globs:
      - "app/**"
      - "test/**"
    scope: adopter
    push_fixes: true
`
    );
    sandbox.write(
      'current',
      `auditors:
  - name: code-audit-frontend
    globs:
      - "app/**"
      - "app/routes/**"
    scope: adopter
    push_fixes: true
`
    );

    const exit = run(argv(sandbox));
    expect(exit).toBe(0);

    const report = parseJson(stdio.outputs);
    expect(report.applied).toEqual([]);
    expect(report.suggestions).toEqual([]);
    expect(report.conflicts).toHaveLength(1);
    expect(report.conflicts[0]).toMatchObject({
      key: 'code-audit-frontend',
      kind: 'entry',
      section: 'auditors',
    });
  });

  test('a roster member removed upstream but still present in baseline is a no-op', () => {
    sandbox.write(
      'baseline',
      `auditors:
  - name: code-audit-legacy
    globs:
      - "legacy/**"
    scope: adopter
    push_fixes: false
`
    );
    sandbox.write('latest', 'auditors: []\n');
    sandbox.write(
      'current',
      `auditors:
  - name: code-audit-legacy
    globs:
      - "legacy/**"
    scope: adopter
    push_fixes: false
`
    );

    const exit = run(argv(sandbox));
    expect(exit).toBe(0);

    const report = parseJson(stdio.outputs);
    expect(report.applied).toEqual([]);
    expect(report.conflicts).toEqual([]);
    expect(report.suggestions).toEqual([]);
  });

  test('a malformed roster entry (missing or non-string name) is skipped without crashing', () => {
    sandbox.write(
      'baseline',
      `auditors:
  - globs:
      - "app/**"
    scope: adopter
  - name: 42
    globs:
      - "other/**"
  - name: code-audit-frontend
    globs:
      - "app/**"
    scope: adopter
    push_fixes: true
`
    );
    sandbox.write(
      'latest',
      `auditors:
  - name: code-audit-frontend
    globs:
      - "app/**"
    scope: adopter
    push_fixes: true
`
    );
    sandbox.write(
      'current',
      `auditors:
  - name: code-audit-frontend
    globs:
      - "app/**"
    scope: adopter
    push_fixes: true
`
    );

    const exit = run(argv(sandbox));
    expect(exit).toBe(0);

    const report = parseJson(stdio.outputs);
    expect(report.applied).toEqual([]);
    expect(report.conflicts).toEqual([]);
    expect(report.suggestions).toEqual([]);
  });

  test('missing file exits non-zero with a structured error', () => {
    sandbox.write('baseline', 'default_mode: ci\n');
    sandbox.write('latest', 'default_mode: ci\n');
    // current is never written.

    const exit = run(argv(sandbox));
    expect(exit).not.toBe(0);
    expect(stdio.errors.join('')).toContain('audit_ci_file_missing');
  });
});
