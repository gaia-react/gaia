import {describe, expect, test} from 'vitest';
import {
  GENERATED_CONTENT_EXEMPT_PATHS,
  isGeneratedContentExempt,
  isWikiScanExempt,
  WIKI_SCAN_EXEMPT_PREFIXES,
} from './markdown-corpus.js';

describe('the shared wiki exemption vocabulary', () => {
  test('the base tier matches a directory by prefix', () => {
    expect(isWikiScanExempt('wiki/meta/lint-report.md')).toBe(true);
    expect(isWikiScanExempt('wiki/concepts/Design System.md')).toBe(false);
  });

  test('the base tier holds only the exemption every scan shares', () => {
    expect([...WIKI_SCAN_EXEMPT_PREFIXES]).toEqual(['wiki/meta/']);
  });

  // The two tiers are separate because their warrants are, so neither
  // predicate may answer for the other: a scan that takes the base must not
  // pick up the generated-content pages through it.
  test('the base tier does not carry the generated-content pages', () => {
    expect(isWikiScanExempt('wiki/hot.md')).toBe(false);
    expect(isWikiScanExempt('wiki/log.md')).toBe(false);
  });

  test('the generated-content tier matches its two pages exactly', () => {
    expect(isGeneratedContentExempt('wiki/hot.md')).toBe(true);
    expect(isGeneratedContentExempt('wiki/log.md')).toBe(true);
    // A Set iterates in insertion order, so this is the declaration order.
    expect([...GENERATED_CONTENT_EXEMPT_PATHS]).toEqual([
      'wiki/hot.md',
      'wiki/log.md',
    ]);
  });

  // Exact, not prefix. `dead-paths` prefix-matched these two before the
  // vocabulary was shared, which also swallowed any page whose path merely
  // started with one of them; `empty-sections` matched them exactly. Taking
  // the exact form narrows the exemption rather than widening it.
  test('the generated-content tier does not match a page that merely starts with one', () => {
    expect(isGeneratedContentExempt('wiki/log.md-archive.md')).toBe(false);
    expect(isGeneratedContentExempt('wiki/hot.md.bak')).toBe(false);
  });
});
