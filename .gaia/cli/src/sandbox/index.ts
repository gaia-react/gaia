/**
 * `gaia sandbox` subcommand router (SPEC-030 tier two: per-machine
 * enablement).
 *
 * `/setup-gaia` (task-setup-gaia-prose) shells these verbs to classify the
 * machine's sandbox capability, resolve the developer's decision, write the
 * real `sandbox.enabled` to the gitignored `.claude/settings.local.json`,
 * seed a minimal starter config, and persist the per-machine resolution
 * marker at `.gaia/local/sandbox.json`. This module owns only the
 * injectable units and their CLI surface; it does not touch any slash
 * command or `setup/util/state-file.ts`'s `SETUP_STEPS`.
 *
 * Object-map dispatch (no `switch`) per the project's typescript skill rules.
 */
import {execFileSync} from 'node:child_process';
import {existsSync, mkdirSync, readFileSync} from 'node:fs';
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import {resolveMainWorktreeRoot} from '../setup/util/state-file.js';
import {structuredError} from '../stderr.js';
import {atomicWriteFileSync} from '../util/atomic-write.js';
import {mergeSandboxSettings} from './apply.js';
import {classifyCapability} from './capability.js';
import type {
  Capability,
  DetectionInput,
  DetectionResult,
  Platform,
  WslKind,
} from './capability.js';
import {readSandboxMarker, writeSandboxMarker} from './marker.js';
import type {SandboxOutcome} from './marker.js';
import {seedSandboxConfig} from './seed.js';
import type {SandboxSettingsFragment} from './seed.js';

const HELP_TEXT = `Usage: gaia sandbox <subcommand> [args]

  detect [--platform <darwin|linux|win32>] [--wsl <none|wsl1|wsl2>]
         [--has-bwrap <true|false>] [--has-socat <true|false>] [--json]
  seed --registry <value> --docker-present <true|false> [--json]
  apply --registry <value> --docker-present <true|false>
        [--settings-path <path>] [--capability <ready|needs-deps|unsupported>]
  record --outcome <enabled|declined|incapable>
         --capability <ready|needs-deps|unsupported>
  status [--json]
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

type RunOptions = {
  cwd?: string;
  now?: () => Date;
};

const failInvalid = (subcommand: string, message: string): number => {
  structuredError({code: 'invalid_arguments', message, subcommand});

  return EXIT_CODES.UNKNOWN_SUBCOMMAND;
};

const takeValue = (
  argv: readonly string[],
  index: number,
  flag: string
): {message: string; ok: false} | {ok: true; value: string} => {
  // `noUncheckedIndexedAccess` is off, so `argv[index]` types as `string`;
  // check the bound explicitly instead of comparing to `undefined`.
  if (index >= argv.length || argv[index].startsWith('--')) {
    return {message: `${flag} requires a value`, ok: false};
  }

  return {ok: true, value: argv[index]};
};

/**
 * Generic `--flag value` tokenizer shared by every verb below (mirrors
 * `ping/index.ts`'s `parseArgvTokens`): collects raw `--flag value` pairs
 * into a map plus a `--json` boolean, with no per-flag-name knowledge. Each
 * verb's `FlagSpec[]` (via `buildFlags`) supplies the actual validation, so
 * this loop stays flat regardless of how many flags a verb accepts.
 */
type TokenizeResult =
  | {json: boolean; ok: true; provided: Map<string, string>}
  | {message: string; ok: false};

const tokenize = (argv: readonly string[]): TokenizeResult => {
  const provided = new Map<string, string>();
  let json = false;

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];

    if (token === '--json') {
      json = true;
    } else {
      const taken = takeValue(argv, index + 1, token);

      if (!taken.ok) return taken;
      provided.set(token, taken.value);
      index += 1;
    }
  }

  return {json, ok: true, provided};
};

type BuildResult =
  {message: string; ok: false} | {ok: true; value: Record<string, FlagValue>};

type FlagSpec = {
  allowed?: readonly string[];
  flag: string;
  key: string;
  kind: 'boolean' | 'enum' | 'string';
  required?: boolean;
};

type FlagValue = boolean | string;

/** Validate + convert the tokenized flags against a verb's `FlagSpec[]`. */
const buildFlags = (
  provided: ReadonlyMap<string, string>,
  specs: readonly FlagSpec[]
): BuildResult => {
  const value: Record<string, FlagValue> = {};

  for (const [flag, raw] of provided) {
    const spec = specs.find((candidate) => candidate.flag === flag);

    if (spec === undefined) {
      return {message: `unknown flag: ${flag}`, ok: false};
    }

    if (spec.kind === 'boolean' && raw !== 'true' && raw !== 'false') {
      return {message: `${flag} must be true or false`, ok: false};
    }

    if (spec.kind === 'enum' && !(spec.allowed ?? []).includes(raw)) {
      return {
        message: `${flag} must be one of: ${(spec.allowed ?? []).join(', ')}`,
        ok: false,
      };
    }

    value[spec.key] = spec.kind === 'boolean' ? raw === 'true' : raw;
  }

  const missing = specs.find(
    (spec) => spec.required === true && !(spec.key in value)
  );

  return missing === undefined ?
      {ok: true, value}
    : {message: `${missing.flag} is required`, ok: false};
};

const PLATFORMS: readonly Platform[] = ['darwin', 'linux', 'win32'];
const WSL_KINDS: readonly WslKind[] = ['none', 'wsl1', 'wsl2'];
const CAPABILITIES: readonly Capability[] = [
  'ready',
  'needs-deps',
  'unsupported',
];
const SANDBOX_OUTCOMES: readonly SandboxOutcome[] = [
  'enabled',
  'declined',
  'incapable',
];

/**
 * Real host probes, used by `detect` for whichever flags are omitted. Kept
 * separate from `classifyCapability` (capability.ts) so that function stays
 * pure and directly unit-testable.
 */
const detectRealPlatform = (): Platform => {
  if (process.platform === 'darwin') return 'darwin';
  if (process.platform === 'win32') return 'win32';

  // Any other process.platform (freebsd, sunos, aix, ...) is treated as
  // linux; GAIA only supports these three developer-machine platforms.
  return 'linux';
};

const detectWsl = (): WslKind => {
  if (process.platform !== 'linux') return 'none';

  let procVersion = '';

  try {
    procVersion = readFileSync('/proc/version', 'utf8').toLowerCase();
  } catch {
    procVersion = '';
  }

  const inWsl =
    procVersion.includes('microsoft') ||
    process.env.WSL_DISTRO_NAME !== undefined;

  if (!inWsl) return 'none';

  // WSL2 runs a real Linux kernel built by Microsoft ("microsoft-standard");
  // WSL1's translation-layer kernel string lacks that "-standard" suffix. If
  // /proc/version couldn't be read but WSL_DISTRO_NAME says we ARE in WSL,
  // default to the more conservative 'wsl1' (unsupported) over assuming the
  // capable case.
  return procVersion.includes('microsoft-standard') ? 'wsl2' : 'wsl1';
};

const commandExists = (binary: 'bwrap' | 'socat'): boolean => {
  try {
    execFileSync('/bin/sh', ['-c', `command -v ${binary}`], {
      stdio: 'ignore',
    });

    return true;
  } catch {
    return false;
  }
};

const DETECT_HELP_TEXT = `Usage: gaia sandbox detect [--platform <darwin|linux|win32>]
       [--wsl <none|wsl1|wsl2>] [--has-bwrap <true|false>]
       [--has-socat <true|false>] [--json]

  Classify this machine's sandbox capability. Any omitted flag falls back to
  a real host probe (process.platform; \`command -v bwrap\`/\`socat\`; WSL
  detection via /proc/version or WSL_DISTRO_NAME).
`;

const DETECT_FLAG_SPECS: readonly FlagSpec[] = [
  {allowed: PLATFORMS, flag: '--platform', key: 'platform', kind: 'enum'},
  {allowed: WSL_KINDS, flag: '--wsl', key: 'wsl', kind: 'enum'},
  {flag: '--has-bwrap', key: 'hasBwrap', kind: 'boolean'},
  {flag: '--has-socat', key: 'hasSocat', kind: 'boolean'},
];

const printDetectResult = (result: DetectionResult, json: boolean): void => {
  if (json) {
    process.stdout.write(`${JSON.stringify(result)}\n`);

    return;
  }

  const lines = [
    `capability: ${result.capability}`,
    `reason: ${result.reason}`,
  ];

  if (result.installCommand !== undefined) {
    lines.push(`install: ${result.installCommand}`);
  }
  process.stdout.write(`${lines.join('\n')}\n`);
};

const runDetect = (argv: readonly string[]): number => {
  if (argv.length > 0 && HELP_TOKENS.has(argv[0])) {
    process.stdout.write(DETECT_HELP_TEXT);

    return EXIT_CODES.OK;
  }

  const tokens = tokenize(argv);

  if (!tokens.ok) return failInvalid('sandbox detect', tokens.message);

  const built = buildFlags(tokens.provided, DETECT_FLAG_SPECS);

  if (!built.ok) return failInvalid('sandbox detect', built.message);

  const input: DetectionInput = {
    hasBwrap:
      (built.value.hasBwrap as boolean | undefined) ?? commandExists('bwrap'),
    hasSocat:
      (built.value.hasSocat as boolean | undefined) ?? commandExists('socat'),
    platform:
      (built.value.platform as Platform | undefined) ?? detectRealPlatform(),
    wsl: (built.value.wsl as undefined | WslKind) ?? detectWsl(),
  };

  printDetectResult(classifyCapability(input), tokens.json);

  return EXIT_CODES.OK;
};

const SEED_HELP_TEXT = `Usage: gaia sandbox seed --registry <value> --docker-present <true|false> [--json]

  Print the minimal sandbox settings fragment for this registry/docker
  combination. --json prints a single-line JSON fragment; otherwise a
  human-readable summary.
`;

const SEED_FLAG_SPECS: readonly FlagSpec[] = [
  {flag: '--registry', key: 'registry', kind: 'string', required: true},
  {
    flag: '--docker-present',
    key: 'dockerPresent',
    kind: 'boolean',
    required: true,
  },
];

const printSeedResult = (
  fragment: SandboxSettingsFragment,
  json: boolean
): void => {
  if (json) {
    process.stdout.write(`${JSON.stringify(fragment)}\n`);

    return;
  }

  const lines = [
    `registry host: ${fragment.sandbox.network.allowedDomains[0]}`,
    `docker excluded: ${fragment.sandbox.excludedCommands === undefined ? 'no' : 'yes'}`,
  ];
  process.stdout.write(`${lines.join('\n')}\n`);
};

const runSeed = (argv: readonly string[]): number => {
  if (argv.length > 0 && HELP_TOKENS.has(argv[0])) {
    process.stdout.write(SEED_HELP_TEXT);

    return EXIT_CODES.OK;
  }

  const tokens = tokenize(argv);

  if (!tokens.ok) return failInvalid('sandbox seed', tokens.message);

  const built = buildFlags(tokens.provided, SEED_FLAG_SPECS);

  if (!built.ok) return failInvalid('sandbox seed', built.message);

  printSeedResult(
    seedSandboxConfig({
      dockerPresent: built.value.dockerPresent as boolean,
      registry: built.value.registry as string,
    }),
    tokens.json
  );

  return EXIT_CODES.OK;
};

const APPLY_HELP_TEXT = `Usage: gaia sandbox apply --registry <value> --docker-present <true|false>
       [--settings-path <path>] [--capability <ready|needs-deps|unsupported>]

  Deep-merge the seed fragment into --settings-path (default
  .claude/settings.local.json; created as {} if absent), verify the path is
  gitignored (warns to stderr if not; never fails on that), then record the
  per-machine marker with outcome 'enabled'.
`;

const APPLY_FLAG_SPECS: readonly FlagSpec[] = [
  {flag: '--registry', key: 'registry', kind: 'string', required: true},
  {
    flag: '--docker-present',
    key: 'dockerPresent',
    kind: 'boolean',
    required: true,
  },
  {flag: '--settings-path', key: 'settingsPath', kind: 'string'},
  {
    allowed: CAPABILITIES,
    flag: '--capability',
    key: 'capability',
    kind: 'enum',
  },
];

const resolveSettingsPath = (
  cwd: string,
  settingsPathArgument: string | undefined
): string => {
  if (settingsPathArgument === undefined) {
    return path.join(cwd, '.claude', 'settings.local.json');
  }

  return path.isAbsolute(settingsPathArgument) ? settingsPathArgument : (
      path.join(cwd, settingsPathArgument)
    );
};

const warnIfNotGitignored = (settingsPath: string, cwd: string): void => {
  try {
    execFileSync('git', ['check-ignore', '-q', settingsPath], {
      cwd,
      stdio: 'ignore',
    });
  } catch {
    // `git check-ignore` exits non-zero both when the path is genuinely not
    // ignored and on unexpected git errors; either way this is a warning,
    // not a failure — `apply` must proceed regardless.
    structuredError({
      code: 'settings_not_gitignored',
      message: `${settingsPath} does not appear to be gitignored`,
      subcommand: 'sandbox apply',
    });
  }
};

const readExistingSettings = (
  settingsPath: string
):
  {message: string; ok: false} | {ok: true; value: Record<string, unknown>} => {
  if (!existsSync(settingsPath)) return {ok: true, value: {}};

  try {
    return {
      ok: true,
      value: JSON.parse(readFileSync(settingsPath, 'utf8')) as Record<
        string,
        unknown
      >,
    };
  } catch (error) {
    return {
      message: `failed to parse ${settingsPath}: ${error instanceof Error ? error.message : String(error)}`,
      ok: false,
    };
  }
};

const runApply = (
  argv: readonly string[],
  options: RunOptions = {}
): number => {
  if (argv.length > 0 && HELP_TOKENS.has(argv[0])) {
    process.stdout.write(APPLY_HELP_TEXT);

    return EXIT_CODES.OK;
  }

  const tokens = tokenize(argv);

  if (!tokens.ok) return failInvalid('sandbox apply', tokens.message);

  const built = buildFlags(tokens.provided, APPLY_FLAG_SPECS);

  if (!built.ok) return failInvalid('sandbox apply', built.message);

  const registry = built.value.registry as string;
  const dockerPresent = built.value.dockerPresent as boolean;
  const capability =
    (built.value.capability as Capability | undefined) ?? 'ready';
  const cwd = options.cwd ?? process.cwd();
  const settingsPath = resolveSettingsPath(
    cwd,
    built.value.settingsPath as string | undefined
  );

  const existing = readExistingSettings(settingsPath);

  if (!existing.ok) return failInvalid('sandbox apply', existing.message);

  const merged = mergeSandboxSettings(
    existing.value,
    seedSandboxConfig({dockerPresent, registry})
  );
  const parent = path.dirname(settingsPath);

  if (!existsSync(parent)) {
    mkdirSync(parent, {mode: 0o755, recursive: true});
  }

  atomicWriteFileSync(settingsPath, `${JSON.stringify(merged, null, 2)}\n`, {
    mode: 0o644,
  });
  warnIfNotGitignored(settingsPath, cwd);

  let repoRoot: string;

  try {
    repoRoot = resolveMainWorktreeRoot(cwd);
  } catch {
    structuredError({
      code: 'not_a_git_repo',
      message: 'gaia sandbox apply must run inside a git repository',
      subcommand: 'sandbox apply',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const nowDate = (options.now ?? (() => new Date()))();
  writeSandboxMarker(repoRoot, {
    capability,
    outcome: 'enabled',
    resolved_at: nowDate.toISOString(),
    version: 1,
  });

  process.stdout.write(
    `${JSON.stringify({code: 'sandbox_applied', settings_path: settingsPath})}\n`
  );

  return EXIT_CODES.OK;
};

const RECORD_HELP_TEXT = `Usage: gaia sandbox record --outcome <enabled|declined|incapable>
       --capability <ready|needs-deps|unsupported>

  Write the per-machine marker only (no settings file write). Used for the
  declined/incapable outcomes; 'enabled' is normally recorded by \`apply\`.
`;

const RECORD_FLAG_SPECS: readonly FlagSpec[] = [
  {
    allowed: SANDBOX_OUTCOMES,
    flag: '--outcome',
    key: 'outcome',
    kind: 'enum',
    required: true,
  },
  {
    allowed: CAPABILITIES,
    flag: '--capability',
    key: 'capability',
    kind: 'enum',
    required: true,
  },
];

const runRecord = (
  argv: readonly string[],
  options: RunOptions = {}
): number => {
  if (argv.length > 0 && HELP_TOKENS.has(argv[0])) {
    process.stdout.write(RECORD_HELP_TEXT);

    return EXIT_CODES.OK;
  }

  const tokens = tokenize(argv);

  if (!tokens.ok) return failInvalid('sandbox record', tokens.message);

  const built = buildFlags(tokens.provided, RECORD_FLAG_SPECS);

  if (!built.ok) return failInvalid('sandbox record', built.message);

  const outcome = built.value.outcome as SandboxOutcome;
  const capability = built.value.capability as Capability;

  let repoRoot: string;

  try {
    repoRoot = resolveMainWorktreeRoot(options.cwd ?? process.cwd());
  } catch {
    structuredError({
      code: 'not_a_git_repo',
      message: 'gaia sandbox record must run inside a git repository',
      subcommand: 'sandbox record',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const nowDate = (options.now ?? (() => new Date()))();
  writeSandboxMarker(repoRoot, {
    capability,
    outcome,
    resolved_at: nowDate.toISOString(),
    version: 1,
  });

  process.stdout.write(
    `${JSON.stringify({capability, code: 'sandbox_recorded', outcome})}\n`
  );

  return EXIT_CODES.OK;
};

type StatusOutput = {
  capability?: Capability;
  outcome?: SandboxOutcome;
  resolved: boolean;
  resolved_at?: string;
};

const STATUS_HELP_TEXT = `Usage: gaia sandbox status [--json]

  Print the per-machine sandbox resolution marker. {resolved: false} when no
  decision has been recorded yet.
`;

const printStatusHuman = (output: StatusOutput): void => {
  if (!output.resolved) {
    process.stdout.write('No sandbox decision recorded yet.\n');

    return;
  }

  process.stdout.write(
    `outcome: ${String(output.outcome)}\n` +
      `capability: ${String(output.capability)}\n` +
      `resolved_at: ${String(output.resolved_at)}\n`
  );
};

const runStatus = (
  argv: readonly string[],
  options: RunOptions = {}
): number => {
  if (argv.length > 0 && HELP_TOKENS.has(argv[0])) {
    process.stdout.write(STATUS_HELP_TEXT);

    return EXIT_CODES.OK;
  }

  const tokens = tokenize(argv);

  if (!tokens.ok) return failInvalid('sandbox status', tokens.message);

  const built = buildFlags(tokens.provided, []);

  if (!built.ok) return failInvalid('sandbox status', built.message);

  let repoRoot: string;

  try {
    repoRoot = resolveMainWorktreeRoot(options.cwd ?? process.cwd());
  } catch {
    structuredError({
      code: 'not_a_git_repo',
      message: 'gaia sandbox status must run inside a git repository',
      subcommand: 'sandbox status',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  let marker;

  try {
    marker = readSandboxMarker(repoRoot);
  } catch (error) {
    structuredError({
      code: 'marker_malformed',
      message: error instanceof Error ? error.message : String(error),
      subcommand: 'sandbox status',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const output: StatusOutput =
    marker === null ?
      {resolved: false}
    : {
        capability: marker.capability,
        outcome: marker.outcome,
        resolved: true,
        resolved_at: marker.resolved_at,
      };

  if (tokens.json) {
    process.stdout.write(`${JSON.stringify(output)}\n`);
  } else {
    printStatusHuman(output);
  }

  return EXIT_CODES.OK;
};

type Handler = (argv: readonly string[], options: RunOptions) => number;

const SUBCOMMAND_HANDLERS: Readonly<Partial<Record<string, Handler>>> = {
  apply: runApply,
  detect: runDetect,
  record: runRecord,
  seed: runSeed,
  status: runStatus,
};

export const run = (
  argv: readonly string[],
  options: RunOptions = {}
): number => {
  const subcommand = argv[0] as string | undefined;
  const rest = argv.slice(1);

  if (subcommand === undefined || HELP_TOKENS.has(subcommand)) {
    process.stdout.write(HELP_TEXT);

    return EXIT_CODES.OK;
  }

  const handler = SUBCOMMAND_HANDLERS[subcommand];

  if (handler === undefined) {
    structuredError({
      code: 'unknown_subcommand',
      subcommand: `sandbox ${subcommand}`,
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  return handler(rest, options);
};
