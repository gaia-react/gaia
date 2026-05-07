/* eslint-disable no-bitwise -- POSIX file mode masking. */
import {decodeTime} from 'ulid';
import {afterEach, beforeEach, describe, expect, test} from 'vitest';
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {AnalyticsReportSchema} from '../../schemas/analytics-report.js';
import {resolveStorageRoots} from '../../storage/paths.js';
import type {StorageRoots} from '../../storage/paths.js';
import {generateAnalyticsReport} from '../generator.js';
import type {PatternResult} from '../generator.js';
import {writeAnalyticsReport} from '../writer.js';

type Sandbox = {
  cleanup: () => void;
  homeDirectory: string;
  repoRoot: string;
  roots: StorageRoots;
};

const setupSandbox = (): Sandbox => {
  const repoRoot = mkdtempSync(path.join(tmpdir(), 'gaia-analytics-repo-'));
  const homeDirectory = mkdtempSync(
    path.join(tmpdir(), 'gaia-analytics-home-')
  );
  const roots = resolveStorageRoots({homeDir: homeDirectory, repoRoot});
  // ensure the slug parent dir tree exists so install-id can be written
  mkdirSync(path.dirname(roots.installIdPath), {mode: 0o700, recursive: true});
  // package.json with a known version
  writeFileSync(
    path.join(repoRoot, 'package.json'),
    JSON.stringify({name: 'gaia', version: '1.0.5'})
  );

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

const seedInstallId = (roots: StorageRoots, id: string): void => {
  writeFileSync(roots.installIdPath, `${id}\n`, {mode: 0o600});
};

const seedMentorshipEvent = (
  roots: StorageRoots,
  date: string,
  event: Record<string, unknown>
): void => {
  if (!existsSync(roots.mentorshipDir)) {
    mkdirSync(roots.mentorshipDir, {mode: 0o700, recursive: true});
  }
  const filePath = path.join(roots.mentorshipDir, `events-${date}.jsonl`);
  const line = `${JSON.stringify(event)}\n`;

  if (existsSync(filePath)) {
    const existing = readFileSync(filePath, 'utf8');
    writeFileSync(filePath, existing + line, {mode: 0o600});
  } else {
    writeFileSync(filePath, line, {mode: 0o600});
  }
};

describe('analytics/generator', () => {
  let sandbox: Sandbox;

  beforeEach(() => {
    sandbox = setupSandbox();
  });

  afterEach(() => {
    sandbox.cleanup();
  });

  test('produces a schema-valid report with empty inputs', async () => {
    const generatedAt = new Date('2026-05-07T12:00:00.000Z');
    seedInstallId(sandbox.roots, '01HZX0K3Q9JSAWC0TR6WYJ5ZNT');

    const report = await generateAnalyticsReport({
      generatedAt,
      patternResults: [],
      roots: sandbox.roots,
      windowDays: 30,
    });

    expect(() => AnalyticsReportSchema.parse(report)).not.toThrow();
    expect(report.report_window_days).toBe(30);
    expect(report.schema_version).toBe(1);
    expect(report.gaia_version).toBe('1.0.5');
    expect(report.audit.no_event_data).toBe(true);
    expect(report.audit.no_user_paths).toBe(true);
    expect(report.audit.no_user_text).toBe(true);
    expect(report.audit.no_project_identifiers).toBe(true);
  });

  test('audit.fields_present matches the actual top-level keys (sorted)', async () => {
    seedInstallId(sandbox.roots, '01HZX0K3Q9JSAWC0TR6WYJ5ZNT');
    const report = await generateAnalyticsReport({
      generatedAt: new Date('2026-05-07T12:00:00.000Z'),
      patternResults: [],
      roots: sandbox.roots,
      windowDays: 30,
    });
    const actualKeys = Object.keys(report).toSorted((a, b) =>
      a.localeCompare(b)
    );
    expect(report.audit.fields_present).toEqual(actualKeys);
  });

  test('weeks_since_install derives from install-id ULID timestamp', async () => {
    // ULID seeded ~3 weeks before generatedAt
    const generatedAt = new Date('2026-05-07T00:00:00.000Z');
    const installMs = generatedAt.getTime() - 21 * 86_400_000;
    // craft a ULID with a known timestamp using the public ulid factory
    const {ulid} = await import('ulid');
    const installId = ulid(installMs);
    seedInstallId(sandbox.roots, installId);

    const report = await generateAnalyticsReport({
      generatedAt,
      patternResults: [],
      roots: sandbox.roots,
      windowDays: 30,
    });

    expect(report.engagement.weeks_since_install).toBe(3);
    // sanity: round-trip the install-id timestamp
    expect(decodeTime(installId)).toBe(installMs);
  });

  test('sessions_in_window counts distinct session_hash values', async () => {
    const generatedAt = new Date('2026-05-07T00:00:00.000Z');
    seedInstallId(sandbox.roots, '01HZX0K3Q9JSAWC0TR6WYJ5ZNT');
    const inWindowDate = '2026-05-06';
    seedMentorshipEvent(sandbox.roots, inWindowDate, {
      event_type: 'uat_pass',
      session_hash: 'a'.repeat(32),
      timestamp: '2026-05-06T10:00:00.000Z',
    });
    seedMentorshipEvent(sandbox.roots, inWindowDate, {
      event_type: 'uat_pass',
      session_hash: 'a'.repeat(32),
      timestamp: '2026-05-06T11:00:00.000Z',
    });
    seedMentorshipEvent(sandbox.roots, inWindowDate, {
      event_type: 'uat_fail',
      session_hash: 'b'.repeat(32),
      timestamp: '2026-05-06T12:00:00.000Z',
    });

    const report = await generateAnalyticsReport({
      generatedAt,
      patternResults: [],
      roots: sandbox.roots,
      windowDays: 30,
    });

    expect(report.engagement.sessions_in_window).toBe(2);
    expect(report.engagement.tasks_completed_in_window).toBe(3);
    expect(report.engagement.days_active_in_window).toBe(1);
  });

  test('counts time_to_resolved_spec events as specs_closed_in_window', async () => {
    seedInstallId(sandbox.roots, '01HZX0K3Q9JSAWC0TR6WYJ5ZNT');
    seedMentorshipEvent(sandbox.roots, '2026-05-06', {
      event_type: 'time_to_resolved_spec',
      session_hash: 'a'.repeat(32),
      timestamp: '2026-05-06T10:00:00.000Z',
    });
    seedMentorshipEvent(sandbox.roots, '2026-05-06', {
      event_type: 'time_to_resolved_spec',
      session_hash: 'b'.repeat(32),
      timestamp: '2026-05-06T11:00:00.000Z',
    });

    const report = await generateAnalyticsReport({
      generatedAt: new Date('2026-05-07T00:00:00.000Z'),
      patternResults: [],
      roots: sandbox.roots,
      windowDays: 30,
    });

    expect(report.engagement.specs_closed_in_window).toBe(2);
  });

  test('events outside the 30-day window are excluded', async () => {
    seedInstallId(sandbox.roots, '01HZX0K3Q9JSAWC0TR6WYJ5ZNT');
    seedMentorshipEvent(sandbox.roots, '2026-03-01', {
      event_type: 'uat_pass',
      session_hash: 'old'.padEnd(32, 'x'),
      timestamp: '2026-03-01T10:00:00.000Z',
    });

    const report = await generateAnalyticsReport({
      generatedAt: new Date('2026-05-07T00:00:00.000Z'),
      patternResults: [],
      roots: sandbox.roots,
      windowDays: 30,
    });

    expect(report.engagement.tasks_completed_in_window).toBe(0);
  });

  test('pattern aggregates flag min_sample_size_met when sample_count >= 10', async () => {
    seedInstallId(sandbox.roots, '01HZX0K3Q9JSAWC0TR6WYJ5ZNT');
    const patternResults: PatternResult[] = [
      {
        area_tag: 'visual',
        pattern_id: 'articulation_gap',
        sample_count: 12,
        strength: 0.65,
      },
      {
        area_tag: 'visual',
        pattern_id: 'sparse',
        sample_count: 3,
        strength: null,
      },
    ];

    const report = await generateAnalyticsReport({
      generatedAt: new Date('2026-05-07T00:00:00.000Z'),
      patternResults,
      roots: sandbox.roots,
      windowDays: 30,
    });

    expect(report.patterns).toHaveLength(2);
    const articulationGap = report.patterns.find(
      (p) => p.pattern_id === 'articulation_gap'
    );
    const sparse = report.patterns.find((p) => p.pattern_id === 'sparse');
    expect(articulationGap?.min_sample_size_met).toBe(true);
    expect(articulationGap?.fire_count).toBe(1);
    expect(sparse?.min_sample_size_met).toBe(false);
    expect(sparse?.fire_count).toBe(0);
  });

  test('falls back to gaia_version "unknown" when package.json is absent', async () => {
    rmSync(path.join(sandbox.repoRoot, 'package.json'), {force: true});
    seedInstallId(sandbox.roots, '01HZX0K3Q9JSAWC0TR6WYJ5ZNT');

    const report = await generateAnalyticsReport({
      generatedAt: new Date('2026-05-07T00:00:00.000Z'),
      patternResults: [],
      roots: sandbox.roots,
      windowDays: 30,
    });

    expect(report.gaia_version).toBe('unknown');
  });
});

describe('analytics/writer', () => {
  let sandbox: Sandbox;

  beforeEach(() => {
    sandbox = setupSandbox();
  });

  afterEach(() => {
    sandbox.cleanup();
  });

  test('writes report-YYYY-MM-DD.json with mode 644 (atomic, idempotent)', async () => {
    seedInstallId(sandbox.roots, '01HZX0K3Q9JSAWC0TR6WYJ5ZNT');
    const generatedAt = new Date('2026-05-07T00:00:00.000Z');
    const report = await generateAnalyticsReport({
      generatedAt,
      patternResults: [],
      roots: sandbox.roots,
      windowDays: 30,
    });

    const {filePath} = await writeAnalyticsReport({
      generatedAt,
      report,
      roots: sandbox.roots,
    });

    expect(filePath).toBe(
      path.join(sandbox.roots.analyticsDir, 'report-2026-05-07.json')
    );
    expect(existsSync(filePath)).toBe(true);
    expect(statSync(filePath).mode & 0o777).toBe(0o644);
    const onDisk = JSON.parse(readFileSync(filePath, 'utf8')) as unknown;
    expect(() => AnalyticsReportSchema.parse(onDisk)).not.toThrow();
  });

  test('overwrites the same-day file on second write (idempotent overwrite)', async () => {
    seedInstallId(sandbox.roots, '01HZX0K3Q9JSAWC0TR6WYJ5ZNT');
    const generatedAt = new Date('2026-05-07T00:00:00.000Z');
    const first = await generateAnalyticsReport({
      generatedAt,
      patternResults: [],
      roots: sandbox.roots,
      windowDays: 30,
    });
    const {filePath} = await writeAnalyticsReport({
      generatedAt,
      report: first,
      roots: sandbox.roots,
    });
    const second = await generateAnalyticsReport({
      generatedAt,
      patternResults: [],
      roots: sandbox.roots,
      windowDays: 30,
    });
    await writeAnalyticsReport({
      generatedAt,
      report: second,
      roots: sandbox.roots,
    });

    const onDisk = JSON.parse(readFileSync(filePath, 'utf8')) as {
      report_id: string;
    };
    expect(onDisk.report_id).toBe(second.report_id);
  });
});
