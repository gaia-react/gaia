/**
 * Declined-update ("snooze") ledger for `gaia update-deps`.
 *
 * The interactive `/update-deps` preview lets a human skip specific update
 * groups this run. A skipped group is recorded here so the statusline nudge
 * stops counting it. The snooze is deliberately not permanent: a record only
 * suppresses while its group's target versions are unchanged AND it is younger
 * than the 14-day cap, so a newer release or the cap elapsing resurfaces it.
 *
 * Scope: this ledger feeds the statusline count ONLY. The preview always shows
 * snoozed groups as updatable; nothing here gates the apply set.
 *
 * The file lives at `.gaia/local/declined-updates.json`, which is gitignored,
 * so the CI update-deps cron (a fresh checkout) never sees it: CI is the
 * "don't forget long-term" backstop and keeps opening PRs regardless. The CLI
 * READS this on the hot path (`update-deps run`) and WRITES it only via the
 * explicit `update-deps decline` subcommand; the statusline refresher never
 * writes, keeping the hot path race-free (mirrors the dep-audit baseline).
 */
import {mkdirSync, readFileSync, writeFileSync} from 'node:fs';
import path from 'node:path';

/** A declined group reappears once it is this old, regardless of versions. */
export const MAX_SNOOZE_MS = 14 * 24 * 60 * 60 * 1000;

const LEDGER_RELATIVE_PATH = path.join(
  '.gaia',
  'local',
  'declined-updates.json'
);

export type DeclinedRecord = {
  /** ISO-8601 stamp of when the group was snoozed; the 14-day cap counts from here. */
  declined_at: string;
  /** Companion group id, or `singleton:<name>`. */
  group: string;
  /** Each member's declined target version at snooze time (`name -> version`). */
  targets: Readonly<Record<string, string>>;
};

type DeclinedLedger = {
  declined: readonly DeclinedRecord[];
  schema_version: 1;
};

/**
 * Minimal structural view of the emitted updates payload, just the fields the
 * count helpers need. Declared locally (not imported from `run.ts`) so this
 * module stays free of an import cycle.
 */
export type CountablePayload = {
  wave_a: readonly {
    current: string;
    group: string;
    latest: string;
    name: string;
  }[];
  wave_b: readonly {
    group: string;
    packages: readonly {current: string; latest: string; name: string}[];
  }[];
};

export const declinedLedgerPath = (cwd: string): string =>
  path.join(cwd, LEDGER_RELATIVE_PATH);

/**
 * Read the ledger, tolerating a missing file, malformed JSON, and individual
 * malformed records (any of which yield an empty / shorter list rather than an
 * error). A missing or unreadable ledger means "nothing snoozed".
 */
export const loadDeclines = (cwd: string): readonly DeclinedRecord[] => {
  let raw: string;

  try {
    raw = readFileSync(declinedLedgerPath(cwd), 'utf8');
  } catch {
    return [];
  }

  let parsed: unknown;

  try {
    parsed = JSON.parse(raw);
  } catch {
    return [];
  }

  if (parsed === null || typeof parsed !== 'object') return [];

  const declined = (parsed as {declined?: unknown}).declined;

  if (!Array.isArray(declined)) return [];

  const out: DeclinedRecord[] = [];

  for (const entry of declined) {
    if (entry === null || typeof entry !== 'object') continue;

    const obj = entry as Partial<DeclinedRecord>;

    if (typeof obj.group !== 'string') continue;
    if (typeof obj.declined_at !== 'string') continue;
    if (obj.targets === null || typeof obj.targets !== 'object') continue;

    const targets: Record<string, string> = {};
    let wellFormed = true;

    for (const [name, version] of Object.entries(
      obj.targets as Record<string, unknown>
    )) {
      if (typeof version !== 'string') {
        wellFormed = false;
        break;
      }
      targets[name] = version;
    }

    if (!wellFormed) continue;

    out.push({declined_at: obj.declined_at, group: obj.group, targets});
  }

  return out;
};

/** Overwrite the ledger with exactly `declined` (full-replace, parent dir created). */
export const saveDeclines = (
  cwd: string,
  declined: readonly DeclinedRecord[]
): void => {
  const ledger: DeclinedLedger = {declined, schema_version: 1};
  const outPath = declinedLedgerPath(cwd);

  mkdirSync(path.dirname(outPath), {recursive: true});
  writeFileSync(outPath, `${JSON.stringify(ledger, null, 2)}\n`, 'utf8');
};

const targetsEqual = (
  a: Readonly<Record<string, string>>,
  b: Readonly<Record<string, string>>
): boolean => {
  const aKeys = Object.keys(a);

  if (aKeys.length !== Object.keys(b).length) return false;

  for (const key of aKeys) {
    if (a[key] !== b[key]) return false;
  }

  return true;
};

/**
 * Whether a group's current target versions are currently snoozed. A record
 * matches when its group and target snapshot equal the current ones AND it is
 * younger than `MAX_SNOOZE_MS`. Any target moving, a sibling joining/leaving
 * the group (target-key set changes), or the cap elapsing breaks the match.
 */
export const isSuppressed = (
  group: string,
  currentTargets: Readonly<Record<string, string>>,
  declines: readonly DeclinedRecord[],
  now: Date
): boolean => {
  for (const record of declines) {
    if (record.group !== group) continue;
    if (!targetsEqual(record.targets, currentTargets)) continue;

    const declinedAtMs = Date.parse(record.declined_at);

    if (!Number.isFinite(declinedAtMs)) continue;
    if (now.getTime() - declinedAtMs >= MAX_SNOOZE_MS) continue;

    return true;
  }

  return false;
};

/**
 * Aggregate the payload into `group -> {name: latest}`, counting only genuine
 * upgrades (`current !== latest`). Companion-group sibling expansion can pull
 * an already-current package into a wave; those no-ops are excluded so the
 * count means "packages that will actually move", matching the statusline.
 * Wave A rows share a `group` and collapse into one entry; each Wave B group is
 * already one entry. A group id appears in exactly one wave, so merging is safe.
 * A group with no genuine upgrade does not appear.
 */
export const collectOutstandingGroups = (
  payload: CountablePayload
): ReadonlyMap<string, Readonly<Record<string, string>>> => {
  const map = new Map<string, Record<string, string>>();

  const record = (
    group: string,
    name: string,
    current: string,
    latest: string
  ): void => {
    if (current === latest) return;

    const existing = map.get(group);

    if (existing === undefined) {
      map.set(group, {[name]: latest});

      return;
    }

    existing[name] = latest;
  };

  for (const entry of payload.wave_a) {
    record(entry.group, entry.name, entry.current, entry.latest);
  }

  for (const groupEntry of payload.wave_b) {
    for (const pkg of groupEntry.packages) {
      record(groupEntry.group, pkg.name, pkg.current, pkg.latest);
    }
  }

  return map;
};

/** Total outstanding upgrade packages across both waves (pre-suppression). */
export const totalCount = (payload: CountablePayload): number => {
  let count = 0;

  for (const targets of collectOutstandingGroups(payload).values()) {
    count += Object.keys(targets).length;
  }

  return count;
};

/**
 * Outstanding upgrade count after removing every currently-suppressed group.
 * This is the number the statusline nudge shows.
 */
export const computeActionableCount = (
  payload: CountablePayload,
  declines: readonly DeclinedRecord[],
  now: Date
): number => {
  let count = 0;

  for (const [group, targets] of collectOutstandingGroups(payload)) {
    if (isSuppressed(group, targets, declines, now)) continue;

    count += Object.keys(targets).length;
  }

  return count;
};
