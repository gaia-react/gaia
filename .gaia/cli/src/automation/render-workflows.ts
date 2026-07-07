/**
 * `gaia automation render-workflows --out-dir <path> [--tools <csv>] [--dry-run]`
 *
 * Reads `.gaia/automation.json`, renders one workflow YAML per CI-mode
 * tool via the Phase 1 engine + Phase 2 templates, and writes the files
 * to the caller-supplied `--out-dir`. Slice 4's `/setup-gaia` calls
 * this with `--out-dir .github/workflows`.
 */
import {mkdirSync, writeFileSync} from 'node:fs';
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import {
  readAutomationConfig,
  TOOL_ID_TO_CONFIG_KEY,
  TOOL_IDS,
} from '../schemas/automation-config.js';
import type {AutomationConfig, ToolId} from '../schemas/automation-config.js';
import {structuredError} from '../stderr.js';
import {resolveRepoRoot} from '../wiki/util/git.js';
import {workflowPartialsDirectory, workflowTemplatePath} from './paths.js';
import {renderWorkflowTemplate} from './render.js';
import {buildWorkflowVars} from './workflow-vars.js';

const HELP_TEXT = `Usage: gaia automation render-workflows --out-dir <path> [--tools <csv>] [--dry-run]

  Renders one workflow YAML per CI-mode tool from .gaia/automation.json.

  --out-dir <path>     Required. Where to write the rendered files.
                       Created with mkdir -p semantics if missing.
  --tools <csv>        Optional. Comma-separated subset of:
                       ${TOOL_IDS.join(', ')}. Defaults to all four.
  --dry-run            Optional. Print what would be written; do not
                       touch the filesystem.
  --config <path>      Reserved. Override of .gaia/automation.json
                       location (not yet wired in v1).
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

type ParsedArgs = {
  configPath?: string;
  dryRun: boolean;
  outDir: string;
  tools: readonly ToolId[];
};

type ParseToolsResult = {error: string} | {tools: readonly ToolId[]};

const parseTools = (raw: string): ParseToolsResult => {
  const parts = raw.split(',').flatMap((part) => {
    const trimmed = part.trim();

    return trimmed ? [trimmed] : [];
  });

  if (parts.length === 0) {
    return {error: '--tools requires at least one tool'};
  }

  const known = new Set<string>(TOOL_IDS);
  const bad = parts.filter((part) => !known.has(part));

  if (bad.length > 0) {
    return {
      error: `--tools entries must be a subset of ${TOOL_IDS.join(', ')}; got: ${bad.join(', ')}`,
    };
  }

  return {tools: parts as readonly ToolId[]};
};

type FlagValueResult = {error: string} | {value: string};

// `noUncheckedIndexedAccess` is off, so TS types `argv[index + 1]` as
// `string`, not `string | undefined`; check the bound explicitly instead of
// comparing the indexed value to `undefined`.
const readFlagValue = (
  argv: readonly string[],
  index: number,
  errorMessage: string
): FlagValueResult => {
  if (index + 1 >= argv.length || argv[index + 1].startsWith('--')) {
    return {error: errorMessage};
  }

  return {value: argv[index + 1]};
};

type ParseState = {
  configPath: string | undefined;
  dryRun: boolean;
  outDir: string | undefined;
  tools: readonly ToolId[];
};

type TokenOutcome = {error: string} | {indexDelta: number};

// One flat `if...return` per flag (no `else if` chain) keeps this shallow:
// each branch is a sibling, not nested inside the previous one.
const applyToken = (
  argv: readonly string[],
  index: number,
  state: ParseState
): TokenOutcome => {
  const token = argv[index];

  if (token === '--out-dir') {
    const next = readFlagValue(
      argv,
      index,
      '--out-dir requires a path argument'
    );

    if ('error' in next) return next;
    state.outDir = next.value;

    return {indexDelta: 1};
  }

  if (token === '--tools') {
    const next = readFlagValue(
      argv,
      index,
      '--tools requires a comma-separated tool list'
    );

    if ('error' in next) return next;
    const parsedTools = parseTools(next.value);

    if ('error' in parsedTools) return parsedTools;
    state.tools = parsedTools.tools;

    return {indexDelta: 1};
  }

  if (token === '--config') {
    const next = readFlagValue(
      argv,
      index,
      '--config requires a path argument'
    );

    if ('error' in next) return next;
    state.configPath = next.value;

    return {indexDelta: 1};
  }

  if (token === '--dry-run') {
    state.dryRun = true;

    return {indexDelta: 0};
  }

  return {error: `unexpected argument: ${token}`};
};

const parseArgs = (argv: readonly string[]): ParsedArgs | {error: string} => {
  const state: ParseState = {
    configPath: undefined,
    dryRun: false,
    outDir: undefined,
    tools: TOOL_IDS,
  };

  for (let index = 0; index < argv.length; index += 1) {
    const outcome = applyToken(argv, index, state);

    if ('error' in outcome) return outcome;
    index += outcome.indexDelta;
  }

  if (state.outDir === undefined) {
    return {error: '--out-dir is required'};
  }

  return {
    configPath: state.configPath,
    dryRun: state.dryRun,
    outDir: state.outDir,
    tools: state.tools,
  };
};

type RenderOneToolOptions = {
  config: AutomationConfig;
  dryRun: boolean;
  outDir: string;
  partialsDir: string;
  tool: ToolId;
};

// Extracted so the loop in `run` is a single flat call: each early `return`
// here plays the role `continue` would in the loop, without adding nesting.
const renderOneTool = (options: RenderOneToolOptions): void => {
  const {config, dryRun, outDir, partialsDir, tool} = options;
  const vars = buildWorkflowVars(config, tool);

  if (vars === null) {
    const toolConfig = config[TOOL_ID_TO_CONFIG_KEY[tool]] as {mode: string};
    process.stderr.write(`${tool}: skipped (mode=${toolConfig.mode})\n`);

    return;
  }

  const rendered = renderWorkflowTemplate(
    workflowTemplatePath(tool),
    partialsDir,
    vars
  );

  const outPath = path.join(outDir, `gaia-ci-${tool}.yml`);

  if (dryRun) {
    process.stdout.write(
      `${tool}: ${String(rendered.length)} bytes -> ${outPath}\n`
    );

    return;
  }

  writeFileSync(outPath, rendered, 'utf8');
  process.stdout.write(`wrote ${outPath}\n`);
};

type RunOptions = {
  cwd?: string;
};

export const run = (
  argv: readonly string[],
  options: RunOptions = {}
): number => {
  if (argv.length === 0 || HELP_TOKENS.has(argv[0])) {
    process.stdout.write(HELP_TEXT);

    return argv.length === 0 ? EXIT_CODES.UNKNOWN_SUBCOMMAND : EXIT_CODES.OK;
  }

  const parsed = parseArgs(argv);

  if ('error' in parsed) {
    structuredError({
      code: 'invalid_arguments',
      message: parsed.error,
      subcommand: 'automation render-workflows',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  let repoRoot: string;

  try {
    repoRoot = resolveRepoRoot(options.cwd ?? process.cwd());
  } catch {
    structuredError({
      code: 'not_a_git_repo',
      message:
        'gaia automation render-workflows must run inside a git repository',
      subcommand: 'automation render-workflows',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const configResult = readAutomationConfig(repoRoot);

  if (configResult.status === 'missing') {
    structuredError({
      code: 'config_missing',
      message: `.gaia/automation.json not found under ${repoRoot}`,
      path: '.gaia/automation.json',
      subcommand: 'automation render-workflows',
    });

    return EXIT_CODES.CONFIG_INVALID;
  }

  if (configResult.status === 'malformed') {
    structuredError({
      code: 'config_malformed',
      error: configResult.error,
      subcommand: 'automation render-workflows',
    });

    return EXIT_CODES.CONFIG_INVALID;
  }

  const partialsDir = workflowPartialsDirectory();

  if (!parsed.dryRun) {
    mkdirSync(parsed.outDir, {recursive: true});
  }

  for (const tool of parsed.tools) {
    renderOneTool({
      config: configResult.config,
      dryRun: parsed.dryRun,
      outDir: parsed.outDir,
      partialsDir,
      tool,
    });
  }

  return EXIT_CODES.OK;
};
