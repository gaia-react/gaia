/**
 * Golden test for the full report shape.
 *
 * Pins the AnalyticsReport top-level keys + audit shape so any structural
 * drift (a new field added without updating audit-attest's `fields_present`
 * derivation, a renamed engagement bucket, etc.) surfaces here loudly.
 */
import {describe, expect, test} from 'vitest';
import {mkdirSync, mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {AnalyticsReportSchema} from '../../schemas/analytics-report.js';
import {resolveStorageRoots} from '../../storage/paths.js';
import {generateAnalyticsReport} from '../generator.js';

const EXPECTED_TOP_LEVEL_KEYS = [
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
] as const;

const EXPECTED_ENGAGEMENT_KEYS = [
  'days_active_in_window',
  'profile_md_read_count',
  'sessions_in_window',
  'specs_closed_in_window',
  'tasks_completed_in_window',
  'weeks_since_install',
] as const;

const EXPECTED_AUDIT_KEYS = [
  'fields_present',
  'no_event_data',
  'no_project_identifiers',
  'no_user_paths',
  'no_user_text',
] as const;

describe('analytics/golden', () => {
  test('full report matches AnalyticsReportSchema and the golden top-level shape', async () => {
    const repoRoot = mkdtempSync(path.join(tmpdir(), 'gaia-golden-repo-'));
    const homeDirectory = mkdtempSync(path.join(tmpdir(), 'gaia-golden-home-'));

    try {
      const roots = resolveStorageRoots({homeDir: homeDirectory, repoRoot});
      mkdirSync(path.dirname(roots.installIdPath), {
        mode: 0o700,
        recursive: true,
      });
      writeFileSync(roots.installIdPath, '01HZX0K3Q9JSAWC0TR6WYJ5ZNT\n', {
        mode: 0o600,
      });
      writeFileSync(
        path.join(repoRoot, 'package.json'),
        JSON.stringify({name: 'gaia', version: '1.0.5'})
      );

      const report = await generateAnalyticsReport({
        generatedAt: new Date('2026-05-07T00:00:00.000Z'),
        patternResults: [],
        roots,
        windowDays: 30,
      });

      // Schema parse (strict) — drops anything unexpected.
      expect(() => AnalyticsReportSchema.parse(report)).not.toThrow();

      // Top-level keys exactly match the golden list.
      const topLevelKeys = Object.keys(report).toSorted((a, b) =>
        a.localeCompare(b)
      );
      expect(topLevelKeys).toEqual([...EXPECTED_TOP_LEVEL_KEYS]);

      // Engagement keys exactly match.
      const engagementKeys = Object.keys(report.engagement).toSorted((a, b) =>
        a.localeCompare(b)
      );
      expect(engagementKeys).toEqual([...EXPECTED_ENGAGEMENT_KEYS]);

      // Audit keys exactly match.
      const auditKeys = Object.keys(report.audit).toSorted((a, b) =>
        a.localeCompare(b)
      );
      expect(auditKeys).toEqual([...EXPECTED_AUDIT_KEYS]);

      // audit.fields_present is the golden top-level list (sorted).
      expect(report.audit.fields_present).toEqual([...EXPECTED_TOP_LEVEL_KEYS]);
    } finally {
      rmSync(repoRoot, {force: true, recursive: true});
      rmSync(homeDirectory, {force: true, recursive: true});
    }
  });
});
