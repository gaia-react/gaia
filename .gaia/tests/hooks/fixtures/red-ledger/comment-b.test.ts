import {expect, test} from '@playwright/test';

test('captures bippy renders: active, canary resolves name + memo + timing', async ({
  page,
}) => {
  await installRenderCapture(page);
  await page.goto('/');
  await hydration(page);
  await driveThemeToggle(page);

  const result = await collectRenderDump(page);

  // Writes renders.json under .gaia/local/cache/<run>/.
  expect(result.rawPath).toMatch(/\.gaia\/local\/cache\/[^/]+\/renders\.json$/);
  expect(result.recordCount).toBeGreaterThan(0);

  // Went active, commits observed, no swallowed errors.
  expect(result.meta.installed).toBe(true);
  expect(result.meta.commits).toBeGreaterThan(0);
  expect(result.meta.errors).toEqual([]);

  // Profiling available, self-describing meta.
  expect(result.meta.profilingAvailable).toBe(true);
  expect(result.meta.rendererVersion).toBeTruthy();
  expect(result.meta.bippyVersion).toMatch(/^\d+\.\d+\.\d+/);

  // A default (StrictMode-on) run is flagged so Phase 2 caveats timings.
  expect(result.meta.strictMode).toBe(true);

  const dump = readDump(result.rawPath);
  expect(dump.total).toBe(result.recordCount);

  // Every emitted record is a real render; didCommit is a boolean.
  for (const record of dump.all) {
    expect(record.didRender).toBe(true);
    expect(typeof record.didCommit).toBe('boolean');
  }

  // Records carry phase + a numeric fiberId; update records exist.
  const updates = dump.all.filter((record) => record.phase === 'update');
  expect(updates.length).toBeGreaterThan(0);

  for (const record of dump.all) {
    expect(typeof record.phase).toBe('string');
    expect(Number.isFinite(record.fiberId)).toBe(true);
  }

  // Change entries serialize to short type labels, never raw values.
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

  // The canary resolves a real name, the expected memo flag, and a non-zero
  // subtree timing; the toggle drives it on an update render.
  const canaryRecords = dump.all.filter(
    (record) => record.componentName === CANARY
  );
  expect(canaryRecords.length).toBeGreaterThan(0);
  expect(
    canaryRecords.every((record) => record.componentName !== 'Unknown')
  ).toBe(true);
  expect(canaryRecords.every((record) => !record.isMemo)).toBe(true);
  expect(canaryRecords.some((record) => record.totalTime > 0)).toBe(true);
  expect(canaryRecords.some((record) => record.phase === 'update')).toBe(true);
});
