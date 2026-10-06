/**
 * Filesystem primitives shared by the scaffolder family.
 *
 * `writeFileIfAbsent` is the contract that protects user customizations:
 * the scaffolder will create new files but refuses to clobber an existing
 * file whose contents differ. Identical content is silently treated as a
 * no-op so re-running a scaffolder is idempotent.
 */
import {existsSync, mkdirSync, readFileSync} from 'node:fs';
import path from 'node:path';
import {atomicWriteFileSync} from '../util/atomic-write.js';
import type {ScaffoldResult} from './types.js';

/**
 * Create the directory at `absPath` (recursive). No-op when it already
 * exists. Mirrors `mkdir -p` semantics.
 */
export const ensureDir = (absPath: string): void => {
  mkdirSync(absPath, {recursive: true});
};

type WriteResult = {written: boolean};

/**
 * Write `contents` to `absPath` only if no file is already there.
 *
 * - File absent → write, return `{written: true}`.
 * - File present and byte-identical → return `{written: false}`.
 * - File present and different → throw `Error("refusing to overwrite ...")`.
 *
 * Always ensures the parent directory exists before writing.
 *
 * Pass `{dryRun: true}` to compute the same result (and surface the same
 * overwrite conflict) without touching the filesystem.
 */
export const writeFileIfAbsent = (
  absPath: string,
  contents: string,
  options: {dryRun?: boolean} = {}
): WriteResult => {
  if (existsSync(absPath)) {
    const existing = readFileSync(absPath, 'utf8');

    if (existing === contents) return {written: false};

    throw new Error(`refusing to overwrite ${absPath}`);
  }

  if (options.dryRun !== true) {
    ensureDir(path.dirname(absPath));
    atomicWriteFileSync(absPath, contents);
  }

  return {written: true};
};

type WriteAndRecordArgs = {
  absPath: string;
  contents: string;
  dryRun?: boolean;
  result: ScaffoldResult;
};

/** `writeFileIfAbsent`, recording the path under `result.written` or `result.skipped`. */
export const writeAndRecordWith = (args: WriteAndRecordArgs): void => {
  const {absPath, contents, dryRun, result} = args;
  const {written} = writeFileIfAbsent(absPath, contents, {dryRun});

  if (written) {
    result.written.push(absPath);
  } else {
    result.skipped.push(absPath);
  }
};

/** `writeAndRecordWith` for a scaffold with no dry run. */
export const writeAndRecord = (
  absPath: string,
  contents: string,
  result: ScaffoldResult
): void => {
  writeAndRecordWith({absPath, contents, result});
};
