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

// Every `--ignore-path` occurrence in a script string. The separator is a space
// or an `=`, and the value is bare, double-quoted, or single-quoted; the value
// alternation sits after the separator alternation, so every combination of the
// two is read, not only the ones written out here. A package.json script is
// JSON, so an embedded double quote arrives escaped (`\"`); the pattern runs
// against the parsed string, where the escape is already gone.
const IGNORE_PATH_PATTERN =
  /--ignore-path(?:=|\s+)(?:"([^"]*)"|'([^']*)'|(\S+))/g;

// The gitignore entry the first assertion leans on. Accepted with either
// prefix a root `.gitignore` uses to name this same directory, a root anchor
// (`/`) or the any-directory glob (`**/`), and with or without the trailing
// slash that restricts the entry to directories. Every combination ignores the
// directory, so rejecting one would red this guard over a rewrite that changed
// no behavior, which is a false failure a maintainer has to diagnose rather
// than a hole. Nothing may follow: a longer path under it
// (`.claude/worktrees/foo`) does not cover the directory as a whole.
const WORKTREE_IGNORE_PATTERN = /^(?:\/|\*\*\/)?\.claude\/worktrees\/?$/;

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

// A prettier INVOCATION, not the bare token. `.prettierignore` contains
// `prettier`, so a substring test is satisfied by a script that only names the
// ignore file and never runs the formatter, which is the one shape that would
// let the assertions below report an ignore scope held over a script doing no
// formatting at all. What separates an invocation from a mention is the
// boundary on each side: the command opens the script or follows whitespace, a
// separator, or a path separator, and ends at whitespace or the end. A runner
// prefix (`pnpm exec prettier`, `npx prettier`) needs no alternation of its
// own, since the space it puts before the command is itself the opening
// boundary; the path separator is what admits a path-invoked
// `./node_modules/.bin/prettier`, which would otherwise be a false red on a
// script that does run the formatter. None of those boundaries admits
// `.prettierignore`, whose preceding character is a dot.
const PRETTIER_INVOCATION_PATTERN = /(?:^|\s|&&|\|\||;|\/)prettier(?:\s|$)/;

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

// Throws rather than returning `undefined` for an absent or non-string script,
// the same posture `node-pin-parity.test.ts` takes toward an unreadable subject:
// a guard that cannot find what it guards has failed, not passed. It is also
// what keeps the assertions below typed, since the CLI tsconfig sets
// `noUncheckedIndexedAccess`.
const readFormatScript = (): string => {
  const {format} = readPackageScripts();

  if (typeof format !== 'string') {
    throw new TypeError('package.json declares no `format` script');
  }

  return format;
};

describe('root format script ignore scope', () => {
  test('the format script exists and runs prettier', () => {
    expect(readFormatScript()).toMatch(PRETTIER_INVOCATION_PATTERN);
  });

  test('does not narrow prettier below its default ignore set', () => {
    expect(narrowedIgnorePathsIn(readFormatScript())).toBeNull();
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
