/* eslint-disable no-bitwise -- POSIX file modes are bitfields; `& 0o777`
   is the standard idiom for masking off the permission bits. */
import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {execFileSync} from 'node:child_process';
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
import {EXIT_CODES} from '../../exit.js';
import {declineLedgerPath} from '../../schemas/decline-ledger.js';
import type {DeclineLedger} from '../../schemas/decline-ledger.js';
import {isValidFindingClass} from '../../schemas/finding-class.js';
import {run} from '../ledger.js';
import {isMaterialRise, TALLY_SCHEMA_VERSION} from '../material-rise.js';
import type * as MaterialRiseModule from '../material-rise.js';

// A partial mock: every other test in this file drives the real
// `isMaterialRise`, since the mock's default implementation calls through to
// the actual function. Only the spy-proof test below overrides a single call
// with `mockReturnValueOnce`, which is what makes it a guard against an
// inline reimplementation of the rule rather than a coverage line.
vi.mock('../material-rise.js', async (importOriginal) => {
  const actual = await importOriginal<typeof MaterialRiseModule>();

  return {...actual, isMaterialRise: vi.fn(actual.isMaterialRise)};
});

type Sandbox = {
  cleanup: () => void;
  ledgerPath: string;
  root: string;
};

const setupSandbox = (): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-harden-ledger-'));
  // The handler calls resolveRepoRoot, so we need a real git repo.
  execFileSync('git', ['init', '-q', '-b', 'main'], {cwd: root});

  return {
    cleanup: () => {
      rmSync(root, {force: true, recursive: true});
    },
    ledgerPath: declineLedgerPath(root),
    root,
  };
};

const captureStdio = () => {
  const out: string[] = [];
  const err: string[] = [];
  const stdoutSpy = vi
    .spyOn(process.stdout, 'write')
    .mockImplementation((chunk: unknown) => {
      out.push(typeof chunk === 'string' ? chunk : String(chunk));

      return true;
    });
  const stderrSpy = vi
    .spyOn(process.stderr, 'write')
    .mockImplementation((chunk: unknown) => {
      err.push(typeof chunk === 'string' ? chunk : String(chunk));

      return true;
    });

  return {
    err,
    out,
    restore: () => {
      stdoutSpy.mockRestore();
      stderrSpy.mockRestore();
    },
  };
};

const readLedger = (ledgerPath: string): DeclineLedger =>
  JSON.parse(readFileSync(ledgerPath, 'utf8')) as DeclineLedger;

const FIXED_NOW = new Date('2026-06-05T14:32:00.000Z');

describe('harden-ledger', () => {
  let sandbox: Sandbox;
  let io: ReturnType<typeof captureStdio>;

  beforeEach(() => {
    sandbox = setupSandbox();
    io = captureStdio();
  });

  afterEach(() => {
    io.restore();
    sandbox.cleanup();
  });

  describe('list', () => {
    test('prints the empty ledger and exits 0 on a fresh repo', () => {
      const code = run(['list'], {cwd: sandbox.root});

      expect(code).toBe(EXIT_CODES.OK);
      expect(io.out.join('')).toBe('{"version":2,"declines":[]}\n');
    });
  });

  describe('record', () => {
    test('creates exactly one entry with an ISO timestamp, pr count, and audited-pr count', () => {
      const code = run(
        [
          'record',
          '--finding-class',
          'react-doctor/no-generic-handler-names',
          '--pr-count',
          '7',
          '--audited-pr-count',
          '400',
        ],
        {cwd: sandbox.root, now: () => FIXED_NOW}
      );

      expect(code).toBe(EXIT_CODES.OK);

      const ledger = readLedger(sandbox.ledgerPath);
      expect(ledger.declines).toHaveLength(1);
      expect(ledger.declines[0]).toEqual({
        declined_at: '2026-06-05T14:32:00.000Z',
        declined_at_audited_pr_count: 400,
        declined_at_pr_count: 7,
        finding_class: 'react-doctor/no-generic-handler-names',
        tally_schema_version: TALLY_SCHEMA_VERSION,
      });
    });

    test('upserts: re-recording the same class overwrites count, denominator, and timestamp', () => {
      run(
        [
          'record',
          '--finding-class',
          'axe/color-contrast',
          '--pr-count',
          '7',
          '--audited-pr-count',
          '400',
        ],
        {
          cwd: sandbox.root,
          now: () => new Date('2026-06-01T00:00:00.000Z'),
        }
      );
      run(
        [
          'record',
          '--finding-class',
          'axe/color-contrast',
          '--pr-count',
          '9',
          '--audited-pr-count',
          '400',
        ],
        {
          cwd: sandbox.root,
          now: () => new Date('2026-06-05T00:00:00.000Z'),
        }
      );

      const ledger = readLedger(sandbox.ledgerPath);
      expect(ledger.declines).toHaveLength(1);
      expect(ledger.declines[0]).toEqual({
        declined_at: '2026-06-05T00:00:00.000Z',
        declined_at_audited_pr_count: 400,
        declined_at_pr_count: 9,
        finding_class: 'axe/color-contrast',
        tally_schema_version: TALLY_SCHEMA_VERSION,
      });
    });

    test('keeps distinct classes as separate entries', () => {
      run(
        [
          'record',
          '--finding-class',
          'knip/exports',
          '--pr-count',
          '3',
          '--audited-pr-count',
          '400',
        ],
        {cwd: sandbox.root}
      );
      run(
        [
          'record',
          '--finding-class',
          'cve/1098765',
          '--pr-count',
          '5',
          '--audited-pr-count',
          '400',
        ],
        {cwd: sandbox.root}
      );

      const ledger = readLedger(sandbox.ledgerPath);
      expect(ledger.declines).toHaveLength(2);
    });

    test('creates the harden dir with mode 755', () => {
      run(
        [
          'record',
          '--finding-class',
          'knip/types',
          '--pr-count',
          '1',
          '--audited-pr-count',
          '400',
        ],
        {cwd: sandbox.root}
      );

      const mode = statSync(path.dirname(sandbox.ledgerPath)).mode & 0o777;
      expect(mode).toBe(0o755);
    });

    test('exits non-zero when --finding-class is missing', () => {
      const code = run(
        ['record', '--pr-count', '7', '--audited-pr-count', '400'],
        {cwd: sandbox.root}
      );

      expect(code).not.toBe(EXIT_CODES.OK);
    });

    test('exits non-zero when --pr-count is missing', () => {
      const code = run(
        [
          'record',
          '--finding-class',
          'knip/exports',
          '--audited-pr-count',
          '400',
        ],
        {cwd: sandbox.root}
      );

      expect(code).not.toBe(EXIT_CODES.OK);
    });
  });

  describe('is-suppressed ratio rule (UAT-013)', () => {
    beforeEach(() => {
      run(
        [
          'record',
          '--finding-class',
          'rule/switch-statement',
          '--pr-count',
          '7',
          '--audited-pr-count',
          '400',
        ],
        {
          cwd: sandbox.root,
          now: () => FIXED_NOW,
        }
      );
    });

    test('stays suppressed below the material-rise floor (delta 1)', () => {
      const code = run(
        [
          'is-suppressed',
          '--finding-class',
          'rule/switch-statement',
          '--current-pr-count',
          '8',
          '--current-audited-pr-count',
          '400',
        ],
        {cwd: sandbox.root}
      );

      expect(code).toBe(EXIT_CODES.OK);
    });

    test('re-surfaces once the rise is material (delta 3, 10 * 4 >= 5 * 7)', () => {
      const code = run(
        [
          'is-suppressed',
          '--finding-class',
          'rule/switch-statement',
          '--current-pr-count',
          '10',
          '--current-audited-pr-count',
          '400',
        ],
        {cwd: sandbox.root}
      );

      expect(code).not.toBe(EXIT_CODES.OK);
    });

    test('exits exactly 1 for an unknown class, not an argument error', () => {
      const code = run(
        [
          'is-suppressed',
          '--finding-class',
          'holistic/n-plus-one',
          '--current-pr-count',
          '99',
          '--current-audited-pr-count',
          '400',
        ],
        {cwd: sandbox.root}
      );

      expect(code).toBe(EXIT_CODES.UNKNOWN_SUBCOMMAND);
    });
  });

  describe('is-suppressed proportional growth and schema version (UAT-013)', () => {
    beforeEach(() => {
      run(
        [
          'record',
          '--finding-class',
          'rule/ratio-target',
          '--pr-count',
          '40',
          '--audited-pr-count',
          '400',
        ],
        {cwd: sandbox.root, now: () => FIXED_NOW}
      );
    });

    test('suppressed at a proportional rise (48 / 400, ratio 1.2)', () => {
      const code = run(
        [
          'is-suppressed',
          '--finding-class',
          'rule/ratio-target',
          '--current-pr-count',
          '48',
          '--current-audited-pr-count',
          '400',
        ],
        {cwd: sandbox.root}
      );

      expect(code).toBe(EXIT_CODES.OK);
    });

    test('re-surfaces once the rise is material (50 / 400, ratio 1.25, delta 10)', () => {
      const code = run(
        [
          'is-suppressed',
          '--finding-class',
          'rule/ratio-target',
          '--current-pr-count',
          '50',
          '--current-audited-pr-count',
          '400',
        ],
        {cwd: sandbox.root}
      );

      expect(code).toBe(EXIT_CODES.UNKNOWN_SUBCOMMAND);
    });

    test('stays suppressed when both the count and the denominator grow proportionally (80 / 800)', () => {
      const code = run(
        [
          'is-suppressed',
          '--finding-class',
          'rule/ratio-target',
          '--current-pr-count',
          '80',
          '--current-audited-pr-count',
          '800',
        ],
        {cwd: sandbox.root}
      );

      expect(code).toBe(EXIT_CODES.OK);
    });

    test('an entry recorded under a stale tally_schema_version never suppresses', () => {
      mkdirSync(path.dirname(sandbox.ledgerPath), {recursive: true});
      writeFileSync(
        sandbox.ledgerPath,
        JSON.stringify({
          declines: [
            {
              declined_at: FIXED_NOW.toISOString(),
              declined_at_audited_pr_count: 400,
              declined_at_pr_count: 40,
              finding_class: 'rule/stale-schema',
              tally_schema_version: TALLY_SCHEMA_VERSION - 1,
            },
          ],
          version: 2,
        }),
        'utf8'
      );

      const code = run(
        [
          'is-suppressed',
          '--finding-class',
          'rule/stale-schema',
          '--current-pr-count',
          '40',
          '--current-audited-pr-count',
          '400',
        ],
        {cwd: sandbox.root}
      );

      expect(code).toBe(EXIT_CODES.UNKNOWN_SUBCOMMAND);
      expect(io.err.join('')).toContain('schema_version_mismatch');
    });
  });

  describe('is-suppressed floor (RISE_MIN_PR_DELTA, directive 12)', () => {
    beforeEach(() => {
      run(
        [
          'record',
          '--finding-class',
          'rule/floor-target',
          '--pr-count',
          '4',
          '--audited-pr-count',
          '400',
        ],
        {cwd: sandbox.root, now: () => FIXED_NOW}
      );
    });

    test('stays suppressed when the ratio passes but the delta misses the floor (6 / 400)', () => {
      const code = run(
        [
          'is-suppressed',
          '--finding-class',
          'rule/floor-target',
          '--current-pr-count',
          '6',
          '--current-audited-pr-count',
          '400',
        ],
        {cwd: sandbox.root}
      );

      expect(code).toBe(EXIT_CODES.OK);
    });

    test('re-surfaces once the delta reaches the floor (7 / 400)', () => {
      const code = run(
        [
          'is-suppressed',
          '--finding-class',
          'rule/floor-target',
          '--current-pr-count',
          '7',
          '--current-audited-pr-count',
          '400',
        ],
        {cwd: sandbox.root}
      );

      expect(code).toBe(EXIT_CODES.UNKNOWN_SUBCOMMAND);
    });
  });

  describe('is-suppressed decides through the shared isMaterialRise function (directive 12)', () => {
    test('calls the spy with the exact material-rise args, and an overridden verdict flips the exit code', () => {
      const spy = vi.mocked(isMaterialRise);

      run(
        [
          'record',
          '--finding-class',
          'rule/spy-target',
          '--pr-count',
          '40',
          '--audited-pr-count',
          '400',
        ],
        {cwd: sandbox.root, now: () => FIXED_NOW}
      );
      spy.mockClear();

      const suppressedCode = run(
        [
          'is-suppressed',
          '--finding-class',
          'rule/spy-target',
          '--current-pr-count',
          '48',
          '--current-audited-pr-count',
          '400',
        ],
        {cwd: sandbox.root}
      );

      expect(suppressedCode).toBe(EXIT_CODES.OK);
      expect(spy).toHaveBeenCalledTimes(1);
      expect(spy).toHaveBeenCalledWith({
        baseAuditedPrCount: 400,
        baseCount: 40,
        liveAuditedPrCount: 400,
        liveCount: 48,
      });

      spy.mockClear();
      spy.mockReturnValueOnce(true);

      const flippedCode = run(
        [
          'is-suppressed',
          '--finding-class',
          'rule/spy-target',
          '--current-pr-count',
          '48',
          '--current-audited-pr-count',
          '400',
        ],
        {cwd: sandbox.root}
      );

      // An inline reimplementation of the rule ignores the mock, so this
      // assertion fails against it: that is what makes this a guard.
      expect(flippedCode).toBe(EXIT_CODES.UNKNOWN_SUBCOMMAND);
    });
  });

  describe('prune', () => {
    beforeEach(() => {
      run(
        [
          'record',
          '--finding-class',
          'knip/exports',
          '--pr-count',
          '3',
          '--audited-pr-count',
          '400',
        ],
        {cwd: sandbox.root}
      );
      run(
        [
          'record',
          '--finding-class',
          'knip/types',
          '--pr-count',
          '4',
          '--audited-pr-count',
          '400',
        ],
        {cwd: sandbox.root}
      );
    });

    test('removes entries not in the window-classes set, keeps those in it', () => {
      const code = run(['prune', '--window-classes', 'knip/exports'], {
        cwd: sandbox.root,
      });

      expect(code).toBe(EXIT_CODES.OK);

      const ledger = readLedger(sandbox.ledgerPath);
      expect(ledger.declines).toHaveLength(1);
      expect(ledger.declines[0]?.finding_class).toBe('knip/exports');
    });

    test('is idempotent: a second prune with the same set is a no-op', () => {
      run(['prune', '--window-classes', 'knip/exports'], {cwd: sandbox.root});
      const code = run(['prune', '--window-classes', 'knip/exports'], {
        cwd: sandbox.root,
      });

      expect(code).toBe(EXIT_CODES.OK);

      const ledger = readLedger(sandbox.ledgerPath);
      expect(ledger.declines).toHaveLength(1);
    });

    test('prunes all entries when given an empty set', () => {
      const code = run(['prune', '--window-classes', ''], {cwd: sandbox.root});

      expect(code).toBe(EXIT_CODES.OK);

      const ledger = readLedger(sandbox.ledgerPath);
      expect(ledger.declines).toHaveLength(0);
    });

    // The classless fallback key carries no exemption here. Its suppression
    // baseline has to be released once the cluster stops recurring, or the next
    // unrelated classless cluster is measured against a high-water mark nothing
    // in the window still supports. Both directions are asserted because an
    // over-correction (always dropping the key) is as wrong as the exemption.
    test('treats the classless fallback key like any other: kept when the window set names it, removed when it does not', () => {
      run(
        [
          'record',
          '--finding-class',
          'holistic/unclassified',
          '--pr-count',
          '5',
          '--audited-pr-count',
          '400',
        ],
        {cwd: sandbox.root}
      );

      expect(
        run(
          ['prune', '--window-classes', 'knip/exports,holistic/unclassified'],
          {
            cwd: sandbox.root,
          }
        )
      ).toBe(EXIT_CODES.OK);
      expect(
        readLedger(sandbox.ledgerPath).declines.map((d) => d.finding_class)
      ).toEqual(['knip/exports', 'holistic/unclassified']);

      expect(
        run(['prune', '--window-classes', 'knip/exports'], {cwd: sandbox.root})
      ).toBe(EXIT_CODES.OK);
      expect(
        readLedger(sandbox.ledgerPath).declines.map((d) => d.finding_class)
      ).toEqual(['knip/exports']);
    });
  });

  describe('fallback-key round trip', () => {
    test('record / is-suppressed round-trips on the classless fallback without widening the closed vocabulary', () => {
      run(
        [
          'record',
          '--finding-class',
          'holistic/unclassified',
          '--pr-count',
          '27',
          '--audited-pr-count',
          '400',
        ],
        {cwd: sandbox.root}
      );

      const runIsSuppressed = (currentPrCount: number): number =>
        run(
          [
            'is-suppressed',
            '--finding-class',
            'holistic/unclassified',
            '--current-pr-count',
            String(currentPrCount),
            '--current-audited-pr-count',
            '400',
          ],
          {cwd: sandbox.root}
        );

      // Below the floor (delta 2): the ratio never gets evaluated.
      expect(runIsSuppressed(29)).toBe(EXIT_CODES.OK);
      // Past the floor, but the ratio still refuses (30 * 4 = 120 < 5 * 27 = 135).
      expect(runIsSuppressed(30)).toBe(EXIT_CODES.OK);
      expect(runIsSuppressed(33)).toBe(EXIT_CODES.OK);
      // The smallest count where the ratio holds (34 * 4 = 136 >= 135, delta 7).
      expect(runIsSuppressed(34)).not.toBe(EXIT_CODES.OK);

      expect(isValidFindingClass('holistic/unclassified')).toBe(false);
    });
  });

  describe('well-formed version-2 ledger', () => {
    test('a complete version-2 entry lists and is-suppresses without error', () => {
      run(
        [
          'record',
          '--finding-class',
          'rule/v2-complete',
          '--pr-count',
          '10',
          '--audited-pr-count',
          '400',
        ],
        {cwd: sandbox.root, now: () => FIXED_NOW}
      );

      const listCode = run(['list'], {cwd: sandbox.root});
      expect(listCode).toBe(EXIT_CODES.OK);
      expect(io.out.join('')).toContain('"version":2');

      const isSuppressedCode = run(
        [
          'is-suppressed',
          '--finding-class',
          'rule/v2-complete',
          '--current-pr-count',
          '11',
          '--current-audited-pr-count',
          '400',
        ],
        {cwd: sandbox.root}
      );
      expect(isSuppressedCode).toBe(EXIT_CODES.OK);
    });
  });

  describe('version-1 ledger compatibility (UAT-014)', () => {
    const legacyFixture = {
      declines: [
        {
          declined_at: '2026-08-01T00:00:00.000Z',
          declined_at_pr_count: 60,
          finding_class: 'holistic/unclassified',
        },
        {
          declined_at: '2026-08-01T00:00:00.000Z',
          declined_at_pr_count: 32,
          finding_class: 'holistic/drifting-duplicate',
        },
      ],
      version: 1,
    };

    const writeLegacyFixture = (): void => {
      mkdirSync(path.dirname(sandbox.ledgerPath), {recursive: true});
      writeFileSync(sandbox.ledgerPath, JSON.stringify(legacyFixture), 'utf8');
    };

    test('list exits 0 and prints the file with "version":1', () => {
      writeLegacyFixture();

      const code = run(['list'], {cwd: sandbox.root});

      expect(code).toBe(EXIT_CODES.OK);
      expect(io.out.join('')).toContain('"version":1');
    });

    test('is-suppressed exits 1 (never 30) with reason legacy_entry at several counts', () => {
      writeLegacyFixture();

      const cases: readonly (readonly [number, number])[] = [
        [0, 0],
        [60, 400],
        [32, 400],
      ];

      for (const [currentPrCount, currentAuditedPrCount] of cases) {
        const code = run(
          [
            'is-suppressed',
            '--finding-class',
            'holistic/unclassified',
            '--current-pr-count',
            String(currentPrCount),
            '--current-audited-pr-count',
            String(currentAuditedPrCount),
          ],
          {cwd: sandbox.root}
        );

        expect(code).toBe(EXIT_CODES.UNKNOWN_SUBCOMMAND);
      }

      expect(io.err.join('')).toContain('legacy_entry');
    });

    test('prune keeping both legacy classes does not rewrite the version-1 file', () => {
      writeLegacyFixture();
      const before = readFileSync(sandbox.ledgerPath, 'utf8');

      const code = run(
        [
          'prune',
          '--window-classes',
          'holistic/unclassified,holistic/drifting-duplicate',
        ],
        {cwd: sandbox.root}
      );

      expect(code).toBe(EXIT_CODES.OK);
      expect(readFileSync(sandbox.ledgerPath, 'utf8')).toBe(before);
    });

    test('prune that removes an entry rewrites as version 2 and keeps the surviving legacy entry byte-for-byte', () => {
      writeLegacyFixture();

      const code = run(['prune', '--window-classes', 'holistic/unclassified'], {
        cwd: sandbox.root,
      });

      expect(code).toBe(EXIT_CODES.OK);

      const ledger = readLedger(sandbox.ledgerPath);
      expect(ledger.version).toBe(2);
      expect(ledger.declines).toEqual([legacyFixture.declines[0]]);
    });

    test('record on a version-1 file upgrades it to version 2 and carries legacy entries forward', () => {
      writeLegacyFixture();

      const code = run(
        [
          'record',
          '--finding-class',
          'holistic/other',
          '--pr-count',
          '5',
          '--audited-pr-count',
          '100',
        ],
        {cwd: sandbox.root, now: () => FIXED_NOW}
      );

      expect(code).toBe(EXIT_CODES.OK);

      const ledger = readLedger(sandbox.ledgerPath);
      expect(ledger.version).toBe(2);

      const newEntry = ledger.declines.find(
        (decline) => decline.finding_class === 'holistic/other'
      );
      expect(newEntry).toEqual({
        declined_at: FIXED_NOW.toISOString(),
        declined_at_audited_pr_count: 100,
        declined_at_pr_count: 5,
        finding_class: 'holistic/other',
        tally_schema_version: TALLY_SCHEMA_VERSION,
      });
      expect(ledger.declines).toContainEqual(legacyFixture.declines[0]);
      expect(ledger.declines).toContainEqual(legacyFixture.declines[1]);

      expect(run(['list'], {cwd: sandbox.root})).toBe(EXIT_CODES.OK);

      for (const findingClass of [
        'holistic/unclassified',
        'holistic/drifting-duplicate',
      ]) {
        const isSuppressedCode = run(
          [
            'is-suppressed',
            '--finding-class',
            findingClass,
            '--current-pr-count',
            '0',
            '--current-audited-pr-count',
            '0',
          ],
          {cwd: sandbox.root}
        );
        expect(isSuppressedCode).toBe(EXIT_CODES.UNKNOWN_SUBCOMMAND);
      }
    });
  });

  describe('argument-error refusal (directive 1)', () => {
    test('is-suppressed without --current-audited-pr-count exits 2 (INVALID_ARGUMENTS)', () => {
      const code = run(
        ['is-suppressed', '--finding-class', 'x', '--current-pr-count', '3'],
        {cwd: sandbox.root}
      );

      expect(code).toBe(EXIT_CODES.INVALID_ARGUMENTS);
    });

    test('is-suppressed with an unknown flag exits 2 (INVALID_ARGUMENTS)', () => {
      const code = run(['is-suppressed', '--bogus'], {cwd: sandbox.root});

      expect(code).toBe(EXIT_CODES.INVALID_ARGUMENTS);
    });

    test('record without --audited-pr-count exits 1 and writes nothing', () => {
      const code = run(['record', '--finding-class', 'x', '--pr-count', '1'], {
        cwd: sandbox.root,
      });

      expect(code).toBe(EXIT_CODES.UNKNOWN_SUBCOMMAND);
      expect(existsSync(sandbox.ledgerPath)).toBe(false);
    });
  });

  describe('corrupt file', () => {
    test('list fails loud (non-zero, structured error) rather than treating as empty', () => {
      run(
        [
          'record',
          '--finding-class',
          'knip/exports',
          '--pr-count',
          '1',
          '--audited-pr-count',
          '400',
        ],
        {cwd: sandbox.root}
      );
      writeFileSync(sandbox.ledgerPath, '{ not valid json', 'utf8');

      const code = run(['list'], {cwd: sandbox.root});

      expect(code).not.toBe(EXIT_CODES.OK);
      expect(io.err.join('')).toContain('malformed_ledger');
    });

    test('is-suppressed fails loud rather than re-surfacing a declined class', () => {
      // Seed a valid entry first so the harden dir exists, then corrupt it.
      run(
        [
          'record',
          '--finding-class',
          'knip/exports',
          '--pr-count',
          '1',
          '--audited-pr-count',
          '400',
        ],
        {cwd: sandbox.root}
      );
      writeFileSync(
        sandbox.ledgerPath,
        JSON.stringify({declines: 'nope', version: 2}),
        'utf8'
      );

      const code = run(
        [
          'is-suppressed',
          '--finding-class',
          'knip/exports',
          '--current-pr-count',
          '1',
          '--current-audited-pr-count',
          '400',
        ],
        {cwd: sandbox.root}
      );

      expect(code).toBe(EXIT_CODES.CONFIG_INVALID);
      expect(io.err.join('')).toContain('malformed_ledger');
    });
  });

  describe('snapshot dispatch', () => {
    test('show with no snapshot returns 1 without throwing; record then show returns 0', () => {
      const showBeforeCode = run(['snapshot', 'show'], {cwd: sandbox.root});
      expect(showBeforeCode).toBe(EXIT_CODES.UNKNOWN_SUBCOMMAND);

      const tallyPath = path.join(sandbox.root, 'tally.json');
      writeFileSync(
        tallyPath,
        JSON.stringify({
          audited_pr_count: 400,
          class_inventory: [
            {distinct_pr_count: 40, finding_class: 'holistic/a'},
          ],
          gh_ok: true,
          tally_schema_version: TALLY_SCHEMA_VERSION,
          unclassified_window_count: null,
          window_days: 90,
        }),
        'utf8'
      );

      const recordCode = run(
        ['snapshot', 'record', '--tally-file', 'tally.json'],
        {cwd: sandbox.root}
      );
      expect(recordCode).toBe(EXIT_CODES.OK);

      const showAfterCode = run(['snapshot', 'show'], {cwd: sandbox.root});
      expect(showAfterCode).toBe(EXIT_CODES.OK);
    });
  });

  describe('unknown subcommand', () => {
    test('exits non-zero', () => {
      const code = run(['frobnicate'], {cwd: sandbox.root});

      expect(code).not.toBe(EXIT_CODES.OK);
    });
  });
});
