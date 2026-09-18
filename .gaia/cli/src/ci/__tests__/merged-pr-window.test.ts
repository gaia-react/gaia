import {afterEach, describe, expect, test, vi} from 'vitest';
import {
  MERGED_PR_PAGE_CEILING,
  MERGED_PR_WINDOW_MAX_PAGES,
  readMergedPrWindow,
} from '../util/merged-pr-window.js';
import * as runProcess from '../util/run-process.js';
import type {ProcessResult} from '../util/run-process.js';

type Row = {createdAt: string; mergedAt: string; number: number};

const ok = (rows: unknown): ProcessResult => ({
  exitCode: 0,
  stderr: '',
  stdout: JSON.stringify(rows),
});

const searchOf = (args: readonly string[]): string =>
  args[args.indexOf('--search') + 1] ?? '';

const at = (minute: number): string =>
  new Date(Date.UTC(2026, 8, 1, 0, minute)).toISOString();

// `count` rows in gh's own order, newest-created first, numbered down from
// `topNumber` and created one minute apart ending at `oldestMinute`. Each
// merges a minute after it was created.
const page = (count: number, topNumber: number, oldestMinute: number): Row[] =>
  Array.from({length: count}, (_, index) => {
    const minute = oldestMinute + (count - 1 - index);

    return {
      createdAt: at(minute),
      mergedAt: at(minute + 1),
      number: topNumber - index,
    };
  });

describe('readMergedPrWindow', () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  test('reads a window below the search ceiling in one query', () => {
    const gh = vi
      .spyOn(runProcess, 'runGh')
      .mockReturnValue(ok(page(3, 30, 0)));

    const result = readMergedPrWindow<Row>({
      cwd: '/repo',
      fields: ['comments'],
      sinceIso: '2026-06-20',
    });

    expect(result).toEqual({ok: true, prs: page(3, 30, 0), truncated: false});
    expect(gh).toHaveBeenCalledTimes(1);
    const args = gh.mock.calls[0]?.[0] ?? [];
    expect(args[args.indexOf('--limit') + 1]).toBe(
      String(MERGED_PR_PAGE_CEILING)
    );
    const fields = (args[args.indexOf('--json') + 1] ?? '').split(',');
    expect(fields).toHaveLength(3);
    expect(fields).toEqual(
      expect.arrayContaining(['comments', 'createdAt', 'number'])
    );
    expect(searchOf(args)).toBe('merged:>=2026-06-20 sort:created-desc');
  });

  test('walks past a full page on the created-at sort key, keeping a PR open across the boundary', () => {
    const first = page(MERGED_PR_PAGE_CEILING, 5000, 100);
    const boundary = first.at(-1);
    // Created before the first page's oldest creation, merged after its
    // newest merge: a cursor on mergedAt would bound it out of both pages.
    const longLived: Row = {
      createdAt: at(50),
      mergedAt: at(5000),
      number: 3500,
    };
    const second = [
      ...(boundary === undefined ? [] : [boundary]),
      longLived,
      ...page(3, 3499, 0),
    ];
    const gh = vi
      .spyOn(runProcess, 'runGh')
      .mockReturnValueOnce(ok(first))
      .mockReturnValueOnce(ok(second));

    const result = readMergedPrWindow<Row>({
      cwd: '/repo',
      fields: [],
      sinceIso: '2026-06-20',
    });

    expect(gh).toHaveBeenCalledTimes(2);
    expect(searchOf(gh.mock.calls[0]?.[0] ?? [])).toBe(
      'merged:>=2026-06-20 sort:created-desc'
    );
    expect(searchOf(gh.mock.calls[1]?.[0] ?? [])).toBe(
      `merged:>=2026-06-20 sort:created-desc created:<=${boundary?.createdAt}`
    );
    expect(result).toEqual({
      ok: true,
      prs: [...first, longLived, ...page(3, 3499, 0)],
      truncated: false,
    });
  });

  test('reports truncated once the page budget is spent on full pages', () => {
    const gh = vi
      .spyOn(runProcess, 'runGh')
      .mockImplementation(() => ok(page(MERGED_PR_PAGE_CEILING, 9000, 0)));

    const result = readMergedPrWindow<Row>({
      cwd: '/repo',
      fields: [],
      sinceIso: null,
    });

    expect(gh).toHaveBeenCalledTimes(MERGED_PR_WINDOW_MAX_PAGES);
    expect(result).toMatchObject({ok: true, truncated: true});
  });

  test('pins the created-at order even with no lower bound', () => {
    const gh = vi.spyOn(runProcess, 'runGh').mockReturnValue(ok([]));

    readMergedPrWindow<Row>({cwd: '/repo', fields: [], sinceIso: null});

    expect(searchOf(gh.mock.calls[0]?.[0] ?? [])).toBe('sort:created-desc');
  });

  test.each([
    ['a non-zero gh exit', {exitCode: 1, stderr: 'boom', stdout: ''}],
    ['unparseable output', {exitCode: 0, stderr: '', stdout: 'not json'}],
    ['a non-array payload', {exitCode: 0, stderr: '', stdout: '{}'}],
  ])('reports a failed read on %s', (_label, response: ProcessResult) => {
    vi.spyOn(runProcess, 'runGh').mockReturnValue(response);

    expect(
      readMergedPrWindow<Row>({cwd: '/repo', fields: [], sinceIso: null})
    ).toEqual({ok: false});
  });
});
