// Contract D — the committed Playwright capture helper. installRenderCapture
// bundles the bippy harness to an IIFE and addInitScript's it before React runs;
// collectRenderDump reads window.__renders / window.__bippyMeta and writes the
// RawDump to .gaia/local/cache/<run>/renders.json (gitignored, auto-deleted on
// process exit unless kept). The raw dump must never enter the model context;
// the reduce CLI (Phase 2) produces the small summary the skill reads.

/* eslint-disable no-underscore-dangle -- window.__renders / __bippyMeta /
   __PERF_NO_STRICT are the harness wire contract; the names are fixed by
   harness-entry.ts and app/entry.client.tsx, not chosen here. */
import type {Page} from '@playwright/test';
import {build} from 'esbuild';
import {nanoid} from 'nanoid';
import {mkdirSync, rmSync, writeFileSync} from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import type {BippyMeta, RawDump, RawDumpMeta, RenderRecord} from './types';

const CURRENT_MODULE_DIR = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(CURRENT_MODULE_DIR, '..', '..');
const CACHE_ROOT = path.join(REPO_ROOT, '.gaia', 'local', 'cache');
const HARNESS_ENTRY = path.join(CURRENT_MODULE_DIR, 'harness-entry.ts');

export type CaptureResult = {
  meta: RawDump['meta'];
  rawPath: string; // absolute path to the written renders.json
  recordCount: number;
};

// Bundle the bippy harness to a browser IIFE once per process (bippy stays
// version-pinned in package.json; no generated bundle is committed).
let harnessIifePromise: Promise<string> | undefined;

const buildHarnessIife = async (): Promise<string> => {
  harnessIifePromise ??= build({
    bundle: true,
    entryPoints: [HARNESS_ENTRY],
    format: 'iife',
    legalComments: 'none',
    platform: 'browser',
    target: 'es2022',
    write: false,
  }).then((result) => {
    const output = result.outputFiles.at(0);

    if (!output) {
      throw new Error('react-perf: esbuild produced no output for the harness');
    }

    return output.text;
  });

  return harnessIifePromise;
};

// Per-page capture options, set at install and read at collect so collect can
// stamp meta.strictMode without re-reading page state.
const captureOptions = new WeakMap<Page, {isStrictModeDisabled: boolean}>();

// Run dirs to remove on process exit (auto-delete unless the caller keeps them).
const pendingCleanup = new Set<string>();
let cleanupHooked = false;

const scheduleCleanup = (directory: string): void => {
  pendingCleanup.add(directory);
  if (cleanupHooked) return;
  cleanupHooked = true;
  process.on('exit', () => {
    for (const pending of pendingCleanup) {
      try {
        rmSync(pending, {force: true, recursive: true});
      } catch {
        // best-effort cleanup on exit
      }
    }
  });
};

export const installRenderCapture = async (
  page: Page,
  options: {isStrictModeDisabled?: boolean} = {}
): Promise<void> => {
  const isStrictModeDisabled = options.isStrictModeDisabled ?? false;
  captureOptions.set(page, {isStrictModeDisabled});

  if (isStrictModeDisabled) {
    // Set before React hydrates so app/entry.client.tsx skips <StrictMode> and
    // timings are honest (not doubled). Default (undefined) keeps StrictMode on.
    await page.addInitScript(() => {
      window.__PERF_NO_STRICT = true;
    });
  }

  const iife = await buildHarnessIife();
  await page.addInitScript({content: iife});
};

export const collectRenderDump = async (
  page: Page,
  options: {keep?: boolean; runId?: string} = {}
): Promise<CaptureResult> => {
  const runId = options.runId ?? `${Date.now()}-${nanoid()}`;
  const keep = options.keep ?? false;

  // Mirror react-scan's ~5s "failed to load" active check: the harness must have
  // gone active, else injection lost the race with React (or the target is a
  // production build, which disarms bippy).
  await page
    .waitForFunction(() => window.__bippyMeta?.installed === true, undefined, {
      timeout: 5000,
    })
    .catch(() => {
      throw new Error(
        'react-perf: bippy instrumentation never went active within 5s. The harness must be injected before React runs (addInitScript at document_start), and the target must be a development build.'
      );
    });

  const browser = await page.evaluate(() => ({
    meta: window.__bippyMeta ?? null,
    renders: window.__renders ?? [],
  }));

  if (!browser.meta) {
    throw new Error(
      'react-perf: window.__bippyMeta missing after active check'
    );
  }

  if (browser.meta.productionDetected) {
    throw new Error(
      'react-perf: production React build detected; aborting (actualDuration is 0 in production, so timings would be meaningless). Point the capture at the dev server.'
    );
  }

  const browserMeta: BippyMeta = browser.meta;
  const renders: RenderRecord[] = browser.renders;
  const isStrictModeDisabled =
    captureOptions.get(page)?.isStrictModeDisabled ?? false;

  const meta: RawDumpMeta = {
    bippyVersion: browserMeta.bippyVersion,
    commits: browserMeta.commits,
    errors: browserMeta.errors,
    installed: browserMeta.installed,
    profilingAvailable: browserMeta.profilingAvailable,
    rendererVersion: browserMeta.rendererVersion,
    strictMode: !isStrictModeDisabled,
  };

  const dump: RawDump = {all: renders, meta, total: renders.length};

  const runDirectory = path.join(CACHE_ROOT, runId);
  mkdirSync(runDirectory, {recursive: true});
  const rawPath = path.join(runDirectory, 'renders.json');
  writeFileSync(rawPath, JSON.stringify(dump, null, 2));

  if (!keep) scheduleCleanup(runDirectory);

  return {meta, rawPath, recordCount: dump.total};
};
