/**
 * Audit-block self-attestation for analytics reports.
 *
 * The four boolean assertions are real, not aspirational. The function
 * inspects the report structure recursively and computes each. If any
 * assertion would be `false`, the function THROWS — failing loud rather
 * than producing a misattested report (mirrors the cloud-projection
 * strict-by-default rule).
 *
 * `fields_present` is the actual top-level keys of the assembled report
 * (the dry-run path re-derives this and warns on drift).
 */
import type {AnalyticsReport} from '../schemas/analytics-report.js';

type AuditBlock = AnalyticsReport['audit'];

type ReportSansAudit = Omit<AnalyticsReport, 'audit'>;

/**
 * Forbidden top-level keys / substrings checked recursively across the
 * report tree. Each list maps directly to one of the four audit booleans.
 */
const EVENT_DATA_KEYS: ReadonlySet<string> = new Set([
  '_local',
  'event_id',
  'event_type',
  'payload',
  'schema_version_envelope',
  'session_hash',
]);

const USER_TEXT_KEYS: ReadonlySet<string> = new Set([
  'amendment_reason',
  'comment',
  'commit_message',
  'description',
  'message',
  'notes',
]);

const PROJECT_IDENTIFIER_KEYS: ReadonlySet<string> = new Set([
  'git_remote_url',
  'project_id',
  'repo_path',
  'repo_root',
  'workspace_path',
]);

const USER_PATH_SUBSTRINGS = ['/Users/', '/home/'] as const;

const isPlainObject = (value: unknown): value is Record<string, unknown> =>
  typeof value === 'object' && value !== null && !Array.isArray(value);

type Walker = (value: unknown, key: string | undefined) => void;

const walk = (value: unknown, visit: Walker, key?: string): void => {
  visit(value, key);

  if (Array.isArray(value)) {
    for (const entry of value) {
      walk(entry, visit);
    }

    return;
  }

  if (isPlainObject(value)) {
    for (const [childKey, childValue] of Object.entries(value)) {
      walk(childValue, visit, childKey);
    }
  }
};

const containsForbiddenKey = (
  report: ReportSansAudit,
  forbidden: ReadonlySet<string>
): boolean => {
  let found = false;
  walk(report, (_value, key) => {
    if (key !== undefined && forbidden.has(key)) {
      found = true;
    }
  });

  return found;
};

const containsUserPathSubstring = (report: ReportSansAudit): boolean => {
  let found = false;
  walk(report, (value) => {
    if (typeof value !== 'string') return;

    for (const needle of USER_PATH_SUBSTRINGS) {
      if (value.includes(needle)) {
        found = true;
      }
    }
  });

  return found;
};

class AuditDriftError extends Error {
  constructor(
    public readonly assertion: keyof AuditBlock,
    public readonly detail: string
  ) {
    super(`audit_drift: ${assertion} would be false (${detail})`);
    this.name = 'AuditDriftError';
  }
}

/**
 * Derive `fields_present` from actual top-level keys, sorted for stable output.
 * Sorting keeps the array deterministic across re-runs and machines, which
 * matters for the dry-run mismatch detector and for the golden test.
 */
const deriveFieldsPresent = (report: ReportSansAudit): string[] =>
  Object.keys(report).toSorted((a, b) => a.localeCompare(b));

/**
 * Compute the audit block. Throws `AuditDriftError` if any of the four
 * boolean assertions would be false.
 */
export const computeAuditBlock = (report: ReportSansAudit): AuditBlock => {
  if (containsForbiddenKey(report, EVENT_DATA_KEYS)) {
    throw new AuditDriftError(
      'no_event_data',
      'report contains an event-shaped key (event_id / event_type / payload / session_hash / _local)'
    );
  }

  if (containsForbiddenKey(report, USER_TEXT_KEYS)) {
    throw new AuditDriftError(
      'no_user_text',
      'report contains a free-text user field (amendment_reason / notes / message / etc.)'
    );
  }

  if (containsForbiddenKey(report, PROJECT_IDENTIFIER_KEYS)) {
    throw new AuditDriftError(
      'no_project_identifiers',
      'report contains a project-scoped identifier (project_id / repo_root / git_remote_url / etc.)'
    );
  }

  if (containsUserPathSubstring(report)) {
    throw new AuditDriftError(
      'no_user_paths',
      'report contains a string with /Users/ or /home/ substring'
    );
  }

  const allKeys = [...deriveFieldsPresent(report), 'audit'];

  return {
    fields_present: allKeys.toSorted((a, b) => a.localeCompare(b)),
    no_event_data: true,
    no_project_identifiers: true,
    no_user_paths: true,
    no_user_text: true,
  };
};

export {AuditDriftError};
