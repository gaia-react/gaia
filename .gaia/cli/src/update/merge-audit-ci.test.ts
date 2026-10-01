/**
 * Strategy: write three temporary `.gaia/audit-ci.yml` files (baseline /
 * latest / current), run the handler, and assert the JSON verdict report. The
 * command is a read-only verdict oracle: it never writes the YAML, so there are
 * no on-disk side effects to assert (the `/update-gaia` skill applies
 * `applied[]` via the Edit tool to preserve comments and order).
 */
import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
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

  test('version-only release: roster identical → all buckets empty', () => {
    const yaml =
      'auditors:\n  - name: code-audit-frontend\n    globs:\n      - "app/**"\n    audience: adopter\n    default: true\n';
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

  test('legacy top-level keys in the adopter file are neither applied nor flagged', () => {
    // An adopter file written by an older version still carries the keys that
    // version managed. The new latest drops them, so they are not read at all:
    // zero items for them, even when the adopter edited one.
    const legacy = [
      'gate_label: null',
      'budget_seconds: 1800',
      'default_mode: ci',
      'audit_authors: "bob=ci"',
      'retrigger_workflows:',
      '  - Tests',
    ].join('\n');
    sandbox.write('baseline', `${legacy}\npush_fixes: true\n`);
    sandbox.write('latest', '{}\n');
    sandbox.write('current', `${legacy}\npush_fixes: false\n`);

    const exit = run(argv(sandbox));
    expect(exit).toBe(0);

    const report = parseJson(stdio.outputs);
    expect(report.applied).toEqual([]);
    expect(report.conflicts).toEqual([]);
    expect(report.suggestions).toEqual([]);
  });

  test('a top-level key only latest carries is not suggested', () => {
    sandbox.write('baseline', 'default_mode: ci\n');
    sandbox.write('latest', 'push_fixes: true\n');
    sandbox.write('current', 'default_mode: ci\n');

    const exit = run(argv(sandbox));
    expect(exit).toBe(0);

    const report = parseJson(stdio.outputs);
    expect(report.applied).toEqual([]);
    expect(report.conflicts).toEqual([]);
    expect(report.suggestions).toEqual([]);
  });

  test('a new GAIA-authored roster member the adopter never saw lands in applied[], not suggestions[]', () => {
    // The exact FC-2 scenario this task exists for: code-audit-github-workflows
    // ships in latest and was never in the adopter's baseline or current file.
    const frontendOnly = [
      'auditors:',
      '  - name: code-audit-frontend',
      '    globs:',
      '      - "app/**"',
      '    audience: adopter',
      '    push_fixes: true',
      '    default: true',
      '',
    ].join('\n');
    const withWorkflows = `${frontendOnly}  - name: code-audit-github-workflows
    globs:
      - ".github/workflows/*.yml"
    audience: adopter
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
          audience: 'adopter',
          globs: ['.github/workflows/*.yml'],
          push_fixes: false,
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
    audience: adopter
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
    audience: adopter
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
    audience: adopter
    push_fixes: true
    default: true
  - name: my-custom-auditor
    globs:
      - "custom/**"
    audience: adopter
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
          audience: 'adopter',
          default: true,
          globs: ['app/**'],
          push_fixes: true,
        },
        baseline: {
          audience: 'adopter',
          default: true,
          globs: ['app/**'],
          push_fixes: true,
        },
        key: 'code-audit-frontend',
        kind: 'entry',
        latest: {
          audience: 'adopter',
          default: true,
          globs: ['app/**', 'test/**'],
          push_fixes: true,
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
    audience: adopter
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
    audience: adopter
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
    audience: adopter
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
    audience: adopter
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
    audience: adopter
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
    audience: adopter
  - name: 42
    globs:
      - "other/**"
  - name: code-audit-frontend
    globs:
      - "app/**"
    audience: adopter
    push_fixes: true
`
    );
    sandbox.write(
      'latest',
      `auditors:
  - name: code-audit-frontend
    globs:
      - "app/**"
    audience: adopter
    push_fixes: true
`
    );
    sandbox.write(
      'current',
      `auditors:
  - name: code-audit-frontend
    globs:
      - "app/**"
    audience: adopter
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
    sandbox.write('baseline', 'auditors: []\n');
    sandbox.write('latest', 'auditors: []\n');
    // current is never written.

    const exit = run(argv(sandbox));
    expect(exit).not.toBe(0);
    expect(stdio.errors.join('')).toContain('audit_ci_file_missing');
  });

  test('an unknown flag exits non-zero with invalid_arguments', () => {
    sandbox.write('baseline', 'auditors: []\n');
    sandbox.write('latest', 'auditors: []\n');
    sandbox.write('current', 'auditors: []\n');

    const exit = run([...argv(sandbox), '--nope']);

    expect(exit).not.toBe(0);
    expect(stdio.errors.join('')).toContain('invalid_arguments');
  });
});
