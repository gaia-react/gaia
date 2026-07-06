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

export type DeclinedRecord = {
  /** ISO-8601 stamp of when the group was snoozed; the 14-day cap counts from here. */
  declined_at: string;
  /** Companion group id, or `singleton:<name>`. */
  group: string;
  /** Each member's declined target version at snooze time (`name -> version`). */
  targets: Readonly<Record<string, string>>;
};

/**
 * A currently-active snooze, surfaced in the emitted updates payload so the
 * interactive preview can mark the group and default-skip it. Distinct from the
 * payload's `skipped` list (policy-filtered *this run*): a `SnoozedGroup` is a
 * group the human deferred earlier that is still within its snooze window.
 */
export type SnoozedGroup = {
  /** Companion group id, or `singleton:<name>`. */
  group: string;
  /** ISO-8601 stamp when the snooze lapses (`declined_at` + `MAX_SNOOZE_MS`). */
  resurfaces_at: string;
  /** ISO-8601 stamp when the group was snoozed. */
  snoozed_at: string;
  /** The snoozed target versions (`name -> version`), matching the current offer. */
  targets: Readonly<Record<string, string>>;
};

type DeclinedLedger = {
  declined: readonly DeclinedRecord[];
  schema_version: 1;
};

export const declinedLedgerPath = (cwd: string): string =>
  path.join(cwd, LEDGER_RELATIVE_PATH);

/**
 * Validate and normalize one raw ledger entry. Returns `null` for anything
 * malformed (wrong shape, non-string field, non-string target version) so
 * one bad record only drops itself, not the whole ledger.
 *
 * `entry` is cast through `Record<string, unknown>`, not `Partial<DeclinedRecord>`:
 * the latter would tell TypeScript `targets` can never be `null`, masking the
 * genuine "arbitrary untrusted JSON" runtime possibility this function exists
 * to guard against.
 */
const parseDeclinedRecord = (entry: unknown): DeclinedRecord | null => {
  if (entry === null || typeof entry !== 'object') return null;

  const record = entry as Record<string, unknown>;
  const {declined_at: declinedAt, group, targets: rawTargets} = record;

  if (typeof group !== 'string') return null;
  if (typeof declinedAt !== 'string') return null;
  if (rawTargets === null || typeof rawTargets !== 'object') return null;

  const targets: Record<string, string> = {};

  for (const [name, version] of Object.entries(
    rawTargets as Record<string, unknown>
  )) {
    if (typeof version !== 'string') return null;
    targets[name] = version;
  }

  return {declined_at: declinedAt, group, targets};
};

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

  const {declined} = parsed as {declined?: unknown};

  if (!Array.isArray(declined)) return [];

  const out: DeclinedRecord[] = [];

  for (const entry of declined) {
    const record = parseDeclinedRecord(entry);

    if (record !== null) out.push(record);
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

export type DeclineQueryArgs = {
  currentTargets: Readonly<Record<string, string>>;
  declines: readonly DeclinedRecord[];
  group: string;
  now: Date;
};

/** Whether `record` is the active snooze for `context`'s group and current
 * target versions (matching group + target snapshot, younger than
 * `MAX_SNOOZE_MS`). */
const isActiveDecline = (
  record: DeclinedRecord,
  context: Omit<DeclineQueryArgs, 'declines'>
): boolean => {
  if (record.group !== context.group) return false;
  if (!targetsEqual(record.targets, context.currentTargets)) return false;

  const declinedAtMs = Date.parse(record.declined_at);

  if (!Number.isFinite(declinedAtMs)) return false;

  return context.now.getTime() - declinedAtMs < MAX_SNOOZE_MS;
};

/**
 * The active snooze record for a group's current target versions, or
 * `undefined` when none applies. A record matches when its group and target
 * snapshot equal the current ones AND it is younger than `MAX_SNOOZE_MS`. Any
 * target moving, a sibling joining/leaving the group (target-key set changes),
 * or the cap elapsing breaks the match, so a stale record never matches.
 */
export const findActiveDecline = (
  args: DeclineQueryArgs
): DeclinedRecord | undefined =>
  args.declines.find((record) => isActiveDecline(record, args));

/**
 * Whether a group's current target versions are currently snoozed. Thin
 * boolean wrapper over {@link findActiveDecline}.
 */
export const isSuppressed = (args: DeclineQueryArgs): boolean =>
  findActiveDecline(args) !== undefined;

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

  const record = (item: {
    current: string;
    group: string;
    latest: string;
    name: string;
  }): void => {
    if (item.current === item.latest) return;

    const existing = map.get(item.group);

    if (existing === undefined) {
      map.set(item.group, {[item.name]: item.latest});

      return;
    }

    existing[item.name] = item.latest;
  };

  for (const entry of payload.wave_a) {
    record(entry);
  }

  for (const groupEntry of payload.wave_b) {
    for (const pkg of groupEntry.packages) {
      record({
        current: pkg.current,
        group: groupEntry.group,
        latest: pkg.latest,
        name: pkg.name,
      });
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
    const suppressed = isSuppressed({
      currentTargets: targets,
      declines,
      group,
      now,
    });

    if (!suppressed) count += Object.keys(targets).length;
  }

  return count;
};

/**
 * Every outstanding group whose current target versions are actively snoozed,
 * with the snooze metadata the preview needs to annotate and default-skip it.
 * A group appears only when it has a genuine upgrade AND an active decline for
 * exactly its current targets; the same match `computeActionableCount` uses to
 * suppress it from the count. Sorted by group id for a deterministic payload.
 */
export const collectSnoozedGroups = (
  payload: CountablePayload,
  declines: readonly DeclinedRecord[],
  now: Date
): readonly SnoozedGroup[] => {
  const out: SnoozedGroup[] = [];

  for (const [group, targets] of collectOutstandingGroups(payload)) {
    const record = findActiveDecline({
      currentTargets: targets,
      declines,
      group,
      now,
    });

    if (record !== undefined) {
      // `declined_at` parsed finite already; findActiveDecline filtered NaN.
      const resurfacesAtMs = Date.parse(record.declined_at) + MAX_SNOOZE_MS;

      out.push({
        group,
        resurfaces_at: new Date(resurfacesAtMs).toISOString(),
        snoozed_at: record.declined_at,
        targets,
      });
    }
  }

  return out.toSorted((a, b) =>
    a.group < b.group ? -1
    : a.group > b.group ? 1
    : 0
  );
};
