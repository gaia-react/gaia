/**
 * `gaia setup-ci check-drift [--workflows-dir <path>] [--json]` handler.
 *
 * Compares the rendered `.github/workflows/gaia-ci-<tool>.yml` files
 * against a fresh in-memory render of the current templates and
 * `.gaia/automation.json`. The `/setup-gaia` slash command calls
 * this between the `status` probe and the idempotent short-circuit
 * to decide whether to offer the adopter a re-render path.
 *
 * Authoritative: any change to the bundled templates, the partials,
 * the `automation.json`, or the workflow-vars layer is detected by
 * byte-comparing the new render with the on-disk YAML.
 *
 * JSON shape (the canonical contract):
 *
 *   {
 *     "drifted": ToolId[],
 *     "in_sync": ToolId[],
 *     "missing": ToolId[]
 *   }
 *
 * - `drifted`: rendered file exists and bytes differ from a fresh render.
 * - `missing`: tool is enabled (mode=ci) but the workflow file is absent.
 * - `in_sync`: rendered bytes match a fresh render.
 *
 * Tools whose `mode !== 'ci'` are absent from all three arrays.
 */
import {readFileSync} from 'node:fs';
import path from 'node:path';
import {
  workflowPartialsDirectory,
  workflowTemplatePath,
} from '../automation/paths.js';
import {renderWorkflowTemplate} from '../automation/render.js';
import {buildWorkflowVars} from '../automation/workflow-vars.js';
import {EXIT_CODES} from '../exit.js';
import {
  TOOL_IDS,
  readAutomationConfig,
  type ToolId,
} from '../schemas/automation-config.js';
import {structuredError} from '../stderr.js';
import {resolveRepoRoot} from '../wiki/util/git.js';

const HELP_TEXT = `Usage: gaia setup-ci check-drift [--workflows-dir <path>] [--json]

  Compare rendered .github/workflows/gaia-ci-*.yml against a fresh render
  of the current templates + .gaia/automation.json. Reports per-tool
  drift, missing-file, and in-sync state. Tools whose mode != 'ci' are
  omitted from every bucket.

  --workflows-dir <path>   Optional. Override of .github/workflows. Defaults
                           to <repoRoot>/.github/workflows.
  --json                   Emit machine-readable JSON instead of a human
                           report.
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

type RunOptions = {
  cwd?: string;
};

type DriftOutput = {
  drifted: ToolId[];
  in_sync: ToolId[];
  missing: ToolId[];
};

type ParsedArgs = {
  json: boolean;
  workflowsDir?: string;
};

const parseArgs = (argv: readonly string[]): ParsedArgs | {error: string} => {
  let json = false;
  let workflowsDir: string | undefined;

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index] as string;

    if (token === '--json') {
      json = true;

      continue;
    }

    if (token === '--workflows-dir') {
      const next = argv[index + 1];

      if (next === undefined || next.startsWith('--')) {
        return {error: '--workflows-dir requires a path argument'};
      }
      workflowsDir = next;
      index += 1;

      continue;
    }

    return {error: `unknown flag: ${token}`};
  }

  return {json, workflowsDir};
};

const safeReadFile = (filePath: string): string | null => {
  try {
    return readFileSync(filePath, 'utf8');
  } catch {
    return null;
  }
};

const printHuman = (output: DriftOutput): void => {
  const lines: string[] = [];

  if (output.drifted.length > 0) {
    lines.push(`drifted: ${output.drifted.join(', ')}`);
  }

  if (output.missing.length > 0) {
    lines.push(`missing: ${output.missing.join(', ')}`);
  }

  if (output.in_sync.length > 0) {
    lines.push(`in_sync: ${output.in_sync.join(', ')}`);
  }

  if (lines.length === 0) {
    process.stdout.write('no CI-mode tools enabled\n');

    return;
  }

  process.stdout.write(`${lines.join('\n')}\n`);
};

export const run = (
  argv: readonly string[],
  options: RunOptions = {}
): number => {
  if (argv.some((token) => HELP_TOKENS.has(token))) {
    process.stdout.write(HELP_TEXT);

    return EXIT_CODES.OK;
  }

  const parsed = parseArgs(argv);

  if ('error' in parsed) {
    structuredError({
      code: 'invalid_arguments',
      message: parsed.error,
      subcommand: 'setup-ci check-drift',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  let repoRoot: string;

  try {
    repoRoot = resolveRepoRoot(options.cwd ?? process.cwd());
  } catch {
    structuredError({
      code: 'not_a_git_repo',
      message: 'gaia setup-ci check-drift must run inside a git repository',
      subcommand: 'setup-ci check-drift',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const configRead = readAutomationConfig(repoRoot);

  if (configRead.status === 'missing') {
    structuredError({
      code: 'config_missing',
      message: '.gaia/automation.json does not exist',
      subcommand: 'setup-ci check-drift',
    });

    return EXIT_CODES.CONFIG_INVALID;
  }

  if (configRead.status === 'malformed') {
    structuredError({
      code: 'config_malformed',
      message: configRead.error,
      subcommand: 'setup-ci check-drift',
    });

    return EXIT_CODES.CONFIG_INVALID;
  }

  const workflowsDir =
    parsed.workflowsDir ?? path.join(repoRoot, '.github', 'workflows');
  const partialsDir = workflowPartialsDirectory();

  const output: DriftOutput = {drifted: [], in_sync: [], missing: []};

  for (const tool of TOOL_IDS) {
    const vars = buildWorkflowVars(configRead.config, tool);

    if (vars === null) continue;

    const renderedPath = path.join(workflowsDir, `gaia-ci-${tool}.yml`);
    const onDisk = safeReadFile(renderedPath);

    if (onDisk === null) {
      output.missing.push(tool);

      continue;
    }

    let freshRender: string;

    try {
      freshRender = renderWorkflowTemplate(
        workflowTemplatePath(tool),
        partialsDir,
        vars
      );
    } catch (error) {
      structuredError({
        code: 'render_failed',
        error: error instanceof Error ? error.message : String(error),
        subcommand: 'setup-ci check-drift',
        tool,
      });

      return EXIT_CODES.CONFIG_INVALID;
    }

    if (freshRender === onDisk) {
      output.in_sync.push(tool);
    } else {
      output.drifted.push(tool);
    }
  }

  if (parsed.json) {
    process.stdout.write(`${JSON.stringify(output)}\n`);
  } else {
    printHuman(output);
  }

  return EXIT_CODES.OK;
};
