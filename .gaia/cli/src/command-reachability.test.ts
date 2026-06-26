/**
 * Maintainer reachability-guard for the CLI subcommand surface.
 *
 * `knip` cannot see this class of deadness. A subcommand is statically
 * reachable through its router's `SUBCOMMAND_HANDLERS` object map, so
 * import-graph analysis always marks it live. The deadness lives one layer
 * lower, at runtime string dispatch: nothing ever passes the argv that
 * selects the command. `gaia update merge` sat dead ~18 days exactly this
 * way, the `/update-gaia` skill stopped routing it but the handler, its
 * help line, and its own test kept it import-reachable.
 *
 * This guard enumerates every `SUBCOMMAND_HANDLERS` leaf command across the
 * two binary entrypoints and the domain routers, then asserts each one is
 * reachable from at least one EXTERNAL invoker: an invocation-shaped string
 * (`gaia <path>` / `gaia-maintainer <path>`) in a skill, command, hook,
 * agent, CI workflow (committed or bundled template), or wiki page. A
 * command's own router (its help text) and its own test are never in the
 * haystack, so they cannot vouch for it. Commands that are invoker-less by
 * design or pending triage are listed in `INTERNAL_COMMANDS` with a reason.
 *
 * Maintainer-only by construction: `.gaia/cli/src` is release-excluded, so
 * adopters carry neither these routers nor this test. On any clone where the
 * routers are absent the suite skips, mirroring the audit-template dogfood
 * guard.
 *
 * Scope boundary (v1): only `SUBCOMMAND_HANDLERS`-dispatched commands. The
 * `if (subcommand === '...')` routers (`mentorship`, `telemetry`, `scaffold`)
 * use a different dispatch shape and are out of scope. The oracle is a
 * substring match, so an invocation-shaped string in operator-facing prose
 * (e.g. a recovery hint in a CI PR body) counts as reachable; that is the
 * intended floor, the target is the command referenced by nothing at all.
 */
import {existsSync, readdirSync, readFileSync, statSync} from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {describe, expect, it} from 'vitest';

// Subcommands reachable only through their router with no external invoker,
// allowed on purpose. Each entry needs a reason. Wiring or retiring a command
// here makes the "no stale entries" test fail until the entry is removed.
const INTERNAL_COMMANDS: ReadonlyMap<string, string> = new Map();

// Directories under the repo root scanned for invocation strings. None of
// these contain a router or a test file, so a command can never vouch for
// itself. `.gaia/cli/src/automation/templates` holds the bundled CI workflow
// templates that render into an adopter's `.github/`, the real home of the
// `automation` and `wiki diff-size` invocations.
//
// Completeness of this list is the guard's single point of rot. If the
// "every leaf has an external invoker" test goes red on a command you know
// is live, the fix is almost always a missing surface here (a new invoker
// location, a new binary, a new invocation prefix), NOT an INTERNAL_COMMANDS
// entry. Allowlisting a live command silently stops the guard watching it.
const INVOKER_SURFACES: readonly string[] = [
  '.claude/skills',
  '.claude/commands',
  '.claude/hooks',
  '.claude/agents',
  '.github',
  'wiki',
  '.gaia/cli/src/automation/templates',
];

const TEXT_EXTENSIONS = new Set([
  '.md',
  '.markdown',
  '.ts',
  '.tsx',
  '.js',
  '.mjs',
  '.cjs',
  '.sh',
  '.yml',
  '.yaml',
  '.tmpl',
  '.json',
  '.txt',
]);

const resolveRepoRoot = (): string => {
  // Walk up from this file's location to the repo root (contains .git).
  let dir = path.dirname(fileURLToPath(import.meta.url));

  for (let attempts = 0; attempts < 20; attempts += 1) {
    if (existsSync(path.join(dir, '.git'))) {
      return dir;
    }
    const parent = path.dirname(dir);

    if (parent === dir) break;
    dir = parent;
  }

  throw new Error('Could not find repo root (no .git directory found)');
};

const escapeRegExp = (value: string): string =>
  value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

// The keys of a router's `SUBCOMMAND_HANDLERS` map. Every handler value is a
// `run<Pascal>` symbol, so anchoring on `: run[A-Z]` selects exactly the
// command keys and skips the `code:` / `message:` / `subcommand:` lines of the
// router's `structuredError` fallback.
const extractHandlerKeys = (source: string): string[] => {
  const start = source.indexOf('const SUBCOMMAND_HANDLERS');

  if (start === -1) return [];

  const endRel = source.slice(start).indexOf('\n};');
  const body =
    endRel === -1 ? source.slice(start) : source.slice(start, start + endRel);

  const keys: string[] = [];

  for (const match of body.matchAll(
    /^\s*'?([a-z][a-z0-9-]*)'?\s*:\s*run[A-Z]/gm
  )) {
    keys.push(match[1]);
  }

  return keys;
};

// Full invocation paths for every map-dispatched leaf command. Domain routers
// (`src/<domain>/index.ts` declaring the map) contribute `<domain> <key>`.
// The two entrypoints contribute their keys that have no same-named sub-router
// directory, the genuinely top-level commands (ci-revert, harden-tally, ...).
const enumerateLeafCommands = (cliSrc: string): string[] => {
  const hasIndex = (name: string): boolean =>
    existsSync(path.join(cliSrc, name, 'index.ts'));

  const domainDirs = readdirSync(cliSrc, {withFileTypes: true})
    .filter((entry) => entry.isDirectory() && hasIndex(entry.name))
    .map((entry) => entry.name)
    .filter((name) =>
      readFileSync(path.join(cliSrc, name, 'index.ts'), 'utf8').includes(
        'const SUBCOMMAND_HANDLERS'
      )
    );

  const leaves = new Set<string>();

  for (const domain of domainDirs) {
    const source = readFileSync(path.join(cliSrc, domain, 'index.ts'), 'utf8');

    for (const key of extractHandlerKeys(source)) {
      leaves.add(`${domain} ${key}`);
    }
  }

  for (const entrypoint of ['index.ts', 'index.maintainer.ts']) {
    const source = readFileSync(path.join(cliSrc, entrypoint), 'utf8');

    for (const key of extractHandlerKeys(source)) {
      if (!hasIndex(key)) leaves.add(key);
    }
  }

  return [...leaves].sort();
};

const collectText = (absDir: string): string => {
  if (!existsSync(absDir)) return '';

  let entries: string[];

  try {
    entries = readdirSync(absDir, {recursive: true}) as string[];
  } catch {
    return '';
  }

  const parts: string[] = [];

  for (const rel of entries) {
    if (!TEXT_EXTENSIONS.has(path.extname(rel).toLowerCase())) continue;

    const abs = path.join(absDir, rel);

    try {
      if (statSync(abs).isFile()) parts.push(readFileSync(abs, 'utf8'));
    } catch {
      // Unreadable entry (e.g. a dangling symlink); skip it.
    }
  }

  return parts.join('\n');
};

const repoRoot = resolveRepoRoot();
const cliSrc = path.join(repoRoot, '.gaia', 'cli', 'src');
const routersPresent = existsSync(cliSrc);

const leafCommands = routersPresent ? enumerateLeafCommands(cliSrc) : [];
const invokerText = routersPresent
  ? INVOKER_SURFACES.map((surface) =>
      collectText(path.join(repoRoot, surface))
    ).join('\n')
  : '';

// A command is reachable when an invocation-shaped string for it exists in the
// invoker text: the binary name, then the space-separated path, bounded so
// `wiki state` never matches inside `wiki state-bump`.
const isReachable = (commandPath: string): boolean => {
  const tokens = commandPath.split(' ').map(escapeRegExp).join('\\s+');

  return new RegExp(
    `(?<![\\w-])gaia(?:-maintainer)?\\s+${tokens}(?![\\w-])`
  ).test(invokerText);
};

describe('CLI subcommand reachability guard', () => {
  it('enumerates the command surface (guards against parser rot)', () => {
    if (!routersPresent) return;

    // A silent enumerator would make the reachability test pass vacuously.
    // Pin a few known leaves and a floor count so parser drift fails loudly.
    expect(leafCommands).toContain('update merge-workspace');
    expect(leafCommands).toContain('wiki orphans');
    expect(leafCommands).toContain('release bump');
    expect(leafCommands).toContain('harden-tally');
    expect(leafCommands.length).toBeGreaterThanOrEqual(40);

    // The oracle must be able to return false, else everything looks reachable.
    expect(isReachable('zzz fabricated-command')).toBe(false);
  });

  it('every map-dispatched leaf command has an external invoker', () => {
    if (!routersPresent) return;

    const dead = leafCommands.filter(
      (command) => !INTERNAL_COMMANDS.has(command) && !isReachable(command)
    );

    expect(
      dead,
      `These CLI subcommands are wired into a SUBCOMMAND_HANDLERS map but ` +
        `invoked by nothing (no skill / command / hook / agent / workflow / ` +
        `bundled template / wiki string). Wire an invoker, retire the ` +
        `command, or add it to INTERNAL_COMMANDS with a reason:\n  ${dead.join(
          '\n  '
        )}`
    ).toEqual([]);
  });

  it('the internal-command allowlist has no stale entries', () => {
    if (!routersPresent) return;

    const leafSet = new Set(leafCommands);

    // An allowlisted command that was retired (no longer a leaf) or that has
    // since gained an invoker must drop out of the allowlist.
    const stale = [...INTERNAL_COMMANDS.keys()].filter(
      (command) => !leafSet.has(command) || isReachable(command)
    );

    expect(
      stale,
      `Remove these stale INTERNAL_COMMANDS entries (command retired or now ` +
        `has an external invoker):\n  ${stale.join('\n  ')}`
    ).toEqual([]);
  });
});
