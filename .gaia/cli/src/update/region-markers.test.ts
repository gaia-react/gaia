import {describe, expect, test} from 'vitest';
/**
 * Tests for `region-markers.ts`'s whole-line marker parser.
 *
 * Strategy: build small multi-line fixtures and assert `scanRegion` /
 * `maskRegion` against them directly. Pure functions, no I/O and nothing to
 * set up or tear down.
 */
import {maskRegion, REGION_PLACEHOLDER, scanRegion} from './region-markers.js';

const START = '<!-- gaia:test:start -->';
const END = '<!-- gaia:test:end -->';

describe('scanRegion', () => {
  test('one start, one end, in order → region with correct 1-based lines', () => {
    const source = ['before', START, 'inside a', 'inside b', END, 'after'].join(
      '\n'
    );
    expect(scanRegion(source, START, END)).toEqual({
      endLine: 5,
      kind: 'region',
      startLine: 2,
    });
  });

  test('absent pair → absent', () => {
    const source = ['no markers here', 'just prose'].join('\n');
    expect(scanRegion(source, START, END)).toEqual({kind: 'absent'});
  });

  test('two starts, one end → duplicate-start', () => {
    const source = [START, 'a', START, 'b', END].join('\n');
    expect(scanRegion(source, START, END)).toEqual({
      kind: 'malformed',
      reason: 'duplicate-start',
    });
  });

  test('one start, two ends → duplicate-end', () => {
    const source = [START, 'a', END, 'b', END].join('\n');
    expect(scanRegion(source, START, END)).toEqual({
      kind: 'malformed',
      reason: 'duplicate-end',
    });
  });

  test('one start, no end → unbalanced', () => {
    const source = [START, 'a', 'b'].join('\n');
    expect(scanRegion(source, START, END)).toEqual({
      kind: 'malformed',
      reason: 'unbalanced',
    });
  });

  test('no start, one end → unbalanced', () => {
    const source = ['a', 'b', END].join('\n');
    expect(scanRegion(source, START, END)).toEqual({
      kind: 'malformed',
      reason: 'unbalanced',
    });
  });

  test('end line before start line → inverted', () => {
    const source = [END, 'a', START].join('\n');
    expect(scanRegion(source, START, END)).toEqual({
      kind: 'malformed',
      reason: 'inverted',
    });
  });

  test('identical start and end markers → inverted, and maskRegion leaves the source alone', () => {
    // One line lands in both the start and end lists, so `startLine ===
    // endLine`. Without the `>=` guard this scans as a zero-length region and
    // maskRegion duplicates the marker line while masking nothing.
    const source = ['a', START, 'b', 'c'].join('\n');
    expect(scanRegion(source, START, START)).toEqual({
      kind: 'malformed',
      reason: 'inverted',
    });
    expect(maskRegion(source, START, START).masked).toBe(source);
  });

  test('substring-only line → absent (whole-line equality, not marker-strip.ts substring matching)', () => {
    const source = [
      'Use the `<!-- gaia:test:start -->` marker to delimit it.',
      'prose',
    ].join('\n');
    expect(scanRegion(source, START, END)).toEqual({kind: 'absent'});
  });

  test('leading/trailing whitespace around an otherwise-matching line → not a match', () => {
    const source = [`  ${START}`, 'a', `${END}  `].join('\n');
    expect(scanRegion(source, START, END)).toEqual({kind: 'absent'});
  });

  test('empty and whitespace-only marker arguments → absent', () => {
    const source = [START, 'a', END].join('\n');
    expect(scanRegion(source, '', END)).toEqual({kind: 'absent'});
    expect(scanRegion(source, START, '')).toEqual({kind: 'absent'});
    expect(scanRegion(source, ' '.repeat(3), END)).toEqual({kind: 'absent'});
    expect(scanRegion(source, START, '\t')).toEqual({kind: 'absent'});
  });
});

describe('maskRegion', () => {
  test('interior replaced by exactly one placeholder line, marker lines and outside content byte-identical', () => {
    const source = ['before', START, 'inside a', 'inside b', END, 'after'].join(
      '\n'
    );
    const {masked, scan} = maskRegion(source, START, END);
    expect(masked).toBe(
      ['before', START, REGION_PLACEHOLDER, END, 'after'].join('\n')
    );
    expect(scan).toEqual({endLine: 5, kind: 'region', startLine: 2});
  });

  test('empty region (markers on consecutive lines) still yields one placeholder line', () => {
    const source = [START, END].join('\n');
    const {masked} = maskRegion(source, START, END);
    expect(masked).toBe([START, REGION_PLACEHOLDER, END].join('\n'));
  });

  test('every non-region scan: output byte-identical to input', () => {
    const cases = [
      ['no markers here'].join('\n'),
      [START, 'a', START, 'b', END].join('\n'), // duplicate-start
      [START, 'a', END, 'b', END].join('\n'), // duplicate-end
      [START, 'a'].join('\n'), // unbalanced
      [END, 'a', START].join('\n'), // inverted
    ];

    for (const source of cases) {
      expect(maskRegion(source, START, END).masked).toBe(source);
    }
  });

  test('idempotence: masking already-masked output yields the same bytes', () => {
    const source = ['before', START, 'inside a', 'inside b', END, 'after'].join(
      '\n'
    );
    const once = maskRegion(source, START, END).masked;
    const twice = maskRegion(once, START, END).masked;
    expect(twice).toBe(once);
  });

  test('two sources differing only inside their regions, with different region line counts, mask to identical strings', () => {
    const short = ['before', START, 'one line', END, 'after'].join('\n');
    const long = [
      'before',
      START,
      'one line',
      'two line',
      'three line',
      END,
      'after',
    ].join('\n');

    expect(maskRegion(short, START, END).masked).toBe(
      maskRegion(long, START, END).masked
    );
  });

  test('trailing newline preservation', () => {
    const source = `${['before', START, 'inside', END, 'after'].join('\n')}\n`;
    const {masked} = maskRegion(source, START, END);
    expect(masked.endsWith('\n')).toBe(true);
    expect(masked).toBe(
      `${['before', START, REGION_PLACEHOLDER, END, 'after'].join('\n')}\n`
    );
  });
});
