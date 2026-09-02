/**
 * Maintainer drift-guard for the ignore scope of the root `format` script.
 *
 * `pnpm format` runs Prettier with `--write` over a glob anchored at the
 * repository root. Prettier 3 defaults `--ignore-path` to
 * `['.gitignore', '.prettierignore']`, and passing the flag REPLACES that
 * array rather than adding to it. A `format` script that names
 * `.prettierignore` alone therefore stops consulting `.gitignore`, and the
 * root-anchored glob then descends into every path `.gitignore` covers:
 * `.claude/worktrees/` above all, but also `.gaia/local/` (a symlink to the
 * main checkout's copy from inside a provisioned worktree), `coverage/`, and
 * `build/`.
 *
 * The failure that earned this guard is cross-tree contamination, not wasted
 * work. A `--write` into `.claude/worktrees/<name>/` rewrites files inside
 * another session's isolated, in-flight worktree; the write lands with no
 * error and no indication which tree it touched. That is the separation
 * `block-worktree-path-mismatch.sh` and the `.gaia/local` tree-key model
 * exist to hold, and this path walks around both because it never goes
 * through a tool call they guard. Measured on a checkout with two live
 * worktrees: 764 files listed different, 274 of them inside worktrees and 273
 * inside `.gaia/local` (#1722).
 *
 * # What is held, and why it takes two assertions
 *
 * The claim is "`pnpm format` does not descend into a live worktree", and it
 * rests on two independent facts that no single file states together.
 *
 * The first is that the `format` script does not narrow Prettier's ignore set
 * below its default. Either it passes no `--ignore-path` at all, which is what
 * the repair landed, or it passes one that still names `.gitignore`, which is
 * the equivalent explicit spelling. Anything else re-opens the hole.
 *
 * The second is that `.gitignore` actually ignores `.claude/worktrees`. The
 * first assertion leans on it entirely: consulting `.gitignore` protects
 * nothing if `.gitignore` stops covering the worktree root. Dropping that
 * entry would also make worktrees stageable, which is louder, but "louder"
 * is not "reported", and the two edits are made by different people for
 * different reasons.
 *
 * Fires on the pull request that causes the drift: `package.json` and
 * `.gitignore` are both in the `code` paths filter of `cli-tests.yml`, whose
 * `Vitest (.gaia/cli)` job is a declared-required context.
 *
 * Maintainer-only by construction: `.gaia/cli/src` is release-excluded, so an
 * adopter clone carries this test's subjects but not the test. Mirrors
 * `node-pin-parity.test.ts`.
 */
import {describe, expect, test} from 'vitest';
import {readFileSync} from 'node:fs';
import path from 'node:path';
import {resolveRepoRootFromImportMeta} from './util/repo-root-fixture.js';

const REPO_ROOT = resolveRepoRootFromImportMeta(import.meta.url);

// Every `--ignore-path` occurrence in a script string, in the four spellings a
// shell accepts: space- or `=`-separated, and the value bare, double-quoted, or
// single-quoted. A package.json script is JSON, so an embedded double quote
// arrives escaped (`\"`); the pattern runs against the parsed string, where the
// escape is already gone.
const IGNORE_PATH_PATTERN =
  /--ignore-path(?:=|\s+)(?:"([^"]*)"|'([^']*)'|(\S+))/g;

// The gitignore entry the first assertion leans on. Matched with an optional
// trailing slash and nothing after it, because both forms ignore the directory
// and the repo may legitimately carry either; a longer path under it
// (`.claude/worktrees/foo`) would not cover the directory as a whole.
const WORKTREE_IGNORE_PATTERN = /^\.claude\/worktrees\/?$/;

const readPackageScripts = (): Record<string, string> => {
  const raw = readFileSync(path.join(REPO_ROOT, 'package.json'), 'utf8');
  const parsed: unknown = JSON.parse(raw);

  if (
    typeof parsed !== 'object' ||
    parsed === null ||
    !('scripts' in parsed) ||
    typeof parsed.scripts !== 'object' ||
    parsed.scripts === null
  ) {
    throw new Error('package.json declares no scripts object');
  }

  return parsed.scripts as Record<string, string>;
};

const ignorePathsIn = (script: string): string[] =>
  [...script.matchAll(IGNORE_PATH_PATTERN)].map(
    ([, doubleQuoted, singleQuoted, bare]) =>
      doubleQuoted ?? singleQuoted ?? bare ?? ''
  );

// The paths a script narrows prettier's ignore set to, or `null` when it
// narrows nothing. Two shapes narrow nothing: no `--ignore-path` at all, which
// leaves prettier on its `['.gitignore', '.prettierignore']` default, and an
// explicit set that still names `.gitignore`. Returning the offending paths
// rather than a boolean is what puts them in the failure message.
const narrowedIgnorePathsIn = (script: string): null | string[] => {
  const ignorePaths = ignorePathsIn(script);

  if (ignorePaths.length === 0) return null;

  return ignorePaths.includes('.gitignore') ? null : ignorePaths;
};

describe('root format script ignore scope', () => {
  test('the format script exists and runs prettier', () => {
    const scripts = readPackageScripts();

    expect(scripts.format).toBeDefined();
    expect(scripts.format).toContain('prettier');
  });

  test('does not narrow prettier below its default ignore set', () => {
    const {format} = readPackageScripts();

    expect(narrowedIgnorePathsIn(format)).toBeNull();
  });

  test('gitignore still covers the worktree root the guard leans on', () => {
    const gitignore = readFileSync(path.join(REPO_ROOT, '.gitignore'), 'utf8');
    const entries = gitignore
      .split('\n')
      .map((line) => line.trim())
      .filter((line) => line.length > 0 && !line.startsWith('#'));

    expect(entries.some((entry) => WORKTREE_IGNORE_PATTERN.test(entry))).toBe(
      true
    );
  });
});
