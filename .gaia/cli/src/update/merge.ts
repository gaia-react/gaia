/**
 * `gaia update merge --baseline <dir> --latest <dir> --manifest <path>` handler.
 *
 * Deterministic file walk for `/update-gaia`: emits JSON describing
 * per-path actions (overwrite/skip/merge/add/delete/conflict). The
 * `/update-gaia` skill invokes this command, parses JSON, and only
 * surfaces conflicts and deletions to the user; no byte reading per
 * manifest entry from the skill side.
 *
 * Decision table:
 *
 *   For every path P in the latest manifest:
 *     - upstream class: overwrite when latest != current
 *     - owned class:    overwrite when current == baseline (adopter undrifted);
 *                       skip when upstream unchanged or already at latest;
 *                       emit patch to .gaia-merge/ (no auto-merge) when
 *                       latest != baseline AND current != baseline.
 *     - shared class:
 *         current == baseline           → take latest    (overwrite[])
 *         latest == baseline            → keep current   (skip[])
 *         current == latest             → skip[]
 *         else clean git merge-file     → write merged   (merge[])
 *         else                          → emit patch     (conflicts[] shared)
 *
 *   Plus paths NOT in manifest:
 *     - present in latest only          → add[]
 *     - present in baseline only        → delete[]   (no removal performed)
 *
 * Side effects: writes overwrites and clean three-way merges directly
 * into the working tree. Patches land under `.gaia-merge/<path>.patch`
 * (creating ancestor dirs). No commits, no deletions.
 *
 * Determinism contract: byte-for-byte equality everywhere. Never
 * normalizes line endings; the GAIA template is LF throughout.
 */
import {
  existsSync,
  mkdirSync,
  readdirSync,
  statSync,
  writeFileSync,
} from 'node:fs';
import path from 'node:path';
import {atomicWriteFileSync} from '../util/atomic-write.js';
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {
  loadManifest,
  type Manifest,
  type NormalizedClass,
} from './util/manifest.js';
import {
  bytesEqual,
  cleanMerge,
  snapshot,
  unifiedDiff,
} from './util/three-way.js';

const HELP_TEXT = `Usage: gaia update merge --baseline <dir> --latest <dir> --manifest <path> [--json]

  Three-way file compare across baseline and latest tarball trees,
  classified by .gaia/manifest.json. Replaces the prose Step 7 of the
  update-gaia skill.

  Outputs a deterministic report. Writes overwrites, clean three-way
  merges, and conflict patches; never commits, never deletes.

  Exit codes:
    0  success (clean run, may include conflicts to resolve)
    1  user-correctable error (missing dir, malformed manifest)
    2  unexpected (filesystem failure)
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);
const UNEXPECTED_EXIT = 2;
const MERGE_DIR = '.gaia-merge';

export type ConflictClass = 'owned' | 'shared' | 'upstream';

export type ConflictReport = {
  class: ConflictClass;
  path: string;
  patch_path: string;
};

export type UpdateMergeReport = {
  overwrite: string[];
  skip: string[];
  merge: string[];
  add: string[];
  delete: string[];
  conflicts: ConflictReport[];
};

type Flags = {
  baseline: string;
  latest: string;
  manifest: string;
  json: boolean;
};

type ParsedFlagsSuccess = {
  flags: Flags;
  ok: true;
};

type ParsedFlagsFailure = {
  message: string;
  ok: false;
};

type ParsedFlagsResult = ParsedFlagsFailure | ParsedFlagsSuccess;

const takeValue = (
  argv: readonly string[],
  index: number,
  flag: string
): {message: string; ok: false} | {ok: true; value: string} => {
  const value = argv[index];

  if (value === undefined)
    return {message: `${flag} requires a value`, ok: false};

  return {ok: true, value};
};

const parseFlags = (argv: readonly string[]): ParsedFlagsResult => {
  let baseline: string | undefined;
  let latest: string | undefined;
  let manifest: string | undefined;
  let json = false;

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index] as string;

    if (token === '--baseline') {
      const taken = takeValue(argv, index + 1, '--baseline');

      if (!taken.ok) return taken;
      baseline = taken.value;
      index += 1;
      continue;
    }

    if (token === '--latest') {
      const taken = takeValue(argv, index + 1, '--latest');

      if (!taken.ok) return taken;
      latest = taken.value;
      index += 1;
      continue;
    }

    if (token === '--manifest') {
      const taken = takeValue(argv, index + 1, '--manifest');

      if (!taken.ok) return taken;
      manifest = taken.value;
      index += 1;
      continue;
    }

    if (token === '--json') {
      json = true;
      continue;
    }

    return {message: `unknown flag: ${token}`, ok: false};
  }

  if (baseline === undefined)
    return {message: '--baseline is required', ok: false};

  if (latest === undefined) return {message: '--latest is required', ok: false};

  if (manifest === undefined)
    return {message: '--manifest is required', ok: false};

  return {flags: {baseline, json, latest, manifest}, ok: true};
};

const walkRelative = (rootDir: string): string[] => {
  const out: string[] = [];

  const visit = (relative: string): void => {
    const absolute = path.join(rootDir, relative);

    let names: string[];

    try {
      names = readdirSync(absolute);
    } catch {
      return;
    }

    for (const name of names) {
      const child = relative === '' ? name : path.join(relative, name);
      const childAbs = path.join(rootDir, child);

      let info: ReturnType<typeof statSync>;

      try {
        info = statSync(childAbs);
      } catch {
        continue;
      }

      if (info.isDirectory()) {
        visit(child);
        continue;
      }

      if (info.isFile()) out.push(child);
    }
  };

  if (!existsSync(rootDir) || !statSync(rootDir).isDirectory()) return out;
  visit('');

  return out.sort();
};

type Context = {
  cwd: string;
  baselineDir: string;
  latestDir: string;
  manifest: Manifest;
};

const ensureDir = (absDir: string): void => {
  mkdirSync(absDir, {recursive: true});
};

const writePatch = (
  ctx: Context,
  relativePath: string,
  patch: string
): string => {
  const mergeRoot = path.join(ctx.cwd, MERGE_DIR);
  const patchAbs = path.join(mergeRoot, `${relativePath}.patch`);
  ensureDir(path.dirname(patchAbs));
  // Patch files are regenerated scratch output under .gaia-merge/, not
  // durable state; a plain write is sufficient; no atomic rename needed.
  writeFileSync(patchAbs, patch, 'utf8');

  return path.relative(ctx.cwd, patchAbs);
};

const writeWorkingTree = (
  ctx: Context,
  relativePath: string,
  bytes: Buffer
): void => {
  const target = path.join(ctx.cwd, relativePath);
  ensureDir(path.dirname(target));
  atomicWriteFileSync(target, bytes);
};

type Decision =
  | {kind: 'add'}
  | {kind: 'overwrite'}
  | {kind: 'skip'}
  | {kind: 'merge'; bytes: Buffer}
  | {kind: 'conflict'; class: ConflictClass; patch: string};

const handleManifestPath = (
  ctx: Context,
  relativePath: string,
  klass: NormalizedClass
): Decision | null => {
  const baselineSnap = snapshot(path.join(ctx.baselineDir, relativePath));
  const latestSnap = snapshot(path.join(ctx.latestDir, relativePath));
  const currentSnap = snapshot(path.join(ctx.cwd, relativePath));

  // Path absent from latest is handled in the deletion sweep, not here.
  if (!latestSnap.exists) return null;

  // Adopter doesn't have this file yet.
  if (!currentSnap.exists) {
    if (!baselineSnap.exists) {
      // New file; copy latest into the working tree.
      writeWorkingTree(ctx, relativePath, latestSnap.bytes);

      return {kind: 'add'};
    }

    // Adopter deleted this file deliberately. Respect.
    return {kind: 'skip'};
  }

  // No drift; overwrite with latest (regardless of class).
  if (bytesEqual(currentSnap.bytes, baselineSnap.bytes)) {
    if (bytesEqual(currentSnap.bytes, latestSnap.bytes)) {
      return {kind: 'skip'};
    }
    writeWorkingTree(ctx, relativePath, latestSnap.bytes);

    return {kind: 'overwrite'};
  }

  // Adopter drifted; upstream unchanged → keep adopter.
  if (bytesEqual(latestSnap.bytes, baselineSnap.bytes)) {
    return {kind: 'skip'};
  }

  // Both drifted in the same direction → already aligned.
  if (bytesEqual(currentSnap.bytes, latestSnap.bytes)) {
    return {kind: 'skip'};
  }

  if (klass === 'owned') {
    const patch = unifiedDiff(currentSnap.bytes, latestSnap.bytes, {
      fromLabel: relativePath,
      toLabel: relativePath,
    });
    const patchPath = writePatch(ctx, relativePath, patch);

    return {class: 'owned', kind: 'conflict', patch: patchPath};
  }

  if (klass === 'shared') {
    if (baselineSnap.bytes === null) {
      // No baseline to three-way merge against (the file is new since the
      // adopter's baseline); fall back to a conflict patch.
      const patch = unifiedDiff(currentSnap.bytes, latestSnap.bytes, {
        fromLabel: relativePath,
        toLabel: relativePath,
      });
      const patchPath = writePatch(ctx, relativePath, patch);

      return {class: 'shared', kind: 'conflict', patch: patchPath};
    }

    const merged = cleanMerge(
      currentSnap.bytes,
      baselineSnap.bytes,
      latestSnap.bytes
    );

    if (merged.ok) {
      return {bytes: merged.merged, kind: 'merge'};
    }

    const patch = unifiedDiff(currentSnap.bytes, latestSnap.bytes, {
      fromLabel: relativePath,
      toLabel: relativePath,
    });
    const patchPath = writePatch(ctx, relativePath, patch);

    return {class: 'shared', kind: 'conflict', patch: patchPath};
  }

  // `upstream` class; collapse to overwrite-on-difference.
  writeWorkingTree(ctx, relativePath, latestSnap.bytes);

  return {kind: 'overwrite'};
};

const computeReport = (ctx: Context): UpdateMergeReport => {
  const overwrite: string[] = [];
  const skip: string[] = [];
  const mergeList: string[] = [];
  const add: string[] = [];
  const deleteList: string[] = [];
  const conflicts: ConflictReport[] = [];

  const latestPaths = new Set(walkRelative(ctx.latestDir));
  const baselinePaths = new Set(walkRelative(ctx.baselineDir));
  const manifestPaths = new Set(ctx.manifest.files.keys());

  // 1. Manifest pass.
  for (const relativePath of [...manifestPaths].toSorted()) {
    const entry = ctx.manifest.files.get(relativePath);

    if (entry === undefined) continue;

    if (!latestPaths.has(relativePath)) {
      // Listed in manifest but not in latest tarball; nothing to do
      // here; the deletion sweep below will catch it if baseline has it.
      continue;
    }

    const decision = handleManifestPath(
      ctx,
      relativePath,
      entry.normalizedClass
    );

    if (decision === null) continue;

    if (decision.kind === 'add') {
      add.push(relativePath);
    } else if (decision.kind === 'overwrite') {
      overwrite.push(relativePath);
    } else if (decision.kind === 'skip') {
      skip.push(relativePath);
    } else if (decision.kind === 'merge') {
      writeWorkingTree(ctx, relativePath, decision.bytes);
      mergeList.push(relativePath);
    } else {
      conflicts.push({
        class: decision.class,
        path: relativePath,
        patch_path: decision.patch,
      });
    }
  }

  // 2. New files in latest that the manifest doesn't list: add[].
  for (const relativePath of [...latestPaths].toSorted()) {
    if (manifestPaths.has(relativePath)) continue;

    const currentSnap = snapshot(path.join(ctx.cwd, relativePath));

    if (currentSnap.exists) continue;
    const latestSnap = snapshot(path.join(ctx.latestDir, relativePath));

    if (!latestSnap.exists) continue;
    writeWorkingTree(ctx, relativePath, latestSnap.bytes);
    add.push(relativePath);
  }

  // 3. Files removed upstream: delete[]. Handles both manifest and
  // non-manifest entries: if a file lived in baseline but not latest,
  // surface it for the user to confirm. We do NOT remove the file.
  for (const relativePath of [...baselinePaths].toSorted()) {
    if (latestPaths.has(relativePath)) continue;

    const currentSnap = snapshot(path.join(ctx.cwd, relativePath));

    if (!currentSnap.exists) continue;
    deleteList.push(relativePath);
  }

  return {
    add: add.sort(),
    conflicts: conflicts.sort((a, b) => a.path.localeCompare(b.path)),
    delete: deleteList.sort(),
    merge: mergeList.sort(),
    overwrite: overwrite.sort(),
    skip: skip.sort(),
  };
};

const printHuman = (report: UpdateMergeReport): void => {
  const lines = [
    'gaia update merge',
    `  Overwrite: ${report.overwrite.length}`,
    `  Merge:     ${report.merge.length}`,
    `  Skip:      ${report.skip.length}`,
    `  Add:       ${report.add.length}`,
    `  Delete:    ${report.delete.length}`,
    `  Conflicts: ${report.conflicts.length}`,
  ];

  const sections: Array<[string, readonly string[]]> = [
    ['Overwrite', report.overwrite],
    ['Merge', report.merge],
    ['Skip', report.skip],
    ['Add', report.add],
    ['Delete', report.delete],
  ];

  for (const [label, items] of sections) {
    if (items.length === 0) continue;
    lines.push('', `${label}:`);

    for (const item of items) lines.push(`  ${item}`);
  }

  if (report.conflicts.length > 0) {
    lines.push('', 'Conflicts:');

    for (const conflict of report.conflicts) {
      lines.push(
        `  [${conflict.class}] ${conflict.path} → ${conflict.patch_path}`
      );
    }
  }

  process.stdout.write(`${lines.join('\n')}\n`);
};

type RunOptions = {
  cwd?: string;
};

export const run = (
  argv: readonly string[],
  options: RunOptions = {}
): number => {
  if (argv.length > 0 && HELP_TOKENS.has(argv[0] as string)) {
    process.stdout.write(HELP_TEXT);

    return EXIT_CODES.OK;
  }

  const parsed = parseFlags(argv);

  if (!parsed.ok) {
    structuredError({
      code: 'invalid_arguments',
      message: parsed.message,
      subcommand: 'update merge',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const cwd = options.cwd ?? process.cwd();
  const baselineDir =
    path.isAbsolute(parsed.flags.baseline) ?
      parsed.flags.baseline
    : path.join(cwd, parsed.flags.baseline);
  const latestDir =
    path.isAbsolute(parsed.flags.latest) ?
      parsed.flags.latest
    : path.join(cwd, parsed.flags.latest);
  const manifestPath =
    path.isAbsolute(parsed.flags.manifest) ?
      parsed.flags.manifest
    : path.join(cwd, parsed.flags.manifest);

  if (!existsSync(baselineDir) || !statSync(baselineDir).isDirectory()) {
    structuredError({
      code: 'baseline_missing',
      message: `--baseline directory not found: ${baselineDir}`,
      subcommand: 'update merge',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  if (!existsSync(latestDir) || !statSync(latestDir).isDirectory()) {
    structuredError({
      code: 'latest_missing',
      message: `--latest directory not found: ${latestDir}`,
      subcommand: 'update merge',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const manifestResult = loadManifest(manifestPath);

  if (!manifestResult.ok) {
    structuredError({
      code: 'manifest_invalid',
      message: manifestResult.message,
      subcommand: 'update merge',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  let report: UpdateMergeReport;

  try {
    report = computeReport({
      baselineDir,
      cwd,
      latestDir,
      manifest: manifestResult.manifest,
    });
  } catch (error) {
    structuredError({
      code: 'merge_failed',
      message: error instanceof Error ? error.message : String(error),
      subcommand: 'update merge',
    });

    return UNEXPECTED_EXIT;
  }

  if (parsed.flags.json) {
    process.stdout.write(`${JSON.stringify(report)}\n`);
  } else {
    printHuman(report);
  }

  return EXIT_CODES.OK;
};
