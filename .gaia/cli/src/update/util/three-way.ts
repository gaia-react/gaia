/**
 * Three-way file compare helpers for `gaia update merge`.
 *
 * Compares (current, baseline, latest) for a single repo-relative path.
 * The decision logic itself lives in the `merge.ts` handler — this
 * module just exposes deterministic byte-equality and merge primitives.
 *
 * The clean-merge primitive shells out to `git merge-file --stdout`,
 * which is identical to the strategy git uses internally for
 * `git merge` on individual files. When `git merge-file` succeeds with
 * exit code 0, the merged bytes are written; conflict markers from a
 * non-zero exit are reported as `clean: false` and the caller falls
 * back to emitting a unified diff patch under `.gaia-merge/`.
 */
import {spawnSync} from 'node:child_process';
import {
  existsSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';

export type FileSnapshot = {
  /** Absolute path in the working tree / baseline / latest. May not exist. */
  absPath: string;
  exists: boolean;
  /** Raw bytes when present. `null` when missing. */
  bytes: Buffer | null;
};

export const snapshot = (absPath: string): FileSnapshot => {
  if (!existsSync(absPath)) {
    return {absPath, bytes: null, exists: false};
  }

  let bytes: Buffer;

  try {
    bytes = readFileSync(absPath);
  } catch {
    return {absPath, bytes: null, exists: false};
  }

  return {absPath, bytes, exists: true};
};

export const bytesEqual = (a: Buffer | null, b: Buffer | null): boolean => {
  if (a === null && b === null) return true;
  if (a === null || b === null) return false;
  if (a.length !== b.length) return false;

  return a.equals(b);
};

export type CleanMergeSuccess = {
  ok: true;
  merged: Buffer;
};

export type CleanMergeFailure = {
  ok: false;
  /** Conflicted output containing `<<<<<<<` markers. May be empty on hard error. */
  conflicted: Buffer;
  reason: 'conflict' | 'error';
};

export type CleanMergeResult = CleanMergeFailure | CleanMergeSuccess;

/**
 * Three-way merge using `git merge-file --stdout`.
 *
 * `current` and `latest` are merged against the common ancestor `baseline`.
 * Non-zero exit < 0 means git itself errored; non-zero >= 1 means
 * conflict markers are present in stdout.
 */
export const cleanMerge = (
  current: Buffer,
  baseline: Buffer,
  latest: Buffer
): CleanMergeResult => {
  const dir = mkdtempSync(path.join(tmpdir(), 'gaia-merge-'));
  const currentPath = path.join(dir, 'current');
  const baselinePath = path.join(dir, 'baseline');
  const latestPath = path.join(dir, 'latest');

  try {
    writeFileSync(currentPath, current);
    writeFileSync(baselinePath, baseline);
    writeFileSync(latestPath, latest);

    const result = spawnSync(
      'git',
      ['merge-file', '--stdout', currentPath, baselinePath, latestPath],
      {encoding: 'buffer'}
    );

    if (result.error !== undefined) {
      return {
        conflicted: Buffer.alloc(0),
        ok: false,
        reason: 'error',
      };
    }

    const status = result.status ?? -1;
    const stdout = result.stdout ?? Buffer.alloc(0);

    if (status === 0) {
      return {merged: stdout, ok: true};
    }

    if (status > 0) {
      // Conflict markers in stdout.
      return {conflicted: stdout, ok: false, reason: 'conflict'};
    }

    return {conflicted: stdout, ok: false, reason: 'error'};
  } finally {
    try {
      rmSync(dir, {force: true, recursive: true});
    } catch {
      // best-effort cleanup
    }
  }
};

/**
 * Build a unified diff (unified=3) showing the change from `from` to `to`.
 * Output is a `git apply --check`-acceptable patch using `a/<label>` and
 * `b/<label>` headers. Returns an empty string when both sides are equal.
 */
export type UnifiedDiffOptions = {
  fromLabel: string;
  toLabel: string;
};

export const unifiedDiff = (
  from: Buffer | null,
  to: Buffer | null,
  options: UnifiedDiffOptions
): string => {
  const fromText = from === null ? '' : from.toString('utf8');
  const toText = to === null ? '' : to.toString('utf8');

  if (fromText === toText) return '';

  return buildUnifiedDiff(fromText, toText, options);
};

type LineToken = {
  text: string;
  /** True if the source line ended with `\n`. */
  newline: boolean;
};

const tokenize = (text: string): LineToken[] => {
  if (text === '') return [];

  const out: LineToken[] = [];
  let start = 0;

  while (start <= text.length) {
    const next = text.indexOf('\n', start);

    if (next === -1) {
      // Trailing chunk without a newline.
      if (start < text.length) {
        out.push({newline: false, text: text.slice(start)});
      }
      break;
    }

    out.push({newline: true, text: text.slice(start, next)});
    start = next + 1;

    if (start === text.length) break;
  }

  return out;
};

type DiffKind = 'equal' | 'delete' | 'insert';

type DiffOp = {
  kind: DiffKind;
  token: LineToken;
};

const diffTokens = (a: LineToken[], b: LineToken[]): DiffOp[] => {
  const n = a.length;
  const m = b.length;
  const lcs: number[][] = Array.from(
    {length: n + 1},
    () => new Array<number>(m + 1).fill(0)
  );

  for (let i = n - 1; i >= 0; i -= 1) {
    for (let j = m - 1; j >= 0; j -= 1) {
      if ((a[i] as LineToken).text === (b[j] as LineToken).text) {
        lcs[i]![j] = (lcs[i + 1]?.[j + 1] ?? 0) + 1;
      } else {
        const down = lcs[i + 1]?.[j] ?? 0;
        const right = lcs[i]?.[j + 1] ?? 0;
        lcs[i]![j] = Math.max(down, right);
      }
    }
  }

  const ops: DiffOp[] = [];
  let i = 0;
  let j = 0;

  while (i < n && j < m) {
    const ai = a[i] as LineToken;
    const bj = b[j] as LineToken;

    if (ai.text === bj.text) {
      ops.push({kind: 'equal', token: ai});
      i += 1;
      j += 1;
      continue;
    }

    const down = lcs[i + 1]?.[j] ?? 0;
    const right = lcs[i]?.[j + 1] ?? 0;

    if (down >= right) {
      ops.push({kind: 'delete', token: ai});
      i += 1;
    } else {
      ops.push({kind: 'insert', token: bj});
      j += 1;
    }
  }

  while (i < n) {
    ops.push({kind: 'delete', token: a[i] as LineToken});
    i += 1;
  }

  while (j < m) {
    ops.push({kind: 'insert', token: b[j] as LineToken});
    j += 1;
  }

  return ops;
};

type AnnotatedOp = DiffOp & {
  oldLine: number;
  newLine: number;
};

const annotate = (ops: readonly DiffOp[]): AnnotatedOp[] => {
  const out: AnnotatedOp[] = [];
  let oldLine = 1;
  let newLine = 1;

  for (const op of ops) {
    out.push({...op, newLine, oldLine});

    if (op.kind === 'equal') {
      oldLine += 1;
      newLine += 1;
    } else if (op.kind === 'delete') {
      oldLine += 1;
    } else {
      newLine += 1;
    }
  }

  return out;
};

const renderToken = (prefix: string, token: LineToken): string[] => {
  if (token.newline) return [`${prefix}${token.text}`];
  // \ No newline at end of file marker.
  return [`${prefix}${token.text}`, '\\ No newline at end of file'];
};

const buildUnifiedDiff = (
  fromText: string,
  toText: string,
  options: UnifiedDiffOptions
): string => {
  const fromTokens = tokenize(fromText);
  const toTokens = tokenize(toText);
  const rawOps = diffTokens(fromTokens, toTokens);
  const ops = annotate(rawOps);
  const context = 3;

  // Group consecutive change-or-near-change ops into hunks.
  type HunkRange = {start: number; end: number};
  const ranges: HunkRange[] = [];

  for (let index = 0; index < ops.length; index += 1) {
    if ((ops[index] as AnnotatedOp).kind === 'equal') continue;

    const last = ranges[ranges.length - 1];

    if (last !== undefined && index - last.end <= context * 2) {
      last.end = index;
    } else {
      ranges.push({end: index, start: index});
    }
  }

  if (ranges.length === 0) return '';

  const lines: string[] = [
    `--- a/${options.fromLabel}`,
    `+++ b/${options.toLabel}`,
  ];

  for (const range of ranges) {
    const startIndex = Math.max(0, range.start - context);
    const endIndex = Math.min(ops.length - 1, range.end + context);
    const slice = ops.slice(startIndex, endIndex + 1);

    let oldStart = 0;
    let newStart = 0;
    let oldCount = 0;
    let newCount = 0;
    const body: string[] = [];

    for (const op of slice) {
      if (op.kind === 'equal') {
        if (oldStart === 0) oldStart = op.oldLine;

        if (newStart === 0) newStart = op.newLine;
        oldCount += 1;
        newCount += 1;
        body.push(...renderToken(' ', op.token));
        continue;
      }

      if (op.kind === 'delete') {
        if (oldStart === 0) oldStart = op.oldLine;
        oldCount += 1;
        body.push(...renderToken('-', op.token));
        continue;
      }

      if (newStart === 0) newStart = op.newLine;
      newCount += 1;
      body.push(...renderToken('+', op.token));
    }

    // When a hunk has zero old or new lines, the start line is
    // canonically reported as 0 in unified diffs. We use 0 explicitly.
    const oldHeader = oldCount === 0 ? 0 : oldStart === 0 ? 1 : oldStart;
    const newHeader = newCount === 0 ? 0 : newStart === 0 ? 1 : newStart;
    lines.push(`@@ -${oldHeader},${oldCount} +${newHeader},${newCount} @@`);
    lines.push(...body);
  }

  return `${lines.join('\n')}\n`;
};
