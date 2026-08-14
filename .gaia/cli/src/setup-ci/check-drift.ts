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
 *     "missing": ToolId[],
 *     "scheduler": "disabled" | "drifted" | "in_sync" | "missing"
 *   }
 *
 * - `drifted`: rendered file exists and bytes differ from a fresh render.
 * - `missing`: tool is enabled (mode=ci) but the workflow file is absent.
 * - `in_sync`: rendered bytes match a fresh render.
 *
 * Tools whose `mode !== 'ci'` are absent from all three arrays.
 *
 * `scheduler` reports `gaia-ci.yml` on the same three states, plus
 * `disabled` for a config with no CI-mode tool, where no scheduler is
 * rendered at all. It is a scalar rather than a fourth array because there
 * is exactly one scheduler and it is not a tool.
 */
import {readFileSync} from 'node:fs';
import path from 'node:path';
import {SCHEDULER_WORKFLOW_FILENAME} from '../automation/paths.js';
import {
  renderedWorkflowFilename,
  renderWorkflowFor,
} from '../automation/render.js';
import type {RenderTarget} from '../automation/render.js';
import {EXIT_CODES} from '../exit.js';
import {readAutomationConfig, TOOL_IDS} from '../schemas/automation-config.js';
import type {AutomationConfig, ToolId} from '../schemas/automation-config.js';
import {structuredError} from '../stderr.js';
import {resolveRepoRoot} from '../util/repo-root.js';

const HELP_TEXT = `Usage: gaia setup-ci check-drift [--workflows-dir <path>] [--json]

  Compare the rendered .github/workflows/gaia-ci-*.yml tool workflows and
  the gaia-ci.yml scheduler against a fresh render of the current templates
  + .gaia/automation.json. Reports per-tool drift, missing-file, and in-sync
  state, plus the scheduler's own. Tools whose mode != 'ci' are omitted from
  every bucket.

  --workflows-dir <path>   Optional. Override of .github/workflows. Defaults
                           to <repoRoot>/.github/workflows.
  --json                   Emit machine-readable JSON instead of a human
                           report.
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

type DriftOutput = {
  drifted: ToolId[];
  in_sync: ToolId[];
  missing: ToolId[];
  scheduler: SchedulerState;
};

type ParsedArgs = {
  json: boolean;
  workflowsDir?: string;
};

type RunOptions = {
  cwd?: string;
};

type SchedulerState = 'disabled' | 'drifted' | 'in_sync' | 'missing';

const parseArgs = (argv: readonly string[]): ParsedArgs | {error: string} => {
  let json = false;
  let workflowsDir: string | undefined;

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];

    if (token === '--json') {
      json = true;
    } else if (token === '--workflows-dir') {
      const next = argv.at(index + 1);

      if (next === undefined || next.startsWith('--')) {
        return {error: '--workflows-dir requires a path argument'};
      }
      workflowsDir = next;
      index += 1;
    } else {
      return {error: `unknown flag: ${token}`};
    }
  }

  return {json, workflowsDir};
};

const safeReadFile = (filePath: string): null | string => {
  try {
    return readFileSync(filePath, 'utf8');
  } catch {
    return null;
  }
};

type ClassifyDriftArgs = {
  config: AutomationConfig;
  target: RenderTarget;
  workflowsDir: string;
};

type DriftClassification =
  {exitCode: number} | {state: 'disabled' | 'drifted' | 'in_sync' | 'missing'};

// Extracted out of `run` (kept its cognitive complexity under the frozen
// limit): one target's drift classification, independent of the per-run
// accumulation into `output`. `disabled` means the config renders nothing
// for this target: a tool whose mode is not `ci`, or a scheduler with no
// CI-mode tool. Callers map it to their own bucket.
const classifyDrift = (args: ClassifyDriftArgs): DriftClassification => {
  const {config, target, workflowsDir} = args;

  try {
    const freshRender = renderWorkflowFor(config, target);

    if (freshRender === null) return {state: 'disabled'};

    const onDisk = safeReadFile(
      path.join(workflowsDir, renderedWorkflowFilename(target))
    );

    if (onDisk === null) return {state: 'missing'};

    return {state: freshRender === onDisk ? 'in_sync' : 'drifted'};
  } catch (error) {
    structuredError({
      code: 'render_failed',
      error: error instanceof Error ? error.message : String(error),
      subcommand: 'setup-ci check-drift',
      tool:
        target.kind === 'scheduler' ? SCHEDULER_WORKFLOW_FILENAME : target.tool,
    });

    return {exitCode: EXIT_CODES.CONFIG_INVALID};
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

  if (output.scheduler === 'disabled' && lines.length === 0) {
    process.stdout.write('no CI-mode tools enabled\n');

    return;
  }

  lines.push(`scheduler (${SCHEDULER_WORKFLOW_FILENAME}): ${output.scheduler}`);

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

  const scheduler = classifyDrift({
    config: configRead.config,
    target: {kind: 'scheduler'},
    workflowsDir,
  });

  if ('exitCode' in scheduler) return scheduler.exitCode;

  const output: DriftOutput = {
    drifted: [],
    in_sync: [],
    missing: [],
    scheduler: scheduler.state,
  };

  for (const tool of TOOL_IDS) {
    const classified = classifyDrift({
      config: configRead.config,
      target: {kind: 'tool', tool},
      workflowsDir,
    });

    if ('exitCode' in classified) return classified.exitCode;

    if (classified.state === 'drifted') output.drifted.push(tool);
    else if (classified.state === 'in_sync') output.in_sync.push(tool);
    else if (classified.state === 'missing') output.missing.push(tool);
    // 'disabled': tool's mode !== 'ci', omitted from every bucket.
  }

  if (parsed.json) {
    process.stdout.write(`${JSON.stringify(output)}\n`);
  } else {
    printHuman(output);
  }

  return EXIT_CODES.OK;
};
