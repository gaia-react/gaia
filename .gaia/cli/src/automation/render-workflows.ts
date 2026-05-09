/**
 * `gaia automation render-workflows --out-dir <path> [--tools <csv>] [--dry-run]`
 *
 * Reads `.gaia/automation.json`, renders one workflow YAML per CI-mode
 * tool via the Phase 1 engine + Phase 2 templates, and writes the files
 * to the caller-supplied `--out-dir`. Slice 4's `/setup-gaia-ci` calls
 * this with `--out-dir .github/workflows`.
 */
import {mkdirSync, writeFileSync} from 'node:fs';
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import {
  TOOL_IDS,
  TOOL_ID_TO_CONFIG_KEY,
  readAutomationConfig,
  type ToolId,
} from '../schemas/automation-config.js';
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

const parseTools = (raw: string): readonly ToolId[] | string => {
  const parts = raw.split(',').map((part) => part.trim()).filter(Boolean);

  if (parts.length === 0) {
    return '--tools requires at least one tool';
  }

  const known = new Set<string>(TOOL_IDS);
  const bad = parts.filter((part) => !known.has(part));

  if (bad.length > 0) {
    return `--tools entries must be a subset of ${TOOL_IDS.join(', ')}; got: ${bad.join(', ')}`;
  }

  return parts as readonly ToolId[];
};

const parseArgs = (
  argv: readonly string[]
): ParsedArgs | {error: string} => {
  let outDir: string | undefined;
  let dryRun = false;
  let tools: readonly ToolId[] = TOOL_IDS;
  let configPath: string | undefined;

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index] as string;

    if (token === '--out-dir') {
      const next = argv[index + 1];

      if (next === undefined || next.startsWith('--')) {
        return {error: '--out-dir requires a path argument'};
      }
      outDir = next;
      index += 1;

      continue;
    }

    if (token === '--tools') {
      const next = argv[index + 1];

      if (next === undefined || next.startsWith('--')) {
        return {error: '--tools requires a comma-separated tool list'};
      }
      const parsed = parseTools(next);

      if (typeof parsed === 'string') return {error: parsed};
      tools = parsed;
      index += 1;

      continue;
    }

    if (token === '--config') {
      const next = argv[index + 1];

      if (next === undefined || next.startsWith('--')) {
        return {error: '--config requires a path argument'};
      }
      configPath = next;
      index += 1;

      continue;
    }

    if (token === '--dry-run') {
      dryRun = true;

      continue;
    }

    return {error: `unexpected argument: ${token}`};
  }

  if (outDir === undefined) {
    return {error: '--out-dir is required'};
  }

  return {configPath, dryRun, outDir, tools};
};

type RunOptions = {
  cwd?: string;
};

export const run = (
  argv: readonly string[],
  options: RunOptions = {}
): number => {
  if (argv.length === 0 || HELP_TOKENS.has(argv[0] as string)) {
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
    const vars = buildWorkflowVars(configResult.config, tool);

    if (vars === null) {
      const toolConfig = configResult.config[TOOL_ID_TO_CONFIG_KEY[tool]] as {
        mode: string;
      };
      process.stderr.write(`${tool}: skipped (mode=${toolConfig.mode})\n`);

      continue;
    }

    const rendered = renderWorkflowTemplate(
      workflowTemplatePath(tool),
      partialsDir,
      vars
    );

    const outPath = path.join(parsed.outDir, `gaia-ci-${tool}.yml`);

    if (parsed.dryRun) {
      process.stdout.write(
        `${tool}: ${String(rendered.length)} bytes -> ${outPath}\n`
      );

      continue;
    }

    writeFileSync(outPath, rendered, 'utf8');
    process.stdout.write(`wrote ${outPath}\n`);
  }

  return EXIT_CODES.OK;
};
