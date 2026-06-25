import {readFileSync} from 'node:fs';
import {expect, test} from '@playwright/test';
import type {Page} from '@playwright/test';
import {collectRenderDump, installRenderCapture} from '../react-perf/capture';
import type {RawDump} from '../react-perf/types';
import {hydration} from '../utils';

// Version-bump canary: a stable, named app component reliably rendered by the
// micro-interaction. GAIA ships no memo-wrapped component, so the expected memo
// flag is false; a bippy/React bump that breaks tag or name resolution flips
// this and fails loud.
const CANARY = 'ThemeSwitch';

const readDump = (rawPath: string): RawDump =>
  JSON.parse(readFileSync(rawPath, 'utf8')) as RawDump;

const totalRenderTime = (dump: RawDump): number =>
  dump.all.reduce((sum, record) => sum + record.totalTime, 0);

// Drive the canary micro-interaction: click the ThemeSwitch toggle in the
// header. It is a submit button that flips the optimistic theme mode (a local
// subtree re-render), NOT a navigation, so ThemeSwitch re-renders on `update`.
const driveThemeToggle = async (page: Page): Promise<void> => {
  const toggle = page.locator('header').getByRole('button');
  await expect(toggle).toBeVisible();
  const before = await toggle.getAttribute('aria-label');
  await toggle.click();
  // Wait for the optimistic update render to commit (label reflects next mode).
  await expect(toggle).not.toHaveAttribute('aria-label', before ?? '');
};

test('captures bippy renders: active, canary resolves name + memo + timing', async ({
  page,
}) => {
  await installRenderCapture(page);
  await page.goto('/');
  await hydration(page);
  await driveThemeToggle(page);

  const result = await collectRenderDump(page);

  // Contract D: writes renders.json under .gaia/local/cache/<run>/.
  expect(result.rawPath).toMatch(/\.gaia\/local\/cache\/[^/]+\/renders\.json$/);
  expect(result.recordCount).toBeGreaterThan(0);

  // §6 #1 + #4: went active, commits observed, no swallowed errors.
  expect(result.meta.installed).toBe(true);
  expect(result.meta.commits).toBeGreaterThan(0);
  expect(result.meta.errors).toEqual([]);

  // §6 #3 + #8: profiling available, self-describing meta.
  expect(result.meta.profilingAvailable).toBe(true);
  expect(result.meta.rendererVersion).toBeTruthy();
  expect(result.meta.bippyVersion).toBe('0.5.42');

  // §6 #2: a default (StrictMode-on) run is flagged so Phase 2 caveats timings.
  expect(result.meta.strictMode).toBe(true);

  const dump = readDump(result.rawPath);
  expect(dump.total).toBe(result.recordCount);

  // §6 #5: every emitted record is a real render; didCommit is a boolean.
  for (const record of dump.all) {
    expect(record.didRender).toBe(true);
    expect(typeof record.didCommit).toBe('boolean');
  }

  // §6 #2 + #6: records carry phase + a numeric fiberId; update records exist.
  const updates = dump.all.filter((record) => record.phase === 'update');
  expect(updates.length).toBeGreaterThan(0);
  for (const record of dump.all) {
    expect(typeof record.phase).toBe('string');
    expect(Number.isFinite(record.fiberId)).toBe(true);
  }

  // §6 #6: change entries serialize to short type labels, never raw values.
  for (const record of dump.all) {
    const changes = [
      ...record.propsChanged,
      ...record.stateChanged,
      ...record.contextChanged,
    ];
    for (const change of changes) {
      expect(typeof change.prev).toBe('string');
      expect(typeof change.next).toBe('string');
      expect(change.prev.length).toBeLessThan(32);
      expect(change.next.length).toBeLessThan(32);
    }
  }

  // §6 #7 + #8: the canary resolves a real name, the expected memo flag, and a
  // non-zero subtree timing; the toggle drives it on an update render.
  const canaryRecords = dump.all.filter((record) => record.componentName === CANARY);
  expect(canaryRecords.length).toBeGreaterThan(0);
  expect(canaryRecords.every((record) => record.componentName !== 'Unknown')).toBe(true);
  expect(canaryRecords.every((record) => record.isMemo === false)).toBe(true);
  expect(canaryRecords.some((record) => record.totalTime > 0)).toBe(true);
  expect(canaryRecords.some((record) => record.phase === 'update')).toBe(true);
});

test('noStrict bypass disables StrictMode (render-time inflation collapses)', async ({
  browser,
  baseURL,
}) => {
  const load = async (isStrictModeDisabled: boolean) => {
    const context = await browser.newContext({baseURL});
    const page = await context.newPage();
    await installRenderCapture(page, {isStrictModeDisabled});
    await page.goto('/');
    await hydration(page);
    const result = await collectRenderDump(page);
    const dump = readDump(result.rawPath);
    await context.close();
    return {meta: result.meta, total: totalRenderTime(dump)};
  };

  // SSR hydration shows no StrictMode mount→unmount→remount burst, so render
  // COUNTS are identical with or without StrictMode. The one observable effect
  // is the double-invoke: React sums both render passes into actualDuration, so
  // a StrictMode-on capture's aggregate render time runs materially higher.
  // Two interleaved loads per mode damp single-run jitter.
  const strictA = await load(false);
  const relaxedA = await load(true);
  const strictB = await load(false);
  const relaxedB = await load(true);

  // meta.strictMode reflects the bypass (Phase 2 keys the timing caveat on it).
  expect(strictA.meta.strictMode).toBe(true);
  expect(strictB.meta.strictMode).toBe(true);
  expect(relaxedA.meta.strictMode).toBe(false);
  expect(relaxedB.meta.strictMode).toBe(false);

  // Proof the bypass actually fired (not vacuous): the double-invoke is gone, so
  // noStrict aggregate render time is well below StrictMode's. A bypass that did
  // nothing would leave these ~equal and fail this margin (observed ratio ~1.2).
  const strictAvg = (strictA.total + strictB.total) / 2;
  const relaxedAvg = (relaxedA.total + relaxedB.total) / 2;
  expect(strictAvg).toBeGreaterThan(relaxedAvg * 1.1);
});
