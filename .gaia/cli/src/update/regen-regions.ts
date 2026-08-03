/**
 * `gaia update regen-regions --manifest <path> --root <dir> [--backup-dir <dir>]
 *   [--conflicted <repo-relative-path>]... [--absent-path <repo-relative-path>]...
 *   [--skip-region <id>]... [--json]` handler.
 *
 * Regeneration runner for SPEC-057's declared generated regions. `merge-region.ts`
 * only classifies a region's divergence; this command is what makes a declared
 * region correct again after an update, by running its shipped regeneration
 * command against the adopter's OWN post-merge tree. Unlike the oracle, this
 * command is not pure: it spawns a process and writes files.
 *
 * Reads the `regions` declaration array straight off `--manifest` as raw JSON.
 * The adopter side does no schema validation of the manifest, so every field
 * here is treated as untrusted shape: a malformed declaration is refused, never
 * thrown.
 *
 * **Trust model.** The shipped-path / symlink / parent-segment checks in
 * `checkOperand` are a well-formedness guard against a stale, corrupt, or
 * hand-edited declaration. The update flow already extracts and runs the
 * release tarball's bundled tool, and the tarball is transport-authenticated
 * only, so these checks are not, and must not be described as, a defense
 * against an adversary who controls the manifest.
 *
 * **Write confinement.** A region's regeneration command legitimately rewrites
 * every path it owns, but nothing else. Before the spawn, this command hashes
 * every regular file and symlink under the union of the declared paths' parent
 * directories (the "snapshot scope"); after the spawn, any such path in scope
 * the spawn newly created is removed, and then anything in scope that is not
 * one of the region's declared paths and no longer matches its pre-image is put
 * back, whether the spawn rewrote it or deleted it. Undoing the creations first
 * is what leaves an ordinary run with real directories to resolve through, so a
 * link the spawn left behind is gone before any pre-image is written near it.
 * Three rules hold the guarantee whatever order anything happens in. Neither
 * snapshot pass traverses a symlink, inside the scope or above it, so a link
 * is recorded and restored as itself and nothing behind one is read or
 * written; a scope directory that is a link, or is reached through one, is
 * recorded but never walked, since reading through a link the writes will not
 * resolve through is what would put an out-of-tree pre-image inside the
 * repository. Every write first asks whether the components between the root
 * and the key are real directories, reporting rather than resolving through one
 * that is not, so a scope key can never name one place while the bytes land in
 * another. And a path is deleted as a spawn creation only where the snapshot
 * positively established that nothing was at that key beforehand, which is
 * `collectScopeDigests`' removal invariant, stated in full there and not
 * restated here. Anything else is reported rather than deleted.
 *
 * A `git status --porcelain -z` before/after pair also catches a
 * write anywhere else in the tree; that has no pre-image to restore from, so
 * it is only reported, never reverted. The spawn never runs through a shell
 * and never takes a shell-interpreted string: it is always a fixed argv array,
 * and it is bounded in output and runtime.
 *
 * Exit codes: 0 for every refusal, skip, spawn failure, or non-zero program
 * exit; 1 only when the flags or `--manifest` itself are unusable.
 */
import {execFileSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {
  chmodSync,
  copyFileSync,
  existsSync,
  lstatSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  readlinkSync,
  realpathSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from 'node:fs';
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {execGaiaGitRaw} from '../util/git-env.js';

const HELP_TEXT = `Usage: gaia update regen-regions --manifest <path> --root <dir> [--backup-dir <dir>]
                                  [--conflicted <repo-relative-path>]...
                                  [--absent-path <repo-relative-path>]...
                                  [--skip-region <id>]... [--json]

  Runs each declared region's regeneration command against <root>, one region
  at a time. A region named by --skip-region, or one of whose declared paths
  appears in --conflicted or --absent-path, is left alone. A declaration that
  fails well-formedness, or an operand that fails the shipped-path / symlink /
  parent-segment guard, is refused before anything is spawned. Writes outside
  a region's declared paths are reverted (inside the region's own directories)
  or reported (anywhere else); a regular file or symlink the snapshot could
  examine is never silently kept.

  Read the manifest's regions from a RELEASE copy, never the adopter's stale
  working-tree copy: pass $LATEST_DIR/.gaia/manifest.json as --manifest.

  Each regeneration program gets 5 minutes and 32 MiB of output before it is
  killed. A program stopped by either bound is reported as killed with the
  bound named, so a command that legitimately needs more is told what stopped
  it rather than left looking like one that never started.

  Exit codes:
    0  success, including every refusal, skip, spawn failure, or non-zero
       program exit
    1  user-correctable error (missing flag / unreadable or unparseable
       --manifest / missing --root)
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

export type RegenRegionsReport = {
  backedUp: string[];
  confined: ConfinedEntry[];
  failed: FailedEntry[];
  ran: RanEntry[];
  refused: RefusedEntry[];
  skipped: SkippedEntry[];
};

type ConfinedEntry = {
  action: 'removed' | 'reported' | 'restored';
  path: string;
  regionId: string;
};

type FailedEntry = {
  argv: string[];
  /** `killed` only: which bound, or none of them, ended the program. */
  cause?: KilledCause;
  kind: 'exit' | 'killed' | 'spawn';
  message: string;
  regionId: string;
  signal?: string;
  status?: number;
};

type Flags = {
  absentPaths: string[];
  backupDir: string | undefined;
  conflicted: string[];
  json: boolean;
  manifest: string;
  root: string;
  skipRegions: string[];
};

type ParsedFlagsResult =
  {flags: Flags; ok: true} | {message: string; ok: false};

type RanEntry = {argv: string[]; regionId: string; rewrote: string[]};

type RefusedEntry = {
  argv?: string[];
  kind: 'declaration' | 'manifest' | 'operand';
  reason: string;
  regionId: string;
};

type SkippedEntry = {argv: string[]; reason: string; regionId: string};

const takeValue = (
  argv: readonly string[],
  index: number,
  flag: string
): {message: string; ok: false} | {ok: true; value: string} => {
  const value = argv.at(index);

  if (value === undefined)
    return {message: `${flag} requires a value`, ok: false};

  return {ok: true, value};
};

type ParseState = {
  absentPaths: string[];
  backupDir: string | undefined;
  conflicted: string[];
  json: boolean;
  manifest: string | undefined;
  root: string | undefined;
  skipRegions: string[];
};

type ValueFlagHandler = (state: ParseState, value: string) => void;

const VALUE_FLAGS: Readonly<Record<string, ValueFlagHandler>> = {
  '--absent-path': (state, value) => {
    state.absentPaths.push(value);
  },
  '--backup-dir': (state, value) => {
    state.backupDir = value;
  },
  '--conflicted': (state, value) => {
    state.conflicted.push(value);
  },
  '--manifest': (state, value) => {
    state.manifest = value;
  },
  '--root': (state, value) => {
    state.root = value;
  },
  '--skip-region': (state, value) => {
    state.skipRegions.push(value);
  },
};

const lookupValueFlag = (token: string): undefined | ValueFlagHandler =>
  Object.hasOwn(VALUE_FLAGS, token) ? VALUE_FLAGS[token] : undefined;

const parseFlags = (argv: readonly string[]): ParsedFlagsResult => {
  const state: ParseState = {
    absentPaths: [],
    backupDir: undefined,
    conflicted: [],
    json: false,
    manifest: undefined,
    root: undefined,
    skipRegions: [],
  };

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];
    const handler = lookupValueFlag(token);

    if (token === '--json') {
      state.json = true;
    } else if (handler === undefined) {
      return {message: `unknown flag: ${token}`, ok: false};
    } else {
      const taken = takeValue(argv, index + 1, token);

      if (!taken.ok) return taken;
      handler(state, taken.value);
      index += 1;
    }
  }

  const {
    absentPaths,
    backupDir,
    conflicted,
    json,
    manifest,
    root,
    skipRegions,
  } = state;

  if (manifest === undefined)
    return {message: '--manifest is required', ok: false};

  if (root === undefined) return {message: '--root is required', ok: false};

  return {
    flags: {
      absentPaths,
      backupDir,
      conflicted,
      json,
      manifest,
      root,
      skipRegions,
    },
    ok: true,
  };
};

type DeclarationParseResult =
  | {declaration: ParsedDeclaration; ok: true}
  | {ok: false; reason: string; regionId: string};

type ParsedDeclaration = {
  args: string[];
  endMarker: string;
  id: string;
  interpreter: string;
  operand: string;
  paths: string[];
  startMarker: string;
};

const isNonEmptyString = (value: unknown): value is string =>
  typeof value === 'string' && value.trim() !== '';

const isStringArray = (value: unknown): value is string[] =>
  Array.isArray(value) && value.every((item) => typeof item === 'string');

const isPlainObject = (value: unknown): value is Record<string, unknown> =>
  typeof value === 'object' && value !== null && !Array.isArray(value);

/**
 * Names a parsed-JSON value's shape for a refusal reason. `null` and arrays
 * are spelled out because `typeof` calls both `'object'`, which would report
 * them identically to the plain object this exists to tell them apart from.
 */
const describeJsonShape = (value: unknown): string => {
  if (value === null) return 'null';

  return Array.isArray(value) ? 'array' : typeof value;
};

/** Strips a leading `./`, collapses separators, converts to POSIX. */
const normalizeRepoPath = (value: string): string => {
  const posix = value.replaceAll('\\', '/').replaceAll(/\/{2,}/gu, '/');

  return posix.startsWith('./') ? posix.slice(2) : posix;
};

/**
 * Well-formedness guard for `paths[]`, the counterpart to `checkOperand`'s
 * guard on the operand. Both are downstream of the same untrusted manifest,
 * and every consumer of a declared path resolves it against `--root`: the
 * backup copies it, the snapshot walks its parent directory, and the sweep
 * writes and deletes inside that directory. An entry that is absolute or
 * carries a parent segment therefore reaches outside `--root` on all three.
 *
 * Normalizing here rather than at each use site is what makes `declaredSet`
 * and the snapshot keys agree by construction. The snapshot canonicalizes its
 * keys through `path.relative`, so a declared `./a/b.md` would otherwise never
 * match its own snapshot entry, and the sweep would revert the very file the
 * regeneration just wrote while reporting the run a success.
 */
const normalizeDeclaredPaths = (
  paths: readonly string[]
): {ok: false; reason: string} | {ok: true; paths: string[]} => {
  const normalized: string[] = [];

  for (const declPath of paths) {
    const candidate = normalizeRepoPath(declPath);

    if (candidate.trim() === '')
      return {ok: false, reason: 'paths carries an empty entry'};

    if (path.isAbsolute(candidate))
      return {
        ok: false,
        reason: `paths carries an absolute path: ${candidate}`,
      };

    if (candidate.split('/').includes('..'))
      return {
        ok: false,
        reason: `paths carries a parent-directory segment: ${candidate}`,
      };

    // The snapshot scope is the union of the declared paths' parent
    // directories, so a path whose parent is the repository root scopes the
    // snapshot to the entire tree: every file under it read and buffered
    // twice per region, `node_modules` and `.git` included. A literal '.'
    // is worse than slow, because it is never equal to any snapshot key, so
    // the sweep reverts the region's own freshly written output while still
    // reporting the region as run.
    if (path.posix.dirname(candidate) === '.')
      return {
        ok: false,
        reason: `paths carries a path whose parent is the repository root: ${candidate}`,
      };

    normalized.push(candidate);
  }

  return {ok: true, paths: normalized};
};

/**
 * Defensive shape parse of one `regions[]` entry (untrusted JSON). Never
 * throws: every defect resolves to a `refused[]`-shaped result, never a crash.
 *
 * `seenIds` is mutated as soon as a candidate id is confirmed non-empty and
 * unique, before the rest of the declaration is validated. That way a
 * duplicate id is always caught on its second occurrence, even when the
 * FIRST declaration bearing that id is itself malformed for an unrelated
 * reason (and so never reaches `ok: true`).
 */
const parseDeclaration = (
  raw: unknown,
  index: number,
  seenIds: Set<string>
): DeclarationParseResult => {
  const fallbackId = `region-at-index-${index}`;

  if (!isPlainObject(raw))
    return {
      ok: false,
      reason: 'declaration is not an object',
      regionId: fallbackId,
    };

  const {endMarker, id, paths, regenerate, startMarker} = raw;

  if (!isNonEmptyString(id))
    return {
      ok: false,
      reason: 'declaration is missing a non-empty id',
      regionId: fallbackId,
    };

  if (seenIds.has(id))
    return {ok: false, reason: `duplicate region id: ${id}`, regionId: id};

  seenIds.add(id);

  if (!isNonEmptyString(startMarker))
    return {ok: false, reason: 'startMarker is missing or empty', regionId: id};

  if (!isNonEmptyString(endMarker))
    return {ok: false, reason: 'endMarker is missing or empty', regionId: id};

  if (!isStringArray(paths))
    return {
      ok: false,
      reason: 'paths is missing or not an array of strings',
      regionId: id,
    };

  const declaredPaths = normalizeDeclaredPaths(paths);

  if (!declaredPaths.ok)
    return {ok: false, reason: declaredPaths.reason, regionId: id};

  if (!isPlainObject(regenerate))
    return {
      ok: false,
      reason: 'regenerate is missing or not an object',
      regionId: id,
    };

  const {args, interpreter, operand} = regenerate;

  if (!isNonEmptyString(interpreter))
    return {
      ok: false,
      reason: 'regenerate.interpreter is missing or empty',
      regionId: id,
    };

  if (!isNonEmptyString(operand))
    return {
      ok: false,
      reason: 'regenerate.operand is missing or empty',
      regionId: id,
    };

  if (!isStringArray(args))
    return {
      ok: false,
      reason: 'regenerate.args is missing or not an array of strings',
      regionId: id,
    };

  return {
    declaration: {
      args,
      endMarker,
      id,
      interpreter,
      operand,
      paths: declaredPaths.paths,
      startMarker,
    },
    ok: true,
  };
};

type SkipInputs = {
  absentPaths: ReadonlySet<string>;
  conflicted: ReadonlySet<string>;
  skipRegions: ReadonlySet<string>;
};

/**
 * Step 2: skip conditions, checked before the operand guard. A region reaches
 * here only after well-formedness, so its argv is always buildable.
 */
const computeSkipReason = (
  decl: ParsedDeclaration,
  inputs: SkipInputs
): string | undefined => {
  const {absentPaths, conflicted, skipRegions} = inputs;

  if (skipRegions.has(decl.id)) return 'inputs not reconciled by this run';

  const conflictedPaths = decl.paths.filter((declPath) =>
    conflicted.has(declPath)
  );

  if (conflictedPaths.length > 0)
    return `region is not regenerated until the adopter resolves the conflict patch for: ${conflictedPaths.join(', ')}`;

  const missingPaths = decl.paths.filter((declPath) =>
    absentPaths.has(declPath)
  );

  if (missingPaths.length > 0)
    return `the adopter's tree does not carry: ${missingPaths.join(', ')}`;

  return undefined;
};

type OperandGuardContext = {
  realRoot: string;
  root: string;
  shippedKeys: ReadonlySet<string>;
};

/**
 * Step 3: refuse before anything is spawned. See the module doc's trust-model
 * note: this is a well-formedness guard, not a defense against a hostile
 * manifest.
 */
const checkOperand = (
  decl: ParsedDeclaration,
  context: OperandGuardContext
): string | undefined => {
  const {realRoot, root, shippedKeys} = context;
  const {interpreter, operand} = decl;

  if (path.isAbsolute(operand)) return 'operand is an absolute path';

  if (operand.split('/').includes('..'))
    return 'operand carries a parent-directory segment';

  if (!shippedKeys.has(normalizeRepoPath(operand)))
    return 'operand is not a path this manifest ships';

  let resolvedReal: string | undefined;

  try {
    resolvedReal = realpathSync(path.resolve(root, operand));
  } catch {
    // Target does not exist: not a refusal here, a spawn failure in step 6.
    resolvedReal = undefined;
  }

  if (resolvedReal !== undefined) {
    const insideRoot =
      resolvedReal === realRoot ||
      resolvedReal.startsWith(`${realRoot}${path.sep}`);

    if (!insideRoot)
      return 'operand resolves through a symlink out of the repository';
  }

  if (
    interpreter.trim() === '' ||
    path.isAbsolute(interpreter) ||
    interpreter.includes('/') ||
    interpreter.includes('\\')
  )
    return 'interpreter is not a bare program name';

  return undefined;
};

/**
 * Step 4: copy each existing declared path aside, unless a copy is already
 * there (the merge walk's own backup, or an earlier region's).
 */
type BackupInputs = {
  backupDir: string | undefined;
  paths: readonly string[];
  regionId: string;
  root: string;
};

const performBackup = (inputs: BackupInputs): string[] => {
  const {backupDir, paths, regionId, root} = inputs;

  if (backupDir === undefined) return [];

  const backedUp: string[] = [];

  paths.forEach((declPath) => {
    const srcAbs = path.resolve(root, declPath);

    if (!existsSync(srcAbs)) return;

    const destinationAbs = path.resolve(backupDir, declPath);

    if (existsSync(destinationAbs)) return;

    // Contained like every other IO call in the region loop. A throw here
    // would discard the whole report, including the confinement records of
    // every region already swept, and the caller reads an empty report as a
    // CLI that predates this subcommand rather than as a backup failure.
    try {
      mkdirSync(path.dirname(destinationAbs), {recursive: true});
      copyFileSync(srcAbs, destinationAbs);
      backedUp.push(declPath);
    } catch (error) {
      structuredError({
        code: 'region_regen_backup_failed',
        message: `backup skipped for '${declPath}' in region '${regionId}': ${error instanceof Error ? error.message : String(error)}`,
        regionId,
        subcommand: 'update regen-regions',
      });
    }
  });

  return backedUp;
};

const scopeDirsFor = (paths: readonly string[]): ReadonlySet<string> =>
  new Set(paths.map((declPath) => path.posix.dirname(declPath)));

/**
 * A `SnapshotEntry` (declared below, the sort order puts this first) that still
 * carries a pre-image, so the sweep can write it back: a file whose bytes were
 * read, or a link whose target was read. The one entry that is not restorable
 * is `unreadable`, recorded for presence alone. Asking this before anything is
 * unlinked is what keeps "was it here" from being answered as "can it be put
 * back".
 */
type RestorableEntry = Exclude<SnapshotEntry, {kind: 'unreadable'}>;
type Snapshot = ReadonlyMap<string, SnapshotEntry>;

/**
 * Both readable kinds carry their whole pre-image, so the sweep's two questions
 * ("did the spawn touch this" and "what do I put back") are answered per kind
 * rather than only for regular files. A file's pre-image is its bytes; a link's
 * is the target it holds, which is all a link is.
 *
 * That target is a `Buffer`, not a string, deliberately. A symlink target is an
 * arbitrary byte string on POSIX, and decoding one as UTF-8 does not fail on an
 * invalid byte, it substitutes U+FFFD. Writing that back would point the link
 * somewhere else while the report claimed it was restored, and the real target
 * is gone by then. Bytes in, bytes out, no decode in between.
 *
 * `unreadable` is the third answer and the one that keeps the sweep honest:
 * something was at this path before the spawn ran and none of it could be read.
 * EVERY IO failure in the walk records it rather than dropping the entry,
 * because a dropped entry answers "was this here" with "no", and the removal
 * loop then unlinks the adopter's own file as a spawn creation and reports the
 * data loss as a stray write cleaned up. It carries no pre-image, so it is
 * never restorable and never untouched: surfaced, never written, never deleted.
 */
type SnapshotEntry =
  | {content: Buffer; digest: string; kind: 'file'; mode: number}
  | {kind: 'symlink'; target: Buffer}
  | {kind: 'unreadable'};

const isRestorable = (entry: SnapshotEntry): entry is RestorableEntry =>
  entry.kind !== 'unreadable';

/** Permission bits alone; `lstat` mode also carries the file-type bits. */
const permissionsOf = (mode: number): number => mode % 0o1_0000;

/**
 * Whether the spawn left this path as it found it. A link is compared by the
 * target string it holds, a file by its bytes AND its permission bits: the two
 * kinds are never equal to each other, so replacing one with the other always
 * counts as a change.
 *
 * Permissions are part of the pre-image because the restore writes them back,
 * so leaving them out of the comparison lets the one change this command can
 * undo pass as no change at all: a spawn that makes an in-scope private file
 * world-readable, or strips the execute bit off one, would be judged untouched
 * and left that way.
 *
 * A pre-image that could not be read is not evidence of sameness, so an
 * `unreadable` entry on either side never answers "untouched". Claiming
 * otherwise would let a retarget through on the strength of a failed read.
 */
const isUntouched = (
  before: SnapshotEntry,
  after: SnapshotEntry | undefined
): boolean => {
  if (after === undefined) return false;

  if (before.kind === 'symlink') {
    return after.kind === 'symlink' && after.target.equals(before.target);
  }

  if (before.kind === 'file') {
    return (
      after.kind === 'file' &&
      after.digest === before.digest &&
      permissionsOf(after.mode) === permissionsOf(before.mode)
    );
  }

  return false;
};

/** Repo-relative and POSIX-separated: the frame every snapshot key is in. */
const relativeKey = (root: string, abs: string): string =>
  path.relative(root, abs).split(path.sep).join('/');

/**
 * Whether `path.resolve(root, relPath)` names the file this key means: true
 * when every directory component between the two that exists today is a real
 * directory rather than a symlink.
 *
 * A snapshot key is lexical and the tree it is applied to is the one the spawn
 * has just finished editing, so the two can disagree. Where they do, the key
 * names one place while the syscall lands in another, which is the confinement
 * guarantee inverted: the write leaves the tree while the report says it
 * stayed. Asked at the write site, this holds whatever else happened first,
 * rather than only while an earlier pass succeeded.
 *
 * The snapshot asks the same question of a scope directory before walking it,
 * which is what keeps the two passes symmetrical: reading through a link the
 * writes will not resolve through is what turns an out-of-tree pre-image into
 * a file inside the repository.
 *
 * A component that does not exist is fine: it is about to be created as a real
 * directory. Only what is there and is not a directory refuses the write.
 */
const resolvesLexically = (root: string, relPath: string): boolean => {
  const components = relPath.split('/').slice(0, -1);
  let current = root;

  return components.every((component) => {
    current = path.join(current, component);

    try {
      return lstatSync(current).isDirectory();
    } catch {
      return true;
    }
  });
};

/**
 * Whether the snapshot holds an entry for any directory above `relPath`, which
 * is `collectScopeDigests`' REMOVAL INVARIANT asked at one path. See that
 * function's docblock for the invariant and for why this is the right test;
 * do not restate it here.
 *
 * The one thing worth repeating at the call site is what it buys, because it is
 * not obvious that anything does: where an ancestor was not enumerated, a path
 * missing from `before` may equally be something the adopter already had that
 * has just ARRIVED at this key. `mv` is the ordinary way that happens, and it
 * moves rather than copies, while backups cover declared paths only, so
 * unlinking it destroys the one copy while the report calls it a stray write
 * cleaned up.
 */
const hasUnenumeratedAncestor = (
  before: Snapshot,
  relPath: string
): boolean => {
  const components = relPath.split('/').slice(0, -1);
  let prefix = '';

  return components.some((component) => {
    prefix = prefix === '' ? component : `${prefix}/${component}`;

    return before.has(prefix);
  });
};

/**
 * Step 5 / re-used for step 7-8: SHA-256 (plus raw content, for restoring)
 * of every existing file under the region's declared paths' parent
 * directories, recursively. Keys are repo-relative, POSIX-separated.
 *
 * **The removal invariant. This is the one statement of it; everything else in
 * this module points here rather than paraphrasing.** The sweep may delete a
 * path found only in the AFTER snapshot, on the grounds that the spawn created
 * it, only where this pass POSITIVELY ESTABLISHED that nothing was at that key
 * before. Anywhere else, a path that appears between the two passes may equally
 * be something the adopter already had that has just arrived there, and
 * deleting it destroys the only copy.
 *
 * The map's shape encodes it exactly: **this walk keys a node exactly when it
 * does not look inside it.** An unreadable directory, an unstattable entry, a
 * link recorded and not descended, a node that is neither of those nor a
 * directory nor a regular file, a regular file, and every arm of the scope-root
 * gate below all get a key. A real directory the walk descends gets none of its
 * own, because its children speak for it. So "no entry for this ancestor" means
 * "this pass enumerated it", the two directions agree, and
 * `hasUnenumeratedAncestor` reads the invariant itself rather than a proxy for
 * it.
 *
 * That biconditional is the thing to preserve before moving any arm of this
 * walk: an arm that stops keying a node it does not enumerate breaks it. Node
 * kind is never the reason to skip one, however plainly childless the kind
 * looks, because what the spawn puts at that path next is a different node.
 */
const collectScopeDigests = (
  root: string,
  scopeDirs: ReadonlySet<string>
): Snapshot => {
  const digests = new Map<string, SnapshotEntry>();

  // Walked by hand rather than with `readdirSync`'s `recursive` option, which
  // decides descent with a FOLLOWING stat and so walks straight through a
  // symlinked subdirectory. Everything behind such a link would be keyed
  // lexically (`<scope>/link/file`) while its bytes live wherever the link
  // points, and the sweep resolves those keys lexically too: it would read and
  // write outside the repository entirely while the report named a path inside
  // it. `lstat` here refuses to descend, so a link is only ever recorded as
  // itself, at every position rather than only the final one.
  //
  // The pending list is explicit rather than a recursive call, because the
  // adopter's own tree sets the depth. `readdirSync`'s recursive option keeps
  // its worklist on the heap for the same reason, and a deep scope directory
  // must not turn the confinement sweep into a stack overflow that abandons
  // every region still to be swept.
  const walk = (scopeRoot: string): void => {
    const pending = [scopeRoot];

    for (
      let absDir = pending.pop();
      absDir !== undefined;
      absDir = pending.pop()
    ) {
      const parent = absDir;
      let names: string[] = [];

      try {
        names = readdirSync(parent);
      } catch {
        // Unreadable directory: nothing inside it can be enumerated, so the
        // directory ITSELF is recorded present-but-unreadable and the walk
        // carries on with the rest. `hasUnenumeratedAncestor` reads that one
        // entry to answer for the whole subtree, which is what stops a spawn
        // that merely makes the directory readable from turning every file the
        // adopter already had inside it into an apparent creation.
        digests.set(relativeKey(root, parent), {kind: 'unreadable'});
      }

      names.forEach((name) => {
        const abs = path.join(parent, name);
        const repoRelative = relativeKey(root, abs);
        let stat;

        try {
          // `lstat`, not `stat`: a symlink must not be followed here. Followed,
          // it would be buffered as its TARGET's bytes, and the sweep would
          // then restore it as a plain regular file holding a copy of content
          // that may have lived wholly outside the region, or write through the
          // link and rewrite a target outside the snapshot scope entirely.
          stat = lstatSync(abs);
        } catch {
          // A parent that is readable but not searchable, or a race: the name
          // came back from `readdir`, so something is here, and that is the
          // whole of what is known about it.
          //
          // Every errno records here, ENOENT included, unlike the scope-root
          // gate below, which discriminates. The asymmetry is the point: here
          // `readdir` has just named this entry, so a vanished one is a race
          // and presence is the conservative answer, costing one `reported`
          // row. There, ENOENT is the ordinary "this region has no directory
          // in this tree" case, which would otherwise report on every run.
          digests.set(repoRelative, {kind: 'unreadable'});

          return;
        }

        // A link's pre-image is the target it holds, which is the whole of it:
        // recording that makes a link restorable in its own right, so the
        // confinement guarantee covers every shape a link can be left in
        // (deleted, retargeted, replaced by a file) rather than only the
        // created one. Reading it never follows the link, and a dangling one
        // reads fine. `'buffer'`, never `'utf8'`: see SnapshotEntry.
        if (stat.isSymbolicLink()) {
          try {
            digests.set(repoRelative, {
              kind: 'symlink',
              target: readlinkSync(abs, 'buffer'),
            });
          } catch {
            digests.set(repoRelative, {kind: 'unreadable'});
          }

          return;
        }

        if (stat.isDirectory()) {
          pending.push(abs);

          return;
        }

        // A FIFO, socket, or device node: present, with nothing to read. It is
        // never OPENED, which for a FIFO would block until a writer arrives,
        // and never will here.
        //
        // Recorded rather than skipped, for the same reason as every other arm
        // above: an unrecorded node is an absent one, and it is childless only
        // for as long as it stays this kind. A spawn that replaces it with
        // moved-in content (`rm`, then `mv`) puts the adopter's only copy at
        // keys this pass would otherwise have said nothing about, and the
        // removal loop takes them.
        if (!stat.isFile()) {
          digests.set(repoRelative, {kind: 'unreadable'});

          return;
        }

        let content;

        try {
          content = readFileSync(abs);
        } catch {
          // Unreadable file (permissions, a race with the spawn): present, with
          // no pre-image. Throwing here would abandon the confinement sweep and
          // the report for every remaining region, which is the one outcome
          // this command promises never to produce.
          digests.set(repoRelative, {kind: 'unreadable'});

          return;
        }

        digests.set(repoRelative, {
          content,
          digest: createHash('sha256').update(content).digest('hex'),
          kind: 'file',
          mode: stat.mode,
        });
      });
    }
  };

  scopeDirs.forEach((dir) => {
    // Ancestors first, and before the `lstat` below, which resolves every
    // component of the path except the last: a symlinked directory ABOVE the
    // scope root is walked straight through, and everything behind it keyed as
    // though it lived in this repository. Both passes read through the same
    // link, so the round trip is self-consistent only for as long as the link
    // is there; the moment the spawn replaces it with a real directory, the
    // sweep resolves those keys lexically and writes the out-of-tree
    // pre-images INTO the repository, at paths that never held them.
    //
    // Refusing to WALK the scope is what closes that. Refusing to record it
    // would reopen the same hole one level out: an unrecorded scope root is an
    // absent one, so if the spawn de-symlinks the path (a `mv` or `cp -R`,
    // not a fresh `mkdir`), the content that arrives there is in `after`,
    // missing from `before`, and unlinked as a creation. That content is the
    // adopter's, it has just been moved rather than copied, and `performBackup`
    // covers declared paths only, so there is no second copy anywhere.
    //
    // Keyed through `relativeKey(root, absDir)` rather than from `dir`
    // directly. `dir` is a declared path's `dirname`, and a declaration can
    // carry an interior `./` that normalization leaves alone, which would key
    // this entry somewhere no `after` key can ever match and silently unshelter
    // the subtree. `path.resolve` settles that before the key is derived, so
    // this guarantee does not rest on a declaration being well shaped.
    const absDir = path.resolve(root, dir);
    const scopeKey = relativeKey(root, absDir);

    // The walk and this gate both write to `digests`, and a region may declare
    // paths whose parent directories nest, so both can key the SAME node: the
    // outer scope's walk reaches it as an entry, the inner scope's gate reaches
    // it as its own root. The walk's entry wins, always, and it is never the
    // worse of the two for either question the map answers. Both shelter
    // identically, because shelter asks only whether a key is present. For
    // restoring, the walk's entry either carries the node's whole pre-image
    // where this one carries none, or is itself `unreadable`, in which case the
    // two say the same thing and which one wins does not matter.
    //
    // Stated once rather than at each of the three arms below, because the rule
    // is about the map rather than about any one arm. Without it, reversing two
    // entries in `paths[]` reverses whether an undeclared path is restored or
    // merely reported, and declaration order is not a fact about the tree.
    const recordUnexaminable = (): void => {
      if (!digests.has(scopeKey)) digests.set(scopeKey, {kind: 'unreadable'});
    };

    if (!resolvesLexically(root, dir)) {
      recordUnexaminable();

      return;
    }

    let stat;

    try {
      stat = lstatSync(absDir);
    } catch (error) {
      // ENOENT alone means there is nothing here to snapshot, the ordinary
      // case for a region whose directory does not exist in this tree.
      //
      // Every other errno means the directory IS here and cannot be examined,
      // most often because its own parent lost its search bit, and swallowing
      // that is the same defect the arms inside the walk answer, one level up:
      // the whole scope reads as absent, so a spawn that does no more than
      // restore the bit makes every file under it look newly created and the
      // removal loop empties it. An unexaminable scope root is recorded like
      // any other unreadable path, and answers for everything beneath it.
      //
      // A non-object throw cannot be read for an errno, so it takes the
      // conservative arm rather than the silent one.
      if (!isPlainObject(error) || error.code !== 'ENOENT') {
        recordUnexaminable();
      }

      return;
    }

    // A scope directory that is ITSELF a link is not walked, like any other
    // link: its contents are not in this repository however its key reads, so
    // there is nothing here the sweep may write to. It is still RECORDED,
    // for the de-symlink case described above.
    if (!stat.isDirectory()) {
      recordUnexaminable();

      return;
    }

    walk(absDir);
  });

  return digests;
};

type SweepInputs = {
  after: Snapshot;
  before: Snapshot;
  declaredPaths: readonly string[];
  regionId: string;
  root: string;
};

/**
 * Step 7: revert anything in the snapshot scope that the spawn touched
 * outside the region's declared paths. Every such path that has a pre-image
 * is restored to it, whether the spawn rewrote it, retargeted it, replaced it
 * with the other kind, or deleted it; a path the spawn created has no
 * pre-image, so it is removed instead. That is the confinement guarantee as
 * stated: reverted when a pre-image exists, reported when it does not.
 *
 * Five limits on "reverted", each deliberate. The first three surface as
 * `reported`; the last two do not, and each names its own arms:
 *
 * - A pre-image the spawn replaced with a DIRECTORY is not restored. `rmSync`
 *   here is deliberately not recursive, and deleting an arbitrary tree the
 *   adopter may care about in order to put one file back is a wider blast
 *   radius than this guarantee asks for.
 * - A path whose components are not all real directories is not written
 *   through, since the key would name one place and the syscall land in
 *   another.
 * - A directory that is a link, or is reached through one, is never walked
 *   (`collectScopeDigests`), so nothing inside it is reverted: reading through
 *   a link the writes will not resolve through is what would put an out-of-tree
 *   pre-image inside the repository. It is still recorded, which is what keeps
 *   an unwalked node from reading as an empty one if the spawn later replaces
 *   it with a real directory.
 * - A file the spawn writes THROUGH an in-scope symlinked directory is not
 *   reverted, and there is not even a row for the directory: the link is
 *   untouched, so it matches its own pre-image and the sweep passes over it.
 *   What reaches the file itself depends on where the link points, and there
 *   are three answers. Pointing OUTSIDE the root, nothing reports it, and
 *   nothing should: the bytes landed where this command has no pre-image and no
 *   business writing, and git does not descend a link either. Pointing inside
 *   the root but outside every scope, they land at a real in-tree path, and the
 *   whole-root `git status` half reports them like any other out-of-scope
 *   write, unless git is unavailable or that path is ignored. Pointing into
 *   another SCOPE directory, the snapshot enumerates the landing path itself,
 *   so the file is an undeclared creation at a key of its own and is REMOVED
 *   like any other.
 * - A DIRECTORY the spawn creates in scope is left behind, empty and without a
 *   row. The walk keys no directory it descends, so there is nothing for the
 *   removal loop to take; what the spawn put inside it is keyed and removed,
 *   which is where the content actually is. Removing the directory too would
 *   mean unlinking a node this pass never recorded, on the strength of its
 *   emptiness at one instant.
 */
const sweepScope = (inputs: SweepInputs): ConfinedEntry[] => {
  const {after, before, declaredPaths, regionId, root} = inputs;
  const declaredSet = new Set(declaredPaths);
  const confined: ConfinedEntry[] = [];

  // The spawn's own creations are undone FIRST, before any pre-image goes
  // back. One of those creations can be a symlink sitting where a scope
  // subdirectory used to be, and undoing it first is what leaves the restores
  // below with real directories to resolve through, so an ordinary run puts
  // the pre-image back where it belongs instead of refusing it. The guarantee
  // itself does not rest on this order, `resolvesLexically` holds it at each
  // write; the order is what makes the good outcome the common one.
  [...after.keys()].forEach((relPath) => {
    if (declaredSet.has(relPath) || before.has(relPath)) return;

    // Absent from `before` is not the same as created by the spawn when the
    // before pass never looked inside the directory this sits in. Deleting it
    // would be the sweep destroying what the adopter already had and reporting
    // it as a stray write cleaned up, so the whole unverifiable subtree is
    // surfaced instead of guessed at.
    if (hasUnenumeratedAncestor(before, relPath)) {
      confined.push({action: 'reported', path: relPath, regionId});

      return;
    }

    if (!resolvesLexically(root, relPath)) {
      confined.push({action: 'reported', path: relPath, regionId});

      return;
    }

    try {
      // `rmSync` unlinks a symlink rather than following it, so removing one
      // the spawn created never touches what it pointed at.
      rmSync(path.resolve(root, relPath), {force: true});
      confined.push({action: 'removed', path: relPath, regionId});
    } catch {
      confined.push({action: 'reported', path: relPath, regionId});
    }
  });

  before.forEach((beforeEntry, relPath) => {
    if (declaredSet.has(relPath)) return;

    // Untouched: nothing to undo. Anything else is an out-of-scope write with
    // a pre-image, and a deletion is one of those: it is absent from `after`
    // rather than merely different. Either way the thing to put back is the
    // same `before` entry.
    if (isUntouched(beforeEntry, after.get(relPath))) return;

    // Present in the snapshot, but with no pre-image: a link whose target, a
    // file whose bytes, or a directory whose entries could not be read. Nothing
    // can be written back without inventing it, so this is surfaced and left
    // alone, and it is asked BEFORE the unlink below. Its presence has already
    // done its one job above, keeping the removal loop from taking what the
    // adopter already had for something the spawn created.
    if (!isRestorable(beforeEntry)) {
      confined.push({action: 'reported', path: relPath, regionId});

      return;
    }

    // Something is standing between this key and the file it names, so the
    // write would leave the tree. Surface it rather than resolve through it,
    // and ask before `mkdirSync` below, which would otherwise create the
    // missing components inside whatever the link points at.
    if (!resolvesLexically(root, relPath)) {
      confined.push({action: 'reported', path: relPath, regionId});

      return;
    }

    try {
      const abs = path.resolve(root, relPath);

      // A deletion may have taken the parent directory with it.
      mkdirSync(path.dirname(abs), {recursive: true});
      // Unlink first, never write onto whatever is sitting there. If the spawn
      // replaced this path with a symlink, writing would FOLLOW the link and
      // put the pre-image into its target, which can live anywhere in or
      // outside the tree: the confinement mechanism writing outside the scope
      // it exists to enforce, while the path itself stays a link and the
      // report claims it was restored.
      rmSync(abs, {force: true});

      if (beforeEntry.kind === 'symlink') {
        // Recreating the link writes no content and follows nothing, so
        // whatever it points at is untouched, exactly as when it was made.
        symlinkSync(beforeEntry.target, abs);
      } else {
        const permissions = permissionsOf(beforeEntry.mode);

        // `restored` has to mean restored. Recreating content under the process
        // umask hands back an executable the adopter can no longer run, and
        // creating it at its own permissions keeps a private pre-image from
        // existing world-readable even briefly.
        writeFileSync(abs, beforeEntry.content, {mode: permissions});
        chmodSync(abs, permissions);
      }

      confined.push({action: 'restored', path: relPath, regionId});
    } catch {
      // The revert itself failed. Surface the write rather than throwing:
      // an abandoned sweep would leave every later entry unexamined and
      // unreported, which is exactly the silent out-of-scope write the
      // confinement guarantee rules out. `reported` is the contract's term
      // for a write that is surfaced rather than reverted.
      confined.push({action: 'reported', path: relPath, regionId});
    }
  });

  return confined;
};

const isInsideScope = (
  relPath: string,
  scopeDirs: ReadonlySet<string>
): boolean =>
  [...scopeDirs].some(
    (dir) => relPath === dir || relPath.startsWith(`${dir}/`)
  );

type GitStatus = {
  /** Root-relative, the same frame every other path in the report uses. */
  inside: string[];
  /** Changed paths that lie above `root`, kept in top-level frame. */
  outside: string[];
};

/**
 * Whole-root `git status --porcelain -z` path list. `null` when git is
 * unavailable or `root` is not a repository, so the caller can degrade
 * cleanly rather than failing.
 *
 * `-z` is load-bearing, not a formatting preference. Without it git applies
 * C-style quoting (`core.quotePath` is on by default), so a path carrying a
 * space, a quote, or a non-ASCII byte arrives wrapped in `"` with its bytes
 * escaped, and a rename arrives as one ambiguous `old -> new` payload that
 * cannot be split on ` -> ` without corrupting a name that contains it.
 * Under `-z` git never quotes, and a rename gets its own trailing record for
 * the origin path, so both hazards disappear rather than being unescaped.
 *
 * Every record git returns is relative to the repository TOP LEVEL, never to
 * `root`, and the two differ whenever a GAIA project sits inside a larger
 * repository. Rebasing them onto `root` is what keeps the caller's comparisons
 * against the declared paths and the snapshot scope, both root-relative,
 * meaningful; without it every one of the region's own legitimate writes fails
 * to match and is reported to the adopter as an out-of-scope write.
 */
const gitStatusPaths = (root: string): GitStatus | null => {
  try {
    // Raw, never trimmed: the ` M path` shape's leading space is a status
    // column, and trimming it shifts the 3-character prefix slice below.
    const out = execGaiaGitRaw(['status', '--porcelain', '-z'], root);
    const paths: string[] = [];
    // A rename/copy record is followed by a bare origin-path record carrying
    // no `XY ` status prefix, so the stream needs a one-record lookahead. The
    // flag is cleared before the next record is classified, which is what
    // keeps an origin path whose own first two characters contain `R` or `C`
    // (`Config/old`) from being read as a status record.
    let expectOriginPath = false;

    out
      .split('\0')
      .filter((record) => record.length > 0)
      .forEach((record) => {
        if (expectOriginPath) {
          expectOriginPath = false;
          paths.push(record);

          return;
        }

        expectOriginPath = /[CR]/u.test(record.slice(0, 2));
        paths.push(record.slice(3));
      });

    // `--show-prefix` is `root`'s own path relative to the top level, with a
    // trailing slash, and empty when the two coincide (the ordinary case, and
    // the only one `--root .` at a repository root produces).
    const prefix = execGaiaGitRaw(['rev-parse', '--show-prefix'], root).replace(
      /\r?\n$/u,
      ''
    );

    if (prefix === '') return {inside: paths, outside: []};

    const inside: string[] = [];
    const outside: string[] = [];

    paths.forEach((changedPath) => {
      if (changedPath.startsWith(prefix)) {
        inside.push(changedPath.slice(prefix.length));

        return;
      }

      outside.push(changedPath);
    });

    return {inside, outside};
  } catch {
    return null;
  }
};

type SpawnOutcome =
  | {
      cause: KilledCause;
      kind: 'killed';
      message: string;
      ok: false;
      signal: string;
    }
  | {kind: 'exit'; message: string; ok: false; status: number}
  | {kind: 'spawn'; message: string; ok: false}
  | {ok: true};

/** Reads one field off a thrown value without asserting its shape. */
const errorField = (error: unknown, key: string): unknown =>
  isPlainObject(error) ? error[key] : undefined;

export type KilledCause = 'external' | 'maxBuffer' | 'timeout';

/**
 * Which of the three ways a killed child died. All three arrive identically
 * otherwise, `signal: 'SIGTERM'` and no status, so without this an adopter
 * whose program legitimately runs past the time bound, one that legitimately
 * says more than the output bound, and one an operator killed by hand all read
 * the same and none of them names GAIA's own ceiling as the reason.
 *
 * The codes are Node's, observed on the sync spawn path: a `timeout` kill
 * surfaces `ETIMEDOUT` and a `maxBuffer` overflow `ENOBUFS`, each on both the
 * thrown error and its nested `error`. Anything else came from outside this
 * process's own bounds.
 */
export const spawnFailureCause = (code: unknown): KilledCause => {
  if (code === 'ETIMEDOUT') return 'timeout';

  if (code === 'ENOBUFS') return 'maxBuffer';

  return 'external';
};

/**
 * Runaway guards on the regeneration program, not a performance budget.
 * Without them the spawn inherits Node's 1 MiB output buffer and no time
 * limit, so a program that merely talks a lot is killed mid-run, and one
 * that hangs hangs the whole update. The one shipped regeneration command is
 * nearly silent and fast; these bounds exist for adopter-authored ones.
 */
const SPAWN_MAX_BUFFER_BYTES = 32 * 1024 * 1024;
const SPAWN_TIMEOUT_MS = 5 * 60 * 1000;

/**
 * Step 6. Never runs through a shell, never a shell-interpreted string, and
 * never enables the shell option: the interpreter comes from the
 * declaration, so no shipped script's executable bit is load-bearing.
 */
const trySpawn = (decl: ParsedDeclaration, root: string): SpawnOutcome => {
  try {
    execFileSync(
      decl.interpreter,
      [path.resolve(root, decl.operand), ...decl.args],
      {
        cwd: root,
        encoding: 'utf8',
        maxBuffer: SPAWN_MAX_BUFFER_BYTES,
        // The child's stdout is never read, so discarding it outright leaves
        // stderr as the only stream that can reach the buffer bound at all,
        // and stderr is what carries the diagnostic this reports on failure.
        stdio: ['ignore', 'ignore', 'pipe'],
        timeout: SPAWN_TIMEOUT_MS,
      }
    );

    return {ok: true};
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    const status = errorField(error, 'status');

    if (typeof status === 'number')
      return {kind: 'exit', message, ok: false, status};

    const signal = errorField(error, 'signal');

    // A killed child and an interpreter that never launched both arrive with
    // no exit status. Reporting them alike would tell the adopter the spawn
    // never happened when in fact it ran and was cut short, so the signal,
    // which only the killed case carries, is what separates them.
    return typeof signal === 'string' ?
        {
          cause: spawnFailureCause(errorField(error, 'code')),
          kind: 'killed',
          message,
          ok: false,
          signal,
        }
      : {kind: 'spawn', message, ok: false};
  }
};

type OutOfScopeInputs = {
  afterStatus: GitStatus | null;
  beforeStatus: GitStatus | null;
  decl: ParsedDeclaration;
  report: RegenRegionsReport;
  scopeDirs: ReadonlySet<string>;
};

/**
 * Whole-root half of step 5/7: anything git saw appear between the before
 * and after snapshots that isn't a declared path and isn't already inside
 * the (already-swept) snapshot scope is an out-of-scope write with no
 * pre-image, so it is reported rather than reverted. Degrades cleanly (a
 * non-fatal stderr note, no effect on the report or the exit code) when git
 * is unavailable or the root is not a repository.
 */
const reportOutOfScopeWrites = (inputs: OutOfScopeInputs): void => {
  const {afterStatus, beforeStatus, decl, report, scopeDirs} = inputs;

  if (beforeStatus === null || afterStatus === null) {
    structuredError({
      code: 'region_regen_git_delta_unavailable',
      message: `whole-root out-of-scope-write detection skipped for region '${decl.id}': git status is unavailable or the run's root is not a git repository`,
      regionId: decl.id,
      subcommand: 'update regen-regions',
    });

    return;
  }

  const beforeSet = new Set(beforeStatus.inside);
  const declaredSet = new Set(decl.paths);

  afterStatus.inside.forEach((changedPath) => {
    if (
      beforeSet.has(changedPath) ||
      declaredSet.has(changedPath) ||
      isInsideScope(changedPath, scopeDirs)
    )
      return;

    report.confined.push({
      action: 'reported',
      path: changedPath,
      regionId: decl.id,
    });
  });

  const beforeOutside = new Set(beforeStatus.outside);
  const newOutside = afterStatus.outside.filter(
    (changedPath) => !beforeOutside.has(changedPath)
  );

  if (newOutside.length === 0) return;

  // Above the run's own root, so it has no root-relative form and cannot join
  // `confined[]`, whose paths are root-relative by contract. It is still a
  // real write the region made, so it leaves by the same non-fatal channel
  // the git-unavailable case uses rather than being dropped.
  structuredError({
    code: 'region_regen_git_delta_out_of_root',
    message: `region '${decl.id}' changed ${newOutside.length} path(s) above the run's root, reported here because they have no root-relative form: ${newOutside.join(', ')}`,
    regionId: decl.id,
    subcommand: 'update regen-regions',
  });
};

type RegionContext = {
  absentPathSet: ReadonlySet<string>;
  backupDir: string | undefined;
  conflictedSet: ReadonlySet<string>;
  realRoot: string;
  report: RegenRegionsReport;
  root: string;
  seenIds: Set<string>;
  shippedKeys: ReadonlySet<string>;
  skipRegionSet: ReadonlySet<string>;
};

/** Steps 4-8 for one region that passed well-formedness, skip, and operand checks. */
const runRegeneration = (
  decl: ParsedDeclaration,
  commandArgv: string[],
  context: RegionContext
): void => {
  const {backupDir, report, root} = context;

  report.backedUp.push(
    ...performBackup({
      backupDir,
      paths: decl.paths,
      regionId: decl.id,
      root,
    })
  );

  const scopeDirs = scopeDirsFor(decl.paths);
  const before = collectScopeDigests(root, scopeDirs);
  const beforeStatus = gitStatusPaths(root);

  const spawnResult = trySpawn(decl, root);

  const after = collectScopeDigests(root, scopeDirs);

  report.confined.push(
    ...sweepScope({
      after,
      before,
      declaredPaths: decl.paths,
      regionId: decl.id,
      root,
    })
  );

  reportOutOfScopeWrites({
    afterStatus: gitStatusPaths(root),
    beforeStatus,
    decl,
    report,
    scopeDirs,
  });

  if (spawnResult.ok) {
    // Same question the sweep asks, so it takes the same answer. Comparing
    // digests alone called a declared path that is a link unchanged however
    // the spawn repointed it, because neither side has a digest to differ on.
    const rewrote = decl.paths.filter((declPath) => {
      const beforeEntry = before.get(declPath);

      return beforeEntry === undefined ?
          after.has(declPath)
        : !isUntouched(beforeEntry, after.get(declPath));
    });

    report.ran.push({argv: commandArgv, regionId: decl.id, rewrote});
  } else {
    report.failed.push({
      argv: commandArgv,
      cause: spawnResult.kind === 'killed' ? spawnResult.cause : undefined,
      kind: spawnResult.kind,
      message: spawnResult.message,
      regionId: decl.id,
      signal: spawnResult.kind === 'killed' ? spawnResult.signal : undefined,
      status: spawnResult.kind === 'exit' ? spawnResult.status : undefined,
    });
  }
};

/** Steps 1-3 for one `regions[]` entry: well-formedness, skip, operand guard. */
const processRegion = (
  raw: unknown,
  index: number,
  context: RegionContext
): void => {
  const {
    absentPathSet,
    conflictedSet,
    realRoot,
    report,
    root,
    seenIds,
    shippedKeys,
    skipRegionSet,
  } = context;

  const parsedDecl = parseDeclaration(raw, index, seenIds);

  if (!parsedDecl.ok) {
    report.refused.push({
      kind: 'declaration',
      reason: parsedDecl.reason,
      regionId: parsedDecl.regionId,
    });

    return;
  }

  const decl = parsedDecl.declaration;
  // parseDeclaration already recorded decl.id in seenIds as soon as it was
  // confirmed non-empty and unique; nothing further to record here.
  const commandArgv = [decl.interpreter, decl.operand, ...decl.args];

  const skipReason = computeSkipReason(decl, {
    absentPaths: absentPathSet,
    conflicted: conflictedSet,
    skipRegions: skipRegionSet,
  });

  if (skipReason !== undefined) {
    report.skipped.push({
      argv: commandArgv,
      reason: skipReason,
      regionId: decl.id,
    });

    return;
  }

  const operandRefusal = checkOperand(decl, {realRoot, root, shippedKeys});

  if (operandRefusal !== undefined) {
    report.refused.push({
      argv: commandArgv,
      kind: 'operand',
      reason: operandRefusal,
      regionId: decl.id,
    });

    return;
  }

  runRegeneration(decl, commandArgv, context);
};

const resolvePath = (cwd: string, value: string): string =>
  path.isAbsolute(value) ? value : path.join(cwd, value);

type LoadedInputs = {
  backupDir: string | undefined;
  manifestRecord: Record<string, unknown>;
  /** `null` when the manifest is a plain object; else its shape name. */
  manifestShape: null | string;
  realRoot: string;
  root: string;
};

type LoadResult = {ok: false} | {ok: true; value: LoadedInputs};

type RunOptions = {
  cwd?: string;
};

/**
 * Reads and validates `--manifest` and `--root` before any region is
 * processed. Every failure here already wrote its own `structuredError`;
 * the caller only needs to know whether to keep going.
 */
const loadRunInputs = (cwd: string, flags: Flags): LoadResult => {
  const manifestPath = resolvePath(cwd, flags.manifest);
  const root = resolvePath(cwd, flags.root);
  const backupDir =
    flags.backupDir === undefined ?
      undefined
    : resolvePath(cwd, flags.backupDir);

  if (!existsSync(manifestPath)) {
    structuredError({
      code: 'manifest_not_found',
      message: `manifest not found: ${manifestPath}`,
      subcommand: 'update regen-regions',
    });

    return {ok: false};
  }

  let manifestRaw: string;

  try {
    manifestRaw = readFileSync(manifestPath, 'utf8');
  } catch (error) {
    structuredError({
      code: 'manifest_read_failed',
      message: `manifest could not be read (${manifestPath}): ${
        error instanceof Error ? error.message : String(error)
      }`,
      subcommand: 'update regen-regions',
    });

    return {ok: false};
  }

  let manifestParsed: unknown;

  try {
    manifestParsed = JSON.parse(manifestRaw);
  } catch (error) {
    structuredError({
      code: 'manifest_parse_failed',
      message: `manifest is not valid JSON (${manifestPath}): ${
        error instanceof Error ? error.message : String(error)
      }`,
      subcommand: 'update regen-regions',
    });

    return {ok: false};
  }

  if (!existsSync(root)) {
    structuredError({
      code: 'root_not_found',
      message: `root directory not found: ${root}`,
      subcommand: 'update regen-regions',
    });

    return {ok: false};
  }

  let realRoot: string;

  try {
    realRoot = realpathSync(root);
  } catch (error) {
    structuredError({
      code: 'root_unreadable',
      message: `root directory could not be resolved (${root}): ${
        error instanceof Error ? error.message : String(error)
      }`,
      subcommand: 'update regen-regions',
    });

    return {ok: false};
  }

  // Two returns rather than one, so the type guard narrows `manifestParsed`
  // for `manifestRecord` on the arm that keeps it.
  if (isPlainObject(manifestParsed))
    return {
      ok: true,
      value: {
        backupDir,
        manifestRecord: manifestParsed,
        manifestShape: null,
        realRoot,
        root,
      },
    };

  // A manifest that parsed but is not an object has no `regions` key to be
  // wrong-typed, so without a shape name it would reach the caller as an
  // empty record and read exactly like a release predating the mechanism.
  return {
    ok: true,
    value: {
      backupDir,
      manifestRecord: {},
      manifestShape: describeJsonShape(manifestParsed),
      realRoot,
      root,
    },
  };
};

const printHuman = (report: RegenRegionsReport): void => {
  const lines = [
    'gaia update regen-regions',
    `  Ran:       ${report.ran.length}`,
    `  Refused:   ${report.refused.length}`,
    `  Skipped:   ${report.skipped.length}`,
    `  Failed:    ${report.failed.length}`,
    `  Backed up: ${report.backedUp.length}`,
    `  Confined:  ${report.confined.length}`,
  ];

  process.stdout.write(`${lines.join('\n')}\n`);
};

export const run = (
  argv: readonly string[],
  options: RunOptions = {}
): number => {
  if (argv.length > 0 && HELP_TOKENS.has(argv[0])) {
    process.stdout.write(HELP_TEXT);

    return EXIT_CODES.OK;
  }

  const parsed = parseFlags(argv);

  if (!parsed.ok) {
    structuredError({
      code: 'invalid_arguments',
      message: parsed.message,
      subcommand: 'update regen-regions',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const cwd = options.cwd ?? process.cwd();
  const loaded = loadRunInputs(cwd, parsed.flags);

  if (!loaded.ok) return EXIT_CODES.UNKNOWN_SUBCOMMAND;

  const {backupDir, manifestRecord, manifestShape, realRoot, root} =
    loaded.value;
  const regionsValue = manifestRecord.regions;
  const regionsAreArray = Array.isArray(regionsValue);
  const rawRegions = regionsAreArray ? regionsValue : [];
  const filesMap =
    isPlainObject(manifestRecord.files) ? manifestRecord.files : {};
  const shippedKeys = new Set(Object.keys(filesMap));

  const context: RegionContext = {
    absentPathSet: new Set(parsed.flags.absentPaths),
    backupDir,
    conflictedSet: new Set(parsed.flags.conflicted),
    realRoot,
    report: {
      backedUp: [],
      confined: [],
      failed: [],
      ran: [],
      refused: [],
      skipped: [],
    },
    root,
    seenIds: new Set<string>(),
    shippedKeys,
    skipRegionSet: new Set(parsed.flags.skipRegions),
  };

  // An absent `regions` key is the legitimate "this release predates the
  // region mechanism" case, and produces an empty report. A present key of
  // the wrong type is a manifest this command could not read; collapsing it
  // into the same empty report would tell the adopter the release carries no
  // regions, with every downstream region guarantee silently not applying.
  //
  // `(manifest)` names the manifest itself rather than a region: the refusal
  // is run-level, and the parentheses keep it clear of a real declared id,
  // which `parseDeclaration` requires to be a non-empty string.
  //
  // Two shapes reach the same refusal. A manifest that is not an object at
  // all has no `regions` key to inspect, so it is caught by shape; a manifest
  // that is an object carrying a wrong-typed `regions` is caught by the key.
  if (manifestShape !== null)
    context.report.refused.push({
      kind: 'manifest',
      reason: `manifest top level is not an object: ${manifestShape}`,
      regionId: '(manifest)',
    });
  else if (regionsValue !== undefined && !regionsAreArray)
    context.report.refused.push({
      kind: 'manifest',
      reason: `regions is present but is not an array: ${describeJsonShape(regionsValue)}`,
      regionId: '(manifest)',
    });

  rawRegions.forEach((raw, index) => {
    processRegion(raw, index, context);
  });

  if (parsed.flags.json) {
    process.stdout.write(`${JSON.stringify(context.report)}\n`);
  } else {
    printHuman(context.report);
  }

  return EXIT_CODES.OK;
};
