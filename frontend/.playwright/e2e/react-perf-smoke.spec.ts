import {expect, test} from '@playwright/test';
import type {Page} from '@playwright/test';
import {existsSync, readFileSync} from 'node:fs';
import path from 'node:path';
import {collectRenderDump, installRenderCapture} from '../react-perf/capture';
import type {RawDump} from '../react-perf/types';
import {hydration} from '../utils';

// Version-bump canary: a stable, named app component reliably rendered by the
// micro-interaction. GAIA ships no memo-wrapped component, so the expected memo
// flag is false; a bippy/React bump that breaks tag or name resolution flips
// this and fails loud.
const CANARY = 'ThemeSwitch';

// Walks up to the directory holding .gaia/VERSION, so the root does not depend
// on how deep the frontend package sits; resolved here rather than imported from
// capture.ts so the assertion stays an oracle independent of its REPO_ROOT.
const findRepoRoot = (startDirectory: string): string => {
  let directory = startDirectory;

  while (!existsSync(path.join(directory, '.gaia', 'VERSION'))) {
    const parent = path.dirname(directory);

    if (parent === directory) {
      throw new Error(`no .gaia/VERSION above ${startDirectory}`);
    }
    directory = parent;
  }

  return directory;
};

const repoRoot = findRepoRoot(import.meta.dirname);

const readDump = (rawPath: string): RawDump =>
  JSON.parse(readFileSync(rawPath, 'utf8')) as RawDump;

// Every mode bit set on any captured fiber in one page load. A fiber inherits
// its parent's mode, so <StrictMode> contributes its bits to the whole app
// subtree and this OR carries them whenever the wrapper is mounted at all.
const collectObservedModeBits = (dump: RawDump): number =>
  // eslint-disable-next-line no-bitwise -- fiber.mode is a bitmask; OR is the only way to union two of them
  dump.all.reduce((bits, record) => bits | record.mode, 0);

// Drive the canary micro-interaction: click the ThemeSwitch inlined on the
// minimal index page. It is the sole button on that page and is located by
// role + accessible name. It is a submit button that flips the optimistic
// theme mode (a local subtree re-render), NOT a navigation, so ThemeSwitch
// re-renders on `update`.
const driveThemeToggle = async (page: Page): Promise<void> => {
  const toggle = page.getByRole('button', {
    name: /enable (dark|light) mode|use system theme/i,
  });
  await expect(toggle).toBeVisible();
  const previousAriaLabel = await toggle.getAttribute('aria-label');
  await toggle.click();
  // Wait for the optimistic update render to commit (label reflects next mode).
  await expect(toggle).not.toHaveAttribute(
    'aria-label',
    previousAriaLabel ?? ''
  );
};

test('captures bippy renders: active, canary resolves name + memo + timing', async ({
  page,
}) => {
  await installRenderCapture(page);
  await page.goto('/');
  await hydration(page);
  await driveThemeToggle(page);

  const renderCapture = await collectRenderDump(page);

  // Writes renders.json under the repo-root .gaia/local/cache/<run>/, the
  // gitignored one; a cache under frontend/ is not ignored.
  expect(path.relative(repoRoot, renderCapture.rawPath)).toMatch(
    /^\.gaia\/local\/cache\/[^/]+\/renders\.json$/
  );
  expect(renderCapture.recordCount).toBeGreaterThan(0);

  // Went active, commits observed, no swallowed errors.
  expect(renderCapture.meta.installed).toBe(true);
  expect(renderCapture.meta.commits).toBeGreaterThan(0);
  expect(renderCapture.meta.errors).toEqual([]);

  // Profiling available, self-describing meta.
  expect(renderCapture.meta.profilingAvailable).toBe(true);
  expect(renderCapture.meta.rendererVersion).toBeTruthy();
  expect(renderCapture.meta.bippyVersion).toMatch(/^\d+\.\d+\.\d+/);

  // A default (StrictMode-on) run is flagged so the reduce CLI caveats timings.
  expect(renderCapture.meta.strictMode).toBe(true);

  const dump = readDump(renderCapture.rawPath);
  expect(dump.total).toBe(renderCapture.recordCount);

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

  // The three change arrays are filled by the traverseProps / traverseState /
  // traverseContexts ports the harness carries locally (bippy dropped them in
  // 0.7.0), and every assertion above reads them from inside a loop, so a port
  // that silently yields nothing satisfies all of them vacuously and the
  // diagnostic reports no changed inputs at all. Assert per array, so one dead
  // visitor cannot hide behind the other two, and over the whole dump rather
  // than the canary slice: the visitors are global, so any record exercising
  // one proves that port lives, while the canary's own propsChanged slice is a
  // single entry and would make this the flakiest line in the file.
  expect(dump.all.some((record) => record.propsChanged.length > 0)).toBe(true);
  expect(dump.all.some((record) => record.stateChanged.length > 0)).toBe(true);
  expect(dump.all.some((record) => record.contextChanged.length > 0)).toBe(
    true
  );

  // The other two ports, on the same terms. getTimings feeds record.selfTime,
  // which the reduce CLI accumulates into the summary /gaia-react-perf reports,
  // so a dead or inverted child-subtraction ships wrong attribution rather than
  // an error. Liveness needs both halves: some record where the subtraction
  // actually ran (selfTime strictly under totalTime, ~145 of ~185 records), and
  // a bound no inverted subtraction can satisfy. didFiberCommit is asserted for
  // a true value, since the typeof check above is boolean-by-construction and
  // stays green whatever COMMIT_MASK resolves to.
  expect(dump.all.some((record) => record.selfTime > 0)).toBe(true);
  expect(dump.all.some((record) => record.selfTime < record.totalTime)).toBe(
    true
  );
  expect(
    dump.all.every(
      (record) => record.selfTime >= 0 && record.selfTime <= record.totalTime
    )
  ).toBe(true);
  expect(dump.all.some((record) => record.didCommit)).toBe(true);

  // Name resolution is asserted over the whole dump, not the canary slice: a
  // slice selected BY componentName can never contain 'Unknown', so asking it
  // that question answers itself. Only composite fibers are recorded, so an
  // 'Unknown' here is a real getDisplayName failure rather than a host node.
  expect(dump.all.every((record) => record.componentName !== 'Unknown')).toBe(
    true
  );

  const canaryRecords = dump.all.filter(
    (record) => record.componentName === CANARY
  );
  expect(canaryRecords.length).toBeGreaterThan(0);
  expect(canaryRecords.every((record) => !record.isMemo)).toBe(true);
  expect(canaryRecords.some((record) => record.totalTime > 0)).toBe(true);
  expect(canaryRecords.some((record) => record.phase === 'update')).toBe(true);
});

test('noStrict bypass disables StrictMode (the StrictMode fiber-mode bits clear)', async ({
  baseURL,
  browser,
}) => {
  const loadPageWithCapture = async (isStrictModeDisabled: boolean) => {
    const context = await browser.newContext({baseURL});
    const page = await context.newPage();
    await installRenderCapture(page, {isStrictModeDisabled});
    await page.goto('/');
    await hydration(page);
    const renderCapture = await collectRenderDump(page);
    const dump = readDump(renderCapture.rawPath);
    await context.close();

    return {meta: renderCapture.meta, modeBits: collectObservedModeBits(dump)};
  };

  const strictModeRun = await loadPageWithCapture(false);
  const strictModeDisabledRun = await loadPageWithCapture(true);

  // meta.strictMode reflects the bypass (the reduce CLI keys its caveat on it).
  expect(strictModeRun.meta.strictMode).toBe(true);
  expect(strictModeDisabledRun.meta.strictMode).toBe(false);

  // Proof the bypass actually fired (not vacuous). The double-invoke inflates
  // StrictMode-on render time, but a wall-clock ratio between two live browser
  // loads is not an oracle this environment can resolve: the effect is ~20% of
  // a sum of sub-millisecond actualDuration values, against a noise floor
  // nothing bounds, so it fails on a loaded machine with the bypass working.
  //
  // The mode bitmask states the same property structurally. React ORs the
  // StrictMode bits into every fiber beneath the wrapper, so removing the
  // wrapper removes them from the whole tree: strict's bits are a STRICT
  // superset of relaxed's. Both halves carry weight. The subset half fails if
  // the bypass changed something other than StrictMode; the inequality fails if
  // it changed nothing at all, which is the vacuous pass the timing assertion
  // was there to catch, and it also fails when both dumps are empty. No literal
  // bit value appears here, so a React renumbering cannot silently invert it.
  /* eslint-disable no-bitwise -- fiber.mode is a bitmask; masking is the only way to test containment */
  expect(strictModeRun.modeBits & strictModeDisabledRun.modeBits).toBe(
    strictModeDisabledRun.modeBits
  );
  /* eslint-enable no-bitwise */
  expect(strictModeRun.modeBits).not.toBe(strictModeDisabledRun.modeBits);
});
