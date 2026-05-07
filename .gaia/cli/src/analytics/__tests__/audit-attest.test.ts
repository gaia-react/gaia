import {describe, expect, test} from 'vitest';
import type {AnalyticsReport} from '../../schemas/analytics-report.js';
import {AuditDriftError, computeAuditBlock} from '../audit-attest.js';

type ReportSansAudit = Omit<AnalyticsReport, 'audit'>;

const baseReport: ReportSansAudit = {
  adaptations: [],
  anonymous_install_id: '01HZX0K3Q9JSAWC0TR6WYJ5ZNT',
  engagement: {
    days_active_in_window: 7,
    profile_md_read_count: 0,
    sessions_in_window: 12,
    specs_closed_in_window: 3,
    tasks_completed_in_window: 18,
    weeks_since_install: 2,
  },
  gaia_version: '1.0.5',
  patterns: [],
  report_generated_at: '2026-05-06T12:34:56.789Z',
  report_id: '01HZX0K3Q9JSAWC0TR6WYJ5ZNT',
  report_window_days: 30,
  schema_version: 1,
};

describe('analytics/audit-attest', () => {
  test('computes audit block with all four assertions true on a clean body', () => {
    const audit = computeAuditBlock(baseReport);

    expect(audit.no_event_data).toBe(true);
    expect(audit.no_user_paths).toBe(true);
    expect(audit.no_user_text).toBe(true);
    expect(audit.no_project_identifiers).toBe(true);
  });

  test('fields_present matches actual top-level keys (sorted, includes audit)', () => {
    const audit = computeAuditBlock(baseReport);
    const allKeys = [...Object.keys(baseReport), 'audit'];
    const expected = allKeys.toSorted((a, b) => a.localeCompare(b));

    expect(audit.fields_present).toEqual(expected);
  });

  test('throws when report contains an event_id field anywhere', () => {
    const polluted = {
      ...baseReport,
      patterns: [
        {
          avg_strength_at_fire: 0.5,

          event_id: 'leaked',
          fire_count: 1,
          min_sample_size_met: true,
          pattern_id: 'foo',
          strength_p10: 0.5,
          strength_p90: 0.5,
        },
      ],
    } as unknown as ReportSansAudit;

    expect(() => computeAuditBlock(polluted)).toThrow(AuditDriftError);
  });

  test('throws when a string contains /Users/ substring', () => {
    const polluted: ReportSansAudit = {
      ...baseReport,
      gaia_version: 'leaked /Users/foo',
    };

    expect(() => computeAuditBlock(polluted)).toThrow(AuditDriftError);
  });

  test('throws when a string contains /home/ substring (Linux variant)', () => {
    const polluted: ReportSansAudit = {
      ...baseReport,
      gaia_version: 'leaked /home/bar',
    };

    expect(() => computeAuditBlock(polluted)).toThrow(AuditDriftError);
  });

  test('throws when an amendment_reason field is present', () => {
    const polluted = {
      ...baseReport,
      adaptations: [
        {
          adaptation_id: 'foo',
          amendment_reason: 'free text leak',
          fire_count: 1,
          linked_pattern: 'bar',
          outcome: null,
          weeks_since_first_fire: 1,
        },
      ],
    } as unknown as ReportSansAudit;

    expect(() => computeAuditBlock(polluted)).toThrow(AuditDriftError);
  });

  test('throws when a project_id field is present', () => {
    const polluted = {
      ...baseReport,
      project_id: 'leaked',
    } as unknown as ReportSansAudit;

    expect(() => computeAuditBlock(polluted)).toThrow(AuditDriftError);
  });

  test('throws when a payload key surfaces (event-data shape)', () => {
    const polluted = {
      ...baseReport,
      payload: {anything: 'goes'},
    } as unknown as ReportSansAudit;

    expect(() => computeAuditBlock(polluted)).toThrow(AuditDriftError);
  });

  test('throws when a _local namespace surfaces', () => {
    const polluted = {
      ...baseReport,
      _local: {git_author_email: 'x@y.z'},
    } as unknown as ReportSansAudit;

    expect(() => computeAuditBlock(polluted)).toThrow(AuditDriftError);
  });
});
