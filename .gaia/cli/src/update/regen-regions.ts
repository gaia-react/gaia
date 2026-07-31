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
 * every file under the union of the declared paths' parent directories
 * (the "snapshot scope"); after the spawn, anything in scope that is not one
 * of the region's declared paths and no longer matches its pre-image is put
 * back, whether the spawn rewrote it or deleted it, and anything in scope the
 * spawn newly created is removed. A `git status --porcelain -z` before/after
 * pair also catches a write anywhere else in the tree; that has no pre-image
 * to restore from, so it is only reported, never reverted. The spawn never
 * runs through a shell and never takes a shell-interpreted string: it is
 * always a fixed argv array, and it is bounded in both output and runtime.
 *
 * Exit codes: 0 for every refusal, skip, spawn failure, or non-zero program
 * exit; 1 only when the flags or `--manifest` itself are unusable.
 */
import {execFileSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {
  copyFileSync,
  existsSync,
  lstatSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  realpathSync,
  rmSync,
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
  or reported (anywhere else); never silently kept.

  Read the manifest's regions from a RELEASE copy, never the adopter's stale
  working-tree copy: pass $LATEST_DIR/.gaia/manifest.json as --manifest.

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

type Snapshot = ReadonlyMap<string, SnapshotEntry>;
type SnapshotEntry = {content: Buffer; digest: string};

/**
 * Step 5 / re-used for step 7-8: SHA-256 (plus raw content, for restoring)
 * of every existing file under the region's declared paths' parent
 * directories, recursively. Keys are repo-relative, POSIX-separated.
 */
const collectScopeDigests = (
  root: string,
  scopeDirs: ReadonlySet<string>
): Snapshot => {
  const digests = new Map<string, SnapshotEntry>();

  scopeDirs.forEach((dir) => {
    const absDir = path.resolve(root, dir);

    if (!existsSync(absDir)) return;

    let entries: string[];

    try {
      entries = readdirSync(absDir, {recursive: true}) as string[];
    } catch {
      return;
    }

    entries.forEach((rel) => {
      const abs = path.join(absDir, rel);
      let stat;

      try {
        // `lstat`, not `stat`: a symlink must not be followed here. The
        // snapshot's whole contract is content it can hash and later write
        // back, and a symlink is neither. Followed, it would be buffered as
        // its TARGET's bytes, and the sweep would then restore it as a plain
        // regular file holding a copy of content that may have lived wholly
        // outside the region, or write through the link and rewrite a target
        // outside the snapshot scope entirely. Excluding it makes the sweep
        // make no claim about symlinks rather than a false one.
        stat = lstatSync(abs);
      } catch {
        return;
      }

      if (!stat.isFile()) return;

      const repoRelative = path.relative(root, abs).split(path.sep).join('/');
      let content;

      try {
        content = readFileSync(abs);
      } catch {
        // Unreadable file (permissions, a race with the spawn): skip it, the
        // same way an unstattable entry is skipped above. Throwing here would
        // abandon the confinement sweep and the report for every remaining
        // region, which is the one outcome this command promises never to
        // produce.
        return;
      }

      digests.set(repoRelative, {
        content,
        digest: createHash('sha256').update(content).digest('hex'),
      });
    });
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
 * is restored to it, whether the spawn rewrote it or deleted it; a file the
 * spawn created has no pre-image, so it is removed instead. That is the
 * confinement guarantee as stated: reverted when a pre-image exists,
 * reported when it does not.
 */
const sweepScope = (inputs: SweepInputs): ConfinedEntry[] => {
  const {after, before, declaredPaths, regionId, root} = inputs;
  const declaredSet = new Set(declaredPaths);
  const confined: ConfinedEntry[] = [];

  before.forEach((beforeEntry, relPath) => {
    if (declaredSet.has(relPath)) return;

    // Untouched: nothing to undo. Anything else is an out-of-scope write with
    // a pre-image, and a deletion is one of those: it is absent from `after`
    // rather than merely different, so the optional chain yields `undefined`,
    // which no digest equals. Either way the content to put back is the same
    // `before` entry.
    if (after.get(relPath)?.digest === beforeEntry.digest) return;

    try {
      const abs = path.resolve(root, relPath);

      // A deletion may have taken the parent directory with it.
      mkdirSync(path.dirname(abs), {recursive: true});
      writeFileSync(abs, beforeEntry.content);
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

  [...after.keys()].forEach((relPath) => {
    if (declaredSet.has(relPath) || before.has(relPath)) return;

    try {
      rmSync(path.resolve(root, relPath), {force: true});
      confined.push({action: 'removed', path: relPath, regionId});
    } catch {
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
 */
const gitStatusPaths = (root: string): null | string[] => {
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

    return paths;
  } catch {
    return null;
  }
};

type SpawnOutcome =
  | {kind: 'exit'; message: string; ok: false; status: number}
  | {kind: 'killed'; message: string; ok: false; signal: string}
  | {kind: 'spawn'; message: string; ok: false}
  | {ok: true};

/** Reads one field off a thrown value without asserting its shape. */
const errorField = (error: unknown, key: string): unknown =>
  isPlainObject(error) ? error[key] : undefined;

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
        {kind: 'killed', message, ok: false, signal}
      : {kind: 'spawn', message, ok: false};
  }
};

type OutOfScopeInputs = {
  afterStatus: null | string[];
  beforeStatus: null | string[];
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

  const beforeSet = new Set(beforeStatus);
  const declaredSet = new Set(decl.paths);

  afterStatus.forEach((changedPath) => {
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
    const rewrote = decl.paths.filter(
      (declPath) => before.get(declPath)?.digest !== after.get(declPath)?.digest
    );

    report.ran.push({argv: commandArgv, regionId: decl.id, rewrote});
  } else {
    report.failed.push({
      argv: commandArgv,
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
