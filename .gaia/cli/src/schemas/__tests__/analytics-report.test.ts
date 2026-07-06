import {describe, expect, test} from 'vitest';
import {AnalyticsReportSchema} from '../analytics-report.js';

const baseEngagement = {
  days_active_in_window: 7,
  profile_md_read_count: 0,
  sessions_in_window: 12,
  specs_closed_in_window: 3,
  tasks_completed_in_window: 18,
  weeks_since_install: 2,
};

const baseAudit = {
  fields_present: [
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
  ],
  no_event_data: true,
  no_project_identifiers: true,
  no_user_paths: true,
  no_user_text: true,
} as const;

const baseReport = {
  adaptations: [],
  anonymous_install_id: '01HZX0K3Q9JSAWC0TR6WYJ5ZNT',
  audit: baseAudit,
  engagement: baseEngagement,
  gaia_version: '1.0.5',
  patterns: [],
  report_generated_at: '2026-05-06T12:34:56.789Z',
  report_id: 'report-2026-05-06',
  report_window_days: 30,
  schema_version: 1,
};

describe('schemas/analytics-report', () => {
  test('accepts a minimal good report (empty patterns/adaptations)', () => {
    expect(() => AnalyticsReportSchema.parse(baseReport)).not.toThrow();
  });

  test('accepts a report with patterns and adaptations populated', () => {
    expect(() =>
      AnalyticsReportSchema.parse({
        ...baseReport,
        adaptations: [
          {
            adaptation_id: 'po_socratic_depth_increased',
            fire_count: 5,
            linked_pattern: 'articulation_gap',
            outcome: {
              after_sample_size: 30,
              after_window_value: 0.18,
              before_sample_size: 30,
              before_window_value: 0.4,
              target_metric: 'needs_context_returned_rate',
            },
            weeks_since_first_fire: 3,
          },
        ],
        patterns: [
          {
            avg_strength_at_fire: 0.65,
            fire_count: 4,
            min_sample_size_met: true,
            pattern_id: 'articulation_gap',
            strength_p10: 0.5,
            strength_p90: 0.8,
          },
        ],
      })
    ).not.toThrow();
  });

  test('audit-block all-true assertions: rejects no_event_data: false', () => {
    expect(() =>
      AnalyticsReportSchema.parse({
        ...baseReport,
        audit: {...baseAudit, no_event_data: false},
      })
    ).toThrow();
  });

  test('audit-block all-true assertions: rejects no_user_paths: false', () => {
    expect(() =>
      AnalyticsReportSchema.parse({
        ...baseReport,
        audit: {...baseAudit, no_user_paths: false},
      })
    ).toThrow();
  });

  test('audit-block all-true assertions: rejects no_user_text: false', () => {
    expect(() =>
      AnalyticsReportSchema.parse({
        ...baseReport,
        audit: {...baseAudit, no_user_text: false},
      })
    ).toThrow();
  });

  test('audit-block all-true assertions: rejects no_project_identifiers: false', () => {
    expect(() =>
      AnalyticsReportSchema.parse({
        ...baseReport,
        audit: {...baseAudit, no_project_identifiers: false},
      })
    ).toThrow();
  });

  test('rejects schema_version != 1', () => {
    expect(() =>
      AnalyticsReportSchema.parse({...baseReport, schema_version: 2})
    ).toThrow();
  });

  test('rejects report_window_days != 30', () => {
    expect(() =>
      AnalyticsReportSchema.parse({...baseReport, report_window_days: 7})
    ).toThrow();
  });

  test('rejects unknown top-level keys (strict)', () => {
    expect(() =>
      AnalyticsReportSchema.parse({...baseReport, extra: 'leak'})
    ).toThrow();
  });

  test('rejects pattern strength outside [0, 1]', () => {
    expect(() =>
      AnalyticsReportSchema.parse({
        ...baseReport,
        patterns: [
          {
            avg_strength_at_fire: 1.2,
            fire_count: 1,
            min_sample_size_met: true,
            pattern_id: 'foo',
            strength_p10: 0,
            strength_p90: 1,
          },
        ],
      })
    ).toThrow();
  });

  test('accepts an ISO-8601 datetime for report_generated_at', () => {
    expect(() =>
      AnalyticsReportSchema.parse({
        ...baseReport,
        report_generated_at: '2026-05-06T12:34:56.789Z',
      })
    ).not.toThrow();
  });

  test('rejects a non-datetime string for report_generated_at', () => {
    expect(() =>
      AnalyticsReportSchema.parse({
        ...baseReport,
        report_generated_at: 'not-a-timestamp',
      })
    ).toThrow();
  });

  test('accepts adaptation with null outcome', () => {
    expect(() =>
      AnalyticsReportSchema.parse({
        ...baseReport,
        adaptations: [
          {
            adaptation_id: 'foo',
            fire_count: 1,
            linked_pattern: 'bar',
            outcome: null,
            weeks_since_first_fire: 1,
          },
        ],
      })
    ).not.toThrow();
  });
});
