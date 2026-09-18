import {describe, expect, test} from 'vitest';
import {
  isMaterialRise,
  MIN_TRUSTED_AUDITED_PRS,
  RISE_MIN_PR_DELTA,
  RISE_RATIO_DEN,
  RISE_RATIO_NUM,
  TALLY_SCHEMA_VERSION,
} from '../material-rise.js';

describe('isMaterialRise', () => {
  test.each([
    [
      'ratio exactly 1.25, delta 10',
      {
        baseAuditedPrCount: 400,
        baseCount: 40,
        liveAuditedPrCount: 400,
        liveCount: 50,
      },
      true,
    ],
    [
      'ratio 1.225',
      {
        baseAuditedPrCount: 400,
        baseCount: 40,
        liveAuditedPrCount: 400,
        liveCount: 49,
      },
      false,
    ],
    [
      'ratio 1.5 but delta 2: floor refuses',
      {
        baseAuditedPrCount: 400,
        baseCount: 4,
        liveAuditedPrCount: 400,
        liveCount: 6,
      },
      false,
    ],
    [
      'ratio 1.75, delta 3',
      {
        baseAuditedPrCount: 400,
        baseCount: 4,
        liveAuditedPrCount: 400,
        liveCount: 7,
      },
      true,
    ],
    [
      'share unchanged; proportional growth never fires',
      {
        baseAuditedPrCount: 400,
        baseCount: 40,
        liveAuditedPrCount: 800,
        liveCount: 80,
      },
      false,
    ],
    [
      'ratio exactly 1.25 at higher counts',
      {
        baseAuditedPrCount: 400,
        baseCount: 120,
        liveAuditedPrCount: 400,
        liveCount: 150,
      },
      true,
    ],
    [
      'ratio 1.2',
      {
        baseAuditedPrCount: 400,
        baseCount: 40,
        liveAuditedPrCount: 400,
        liveCount: 48,
      },
      false,
    ],
    [
      'proportional growth, small counts',
      {
        baseAuditedPrCount: 400,
        baseCount: 2,
        liveAuditedPrCount: 800,
        liveCount: 4,
      },
      false,
    ],
    [
      'delta below floor',
      {
        baseAuditedPrCount: 400,
        baseCount: 2,
        liveAuditedPrCount: 400,
        liveCount: 3,
      },
      false,
    ],
    [
      'raw branch: a denominator below 20',
      {
        baseAuditedPrCount: 16,
        baseCount: 4,
        liveAuditedPrCount: 32,
        liveCount: 8,
      },
      true,
    ],
    [
      'raw branch, delta 2',
      {
        baseAuditedPrCount: 16,
        baseCount: 4,
        liveAuditedPrCount: 32,
        liveCount: 6,
      },
      false,
    ],
    [
      'raw branch because 19 < 20, even though the share falls',
      {
        baseAuditedPrCount: 19,
        baseCount: 10,
        liveAuditedPrCount: 400,
        liveCount: 13,
      },
      true,
    ],
    [
      'both denominators trusted, share falls: raw branch is gated on the < 20 condition, not always on',
      {
        baseAuditedPrCount: 20,
        baseCount: 10,
        liveAuditedPrCount: 400,
        liveCount: 13,
      },
      false,
    ],
    [
      'delta meets the floor, ratio does not: the ratio arm refuses on its own',
      {
        baseAuditedPrCount: 400,
        baseCount: 40,
        liveAuditedPrCount: 400,
        liveCount: 43,
      },
      false,
    ],
  ])('%s => %s', (_label, args, expected) => {
    expect(isMaterialRise(args)).toBe(expected);
  });

  test('the constants are fixed by design', () => {
    expect(RISE_RATIO_NUM).toBe(5);
    expect(RISE_RATIO_DEN).toBe(4);
    expect(RISE_MIN_PR_DELTA).toBe(3);
    expect(MIN_TRUSTED_AUDITED_PRS).toBe(20);
    expect(TALLY_SCHEMA_VERSION).toBe(1);
  });
});
