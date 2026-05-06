import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {mkdirSync, mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {EXIT_CODES} from '../../exit.js';
import type {AnalyticsReport} from '../../schemas/analytics-report.js';
import {resolveStorageRoots} from '../../storage/index.js';
import type {StorageRoots} from '../../storage/index.js';
import {run as runDryRun} from '../analytics-dry-run.js';

type Sandbox = {
  cleanup: () => void;
  homeDirectory: string;
  repoRoot: string;
  roots: StorageRoots;
};

const setupSandbox = (): Sandbox => {
  const repoRoot = mkdtempSync(path.join(tmpdir(), 'gaia-dryrun-repo-'));
  const homeDirectory = mkdtempSync(path.join(tmpdir(), 'gaia-dryrun-home-'));
  const roots = resolveStorageRoots({homeDir: homeDirectory, repoRoot});

  return {
    cleanup: () => {
      rmSync(repoRoot, {force: true, recursive: true});
      rmSync(homeDirectory, {force: true, recursive: true});
    },
    homeDirectory,
    repoRoot,
    roots,
  };
};

const buildReport = (
  fieldsPresent: readonly string[]
): Record<string, unknown> => {
  const report = {
    adaptations: [],
    anonymous_install_id: '0'.repeat(26),
    audit: {
      fields_present: [...fieldsPresent],
      no_event_data: true,
      no_project_identifiers: true,
      no_user_paths: true,
      no_user_text: true,
    },
    engagement: {
      days_active_in_window: 0,
      profile_md_read_count: 0,
      sessions_in_window: 0,
      specs_closed_in_window: 0,
      tasks_completed_in_window: 0,
      weeks_since_install: 0,
    },
    gaia_version: '1.0.0',
    patterns: [],
    report_generated_at: '2026-05-07T00:00:00.000Z',
    report_id: '0'.repeat(26),
    report_window_days: 30,
    schema_version: 1,
  };

  return report;
};

const seedReport = (roots: StorageRoots, report: object): string => {
  mkdirSync(roots.analyticsDir, {mode: 0o755, recursive: true});
  const reportPath = path.join(roots.analyticsDir, 'report-2026-05-07.json');
  writeFileSync(reportPath, JSON.stringify(report));

  return reportPath;
};

describe('mentorship/analytics-dry-run', () => {
  let sandbox: Sandbox;
  let stderrSpy: ReturnType<typeof vi.spyOn>;
  let stdoutSpy: ReturnType<typeof vi.spyOn>;

  beforeEach(() => {
    sandbox = setupSandbox();
    stderrSpy = vi
      .spyOn(process.stderr, 'write')
      .mockImplementation(() => true);
    stdoutSpy = vi
      .spyOn(process.stdout, 'write')
      .mockImplementation(() => true);
  });

  afterEach(() => {
    sandbox.cleanup();
    stderrSpy.mockRestore();
    stdoutSpy.mockRestore();
  });

  test('UAT-043: prints {"code":"no_analytics_report"} when no report exists', () => {
    const exit = runDryRun([], {roots: sandbox.roots});

    expect(exit).toBe(EXIT_CODES.OK);
    const lines = (stdoutSpy.mock.calls as unknown[][]).map((call) =>
      String(call[0])
    );
    expect(lines.some((line) => line.includes('no_analytics_report'))).toBe(
      true
    );
  });

  test('UAT-043: prints the report when fields_present matches actual top-level keys', () => {
    const declaredFields = [
      'adaptations',
      'anonymous_install_id',
      'audit',
      'engagement',
      'gaia_version',
      'patterns',
      'report_generated_at',
      'report_id',
      'report_window_days',
      'schema_version',
    ];
    const report = buildReport(declaredFields);
    seedReport(sandbox.roots, report);

    const exit = runDryRun([], {roots: sandbox.roots});

    expect(exit).toBe(EXIT_CODES.OK);
    const lines = (stdoutSpy.mock.calls as unknown[][]).map((call) =>
      String(call[0])
    );
    const reportLine = lines.find((line) => line.includes('"audit"'));
    expect(reportLine).toBeDefined();
    const printed = JSON.parse(reportLine ?? '{}') as AnalyticsReport;
    expect(printed.audit.no_event_data).toBe(true);
    expect(printed.audit.fields_present).toEqual(declaredFields);
    // No mismatch warning -> stderr is silent on the happy path.
    expect(stderrSpy).not.toHaveBeenCalled();
  });

  test('UAT-043: warns to stderr when fields_present does not match actual top-level keys', () => {
    // Declare an incomplete fields_present.
    const report = buildReport(['schema_version']);
    seedReport(sandbox.roots, report);

    const exit = runDryRun([], {roots: sandbox.roots});

    // Still exits 0 on the happy path; the mismatch is a warning.
    expect(exit).toBe(EXIT_CODES.OK);
    expect(stderrSpy).toHaveBeenCalled();
    const stderrCall = stderrSpy.mock.calls[0]?.[0] as string;
    const payload = JSON.parse(stderrCall) as Record<string, unknown>;
    expect(payload.code).toBe('analytics_audit_fields_mismatch');
  });

  test('UAT-043: rejects malformed JSON with structured error', () => {
    mkdirSync(sandbox.roots.analyticsDir, {mode: 0o755, recursive: true});
    writeFileSync(
      path.join(sandbox.roots.analyticsDir, 'report-2026-05-07.json'),
      '{not json'
    );

    const exit = runDryRun([], {roots: sandbox.roots});

    expect(exit).toBe(EXIT_CODES.CONFIG_INVALID);
    const stderrCall = stderrSpy.mock.calls[0]?.[0] as string;
    const payload = JSON.parse(stderrCall) as Record<string, unknown>;
    expect(payload.code).toBe('analytics_report_malformed');
  });

  test('UAT-043: rejects schema-invalid reports', () => {
    mkdirSync(sandbox.roots.analyticsDir, {mode: 0o755, recursive: true});
    writeFileSync(
      path.join(sandbox.roots.analyticsDir, 'report-2026-05-07.json'),
      JSON.stringify({wrong: 'shape'})
    );

    const exit = runDryRun([], {roots: sandbox.roots});

    expect(exit).toBe(EXIT_CODES.CONFIG_INVALID);
    const stderrCall = stderrSpy.mock.calls[0]?.[0] as string;
    const payload = JSON.parse(stderrCall) as Record<string, unknown>;
    expect(payload.code).toBe('analytics_report_invalid');
  });

  test('UAT-043: picks the most recent report when multiple exist', () => {
    const declaredFields = [
      'adaptations',
      'anonymous_install_id',
      'audit',
      'engagement',
      'gaia_version',
      'patterns',
      'report_generated_at',
      'report_id',
      'report_window_days',
      'schema_version',
    ];
    const old = buildReport(declaredFields);
    const fresh = buildReport(declaredFields);
    fresh.report_generated_at = '2026-05-09T00:00:00.000Z';
    fresh.report_id = '1'.repeat(26);
    mkdirSync(sandbox.roots.analyticsDir, {mode: 0o755, recursive: true});
    writeFileSync(
      path.join(sandbox.roots.analyticsDir, 'report-2026-05-07.json'),
      JSON.stringify(old)
    );
    writeFileSync(
      path.join(sandbox.roots.analyticsDir, 'report-2026-05-09.json'),
      JSON.stringify(fresh)
    );

    runDryRun([], {roots: sandbox.roots});

    const lines = (stdoutSpy.mock.calls as unknown[][]).map((call) =>
      String(call[0])
    );
    const reportLine = lines.find((line) => line.includes('"audit"'));
    const printed = JSON.parse(reportLine ?? '{}') as AnalyticsReport;
    expect(printed.report_id).toBe('1'.repeat(26));
  });
});
