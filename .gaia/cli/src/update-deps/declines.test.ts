import {mkdtempSync, readFileSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {afterEach, beforeEach, describe, expect, test} from 'vitest';
import {
  MAX_SNOOZE_MS,
  collectOutstandingGroups,
  computeActionableCount,
  declinedLedgerPath,
  isSuppressed,
  loadDeclines,
  saveDeclines,
  totalCount,
  type CountablePayload,
  type DeclinedRecord,
} from './declines.js';

type Sandbox = {cleanup: () => void; root: string};

const setupSandbox = (): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-declines-'));

  return {
    cleanup: () => rmSync(root, {force: true, recursive: true}),
    root,
  };
};

// A two-group outstanding payload: `react-router` (Wave B, 2 members) and the
// `singleton:left-pad` (Wave A, 1 member). Used across the count tests.
const payload: CountablePayload = {
  wave_a: [
    {
      current: '1.3.0',
      group: 'singleton:left-pad',
      latest: '1.4.0',
      name: 'left-pad',
    },
  ],
  wave_b: [
    {
      group: 'react-router',
      packages: [
        {current: '7.1.0', latest: '7.2.0', name: 'react-router'},
        {current: '7.1.0', latest: '7.2.0', name: 'react-router-dom'},
      ],
    },
  ],
};

const reactRouterTargets = {
  'react-router': '7.2.0',
  'react-router-dom': '7.2.0',
};

const now = new Date('2026-06-11T18:00:00.000Z');

const declineRecord = (
  overrides: Partial<DeclinedRecord> = {}
): DeclinedRecord => ({
  declined_at: now.toISOString(),
  group: 'react-router',
  targets: reactRouterTargets,
  ...overrides,
});

describe('declines ledger I/O', () => {
  let sandbox: Sandbox;

  beforeEach(() => {
    sandbox = setupSandbox();
  });

  afterEach(() => {
    sandbox.cleanup();
  });

  test('loadDeclines returns empty when the ledger is absent', () => {
    expect(loadDeclines(sandbox.root)).toEqual([]);
  });

  test('saveDeclines then loadDeclines round-trips records', () => {
    const records = [declineRecord()];
    saveDeclines(sandbox.root, records);
    expect(loadDeclines(sandbox.root)).toEqual(records);
  });

  test('saveDeclines writes to .gaia/local/declined-updates.json', () => {
    saveDeclines(sandbox.root, [declineRecord()]);
    const expected = path.join(
      sandbox.root,
      '.gaia',
      'local',
      'declined-updates.json'
    );
    expect(declinedLedgerPath(sandbox.root)).toBe(expected);
    const parsed = JSON.parse(readFileSync(expected, 'utf8')) as unknown;
    expect(parsed).toMatchObject({schema_version: 1});
  });

  test('loadDeclines tolerates malformed JSON and drops bad records', () => {
    const ledger = declinedLedgerPath(sandbox.root);
    saveDeclines(sandbox.root, []); // ensure parent dir exists
    writeFileSync(
      ledger,
      JSON.stringify({
        declined: [
          declineRecord(),
          {group: 'no-targets'},
          {declined_at: now.toISOString(), group: 'x', targets: {a: 1}},
        ],
        schema_version: 1,
      }),
      'utf8'
    );
    // Only the well-formed record survives.
    expect(loadDeclines(sandbox.root)).toEqual([declineRecord()]);
  });
});

describe('isSuppressed', () => {
  test('matches on equal group + targets inside the 14-day window', () => {
    expect(
      isSuppressed('react-router', reactRouterTargets, [declineRecord()], now)
    ).toBe(true);
  });

  test('does not match when a target version moved', () => {
    const moved = {...reactRouterTargets, 'react-router': '7.3.0'};
    expect(isSuppressed('react-router', moved, [declineRecord()], now)).toBe(
      false
    );
  });

  test('does not match when a new sibling joins the group', () => {
    const grown = {...reactRouterTargets, '@react-router/dev': '7.2.0'};
    expect(isSuppressed('react-router', grown, [declineRecord()], now)).toBe(
      false
    );
  });

  test('still suppressed one day before the 14-day cap', () => {
    const later = new Date(now.getTime() + MAX_SNOOZE_MS - 24 * 3600 * 1000);
    expect(
      isSuppressed('react-router', reactRouterTargets, [declineRecord()], later)
    ).toBe(true);
  });

  test('resurfaces once the 14-day cap elapses', () => {
    const later = new Date(now.getTime() + MAX_SNOOZE_MS);
    expect(
      isSuppressed('react-router', reactRouterTargets, [declineRecord()], later)
    ).toBe(false);
  });
});

describe('count helpers', () => {
  test('totalCount counts every Wave A and Wave B package', () => {
    expect(totalCount(payload)).toBe(3);
  });

  test('computeActionableCount equals totalCount when nothing is declined', () => {
    expect(computeActionableCount(payload, [], now)).toBe(3);
  });

  test('computeActionableCount subtracts a suppressed group', () => {
    // react-router (2 packages) suppressed → only left-pad remains.
    expect(computeActionableCount(payload, [declineRecord()], now)).toBe(1);
  });

  test('an aged-out decline no longer suppresses', () => {
    const later = new Date(now.getTime() + MAX_SNOOZE_MS);
    expect(computeActionableCount(payload, [declineRecord()], later)).toBe(3);
  });

  test('collectOutstandingGroups aggregates Wave A rows and Wave B packages', () => {
    const groups = collectOutstandingGroups(payload);
    expect(groups.get('react-router')).toEqual(reactRouterTargets);
    expect(groups.get('singleton:left-pad')).toEqual({'left-pad': '1.4.0'});
  });

  test('a pulled-along up-to-date sibling is not counted', () => {
    // @types/react is current === latest (a sibling dragged in by the group);
    // it must not inflate the count or appear in the group targets.
    const withSibling: CountablePayload = {
      wave_a: [],
      wave_b: [
        {
          group: 'react',
          packages: [
            {current: '18.0.0', latest: '19.0.0', name: 'react'},
            {current: '19.0.0', latest: '19.0.0', name: '@types/react'},
          ],
        },
      ],
    };
    expect(totalCount(withSibling)).toBe(1);
    expect(collectOutstandingGroups(withSibling).get('react')).toEqual({
      react: '19.0.0',
    });
  });
});
