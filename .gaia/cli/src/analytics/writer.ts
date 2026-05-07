/**
 * Atomic writer for the daily analytics report.
 *
 * Path: `<roots.analyticsDir>/report-YYYY-MM-DD.json`.
 * Mode: 644.
 * Idempotency: re-running on the same day overwrites with the latest aggregate
 * (analytics is daily, not append-only).
 *
 * Atomic write: write-temp-and-rename. POSIX rename is atomic on the same
 * filesystem, so a crash mid-write leaves either the old file or the new
 * file — never a half-written one (mirrors the profile.md atomic-write contract).
 */
import {existsSync, mkdirSync, renameSync, writeFileSync} from 'node:fs';
import path from 'node:path';
import type {AnalyticsReport} from '../schemas/analytics-report.js';
import type {StorageRoots} from '../storage/paths.js';
import {isoDateUtc} from './generator.js';

type WriteArgs = {
  generatedAt?: Date;
  report: AnalyticsReport;
  roots: StorageRoots;
};

type WriteResult = {
  filePath: string;
};

const ANALYTICS_DIR_MODE = 0o755;
const REPORT_FILE_MODE = 0o644;

export const writeAnalyticsReport = async (
  args: WriteArgs
): Promise<WriteResult> => {
  const {report, roots} = args;
  const generatedAt = args.generatedAt ?? new Date();
  const dateSegment = isoDateUtc(generatedAt);
  const filePath = path.join(roots.analyticsDir, `report-${dateSegment}.json`);

  if (!existsSync(roots.analyticsDir)) {
    mkdirSync(roots.analyticsDir, {
      mode: ANALYTICS_DIR_MODE,
      recursive: true,
    });
  }

  const contents = `${JSON.stringify(report, null, 2)}\n`;
  // pid + hrtime keeps concurrent writers (multiple compute-profile chains
  // racing within the same millisecond) from clobbering each other's temp
  // file. Last writer wins on the rename; that's acceptable per the brief
  // ("re-running on the same day overwrites with the latest aggregate").
  const temporaryPath = `${filePath}.tmp-${process.pid}-${process.hrtime.bigint().toString()}`;

  writeFileSync(temporaryPath, contents, {mode: REPORT_FILE_MODE});
  renameSync(temporaryPath, filePath);

  return {filePath};
};
