/* eslint-disable unicorn/prevent-abbreviations -- `analyticsDir` mirrors the
   frozen `StorageRoots.analyticsDir` field name (see
   `.gaia/cli/src/storage/paths.ts`). */
/**
 * `gaia mentorship analytics dry-run`.
 *
 * 1. Read latest `<repoRoot>/.gaia/local/telemetry/analytics/report-YYYY-MM-DD.json`.
 * 2. If no report exists → print `{"code":"no_analytics_report"}` → exit 0.
 * 3. Validate against AnalyticsReportSchema.
 * 4. Re-derive `audit.fields_present` from actual top-level keys; warn on
 *    mismatch.
 * 5. Print the report JSON to stdout.
 * 6. Never make any network call.
 */
import {existsSync, readdirSync, readFileSync} from 'node:fs';
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import {AnalyticsReportSchema} from '../schemas/analytics-report.js';
import {structuredError} from '../stderr.js';
import {resolveStorageRoots} from '../storage/paths.js';
import type {StorageRoots} from '../storage/paths.js';

type RunOptions = {
  roots?: StorageRoots;
};

const REPORT_GLOB = /^report-\d{4}-\d{2}-\d{2}\.json$/u;

const sortAlpha = (entries: readonly string[]): string[] => {
  const copy = [...entries];

  return copy.toSorted((a, b) => a.localeCompare(b));
};

const findLatestReport = (analyticsDir: string): null | string => {
  if (!existsSync(analyticsDir)) return null;
  let entries: string[];

  try {
    entries = readdirSync(analyticsDir);
  } catch {
    return null;
  }
  const matching = entries
    .filter((entry) => REPORT_GLOB.test(entry))
    .toSorted((a, b) => a.localeCompare(b));
  const last = matching.at(-1);

  return last === undefined ? null : path.join(analyticsDir, last);
};

export const run = (
  _argv: readonly string[],
  options: RunOptions = {}
): number => {
  const roots = options.roots ?? resolveStorageRoots();
  const reportPath = findLatestReport(roots.analyticsDir);

  if (reportPath === null) {
    process.stdout.write(`${JSON.stringify({code: 'no_analytics_report'})}\n`);

    return EXIT_CODES.OK;
  }
  let raw: string;

  try {
    raw = readFileSync(reportPath, 'utf8');
  } catch (error) {
    structuredError({
      code: 'storage_inaccessible',
      message: error instanceof Error ? error.message : String(error),
      path: reportPath,
    });

    return EXIT_CODES.STORAGE_INACCESSIBLE;
  }
  let parsed: unknown;

  try {
    parsed = JSON.parse(raw) as unknown;
  } catch (error) {
    structuredError({
      code: 'analytics_report_malformed',
      message: error instanceof Error ? error.message : String(error),
      path: reportPath,
    });

    return EXIT_CODES.CONFIG_INVALID;
  }
  const validation = AnalyticsReportSchema.safeParse(parsed);

  if (!validation.success) {
    structuredError({
      code: 'analytics_report_invalid',
      issues: validation.error.issues,
      path: reportPath,
    });

    return EXIT_CODES.CONFIG_INVALID;
  }
  const report = validation.data;
  const actualKeys = sortAlpha(Object.keys(report));
  const declaredKeys = sortAlpha(report.audit.fields_present);
  const fieldsMatch =
    actualKeys.length === declaredKeys.length &&
    actualKeys.every((key, index) => key === declaredKeys[index]);

  if (!fieldsMatch) {
    structuredError({
      actual_fields: actualKeys,
      code: 'analytics_audit_fields_mismatch',
      declared_fields: declaredKeys,
    });
  }
  process.stdout.write(`${JSON.stringify(report)}\n`);

  return EXIT_CODES.OK;
};
