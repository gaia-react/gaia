/**
 * `gaia setup-ci check-audit-drift [--workflows-dir <path>]
 *  [--baseline <path> [--latest <path>]] [--json]` handler.
 *
 * Two modes, both read-only.
 *
 * **2-way (default).** Byte-compares the installed
 * `.github/workflows/code-review-audit.yml` against the canonical bundled
 * template. The `/setup-gaia` slash command's Step 2 drift probe calls
 * this alongside `check-drift` to detect whether the audit workflow is
 * present and up-to-date.
 *
 *   { "state": "in_sync" | "drifted" | "missing" }
 *
 * - `in_sync` : installed file matches the template byte-for-byte.
 * - `drifted` : installed file exists but bytes differ from the template.
 * - `missing` : the file is absent (audit not yet installed or excluded).
 *
 * **3-way (with `--baseline`).** Classifies the installed file against the
 * baseline template (what the prior release shipped) and the latest
 * template (what this release ships) so `/update-gaia` Step 12 can refresh
 * a stale audit workflow without clobbering adopter customizations. The
 * audit template is static (no render), so this is a pure text 3-way.
 * `--latest` defaults to the bundled template when omitted.
 *
 *   { "state": "in_sync" | "clean" | "conflict" | "missing" }
 *
 * - `in_sync`  : installed equals latest, OR the release did not change the
 *                template (baseline == latest) so there is nothing to apply.
 * - `clean`    : installed equals baseline (stale but un-customized); safe to
 *                overwrite with latest.
 * - `conflict` : installed matches neither (adopter drift), or the baseline
 *                template is unavailable so cleanliness cannot be proven.
 *                The caller must NOT auto-write; surface a patch instead.
 * - `missing`  : the installed file is absent.
 *
 * This is a read-only query command; it exits 0 on every classification.
 */
import {readFileSync} from 'node:fs';
import path from 'node:path';
import {workflowAuditTemplatePath} from '../automation/paths.js';
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {resolveRepoRoot} from '../wiki/util/git.js';

const HELP_TEXT = `Usage: gaia setup-ci check-audit-drift [--workflows-dir <p>]
                                       [--baseline <p> [--latest <p>]] [--json]

  Compare the installed audit workflow against the template(s).

  Default (2-way): byte-compares <workflows-dir>/code-review-audit.yml
  against the canonical bundled template. Reports state:
  in_sync | drifted | missing.

  With --baseline (3-way): classifies the installed file against the prior
  release's template (--baseline) and this release's template (--latest,
  defaulting to the bundled template). Reports state:
  in_sync | clean | conflict | missing. Used by /update-gaia to refresh a
  stale audit workflow without clobbering adopter edits.

  --workflows-dir <path>   Optional. Override of .github/workflows. Defaults
                           to <repoRoot>/.github/workflows.
  --baseline <path>        Prior release's code-review-audit.yml.tmpl. Enables
                           3-way mode.
  --latest <path>          This release's code-review-audit.yml.tmpl. Defaults
                           to the bundled template. Requires --baseline.
  --json                   Emit machine-readable JSON instead of a human
                           report.
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

type AuditDriftState =
  | 'clean'
  | 'conflict'
  | 'drifted'
  | 'in_sync'
  | 'missing';

type ParsedArgs = {
  baseline?: string;
  json: boolean;
  latest?: string;
  workflowsDir?: string;
};

const parseArgs = (argv: readonly string[]): ParsedArgs | {error: string} => {
  let json = false;
  let workflowsDir: string | undefined;
  let baseline: string | undefined;
  let latest: string | undefined;

  const takePath = (
    flag: string,
    index: number
  ): {value: string} | {error: string} => {
    const next = argv[index + 1];

    if (next === undefined || next.startsWith('--')) {
      return {error: `${flag} requires a path argument`};
    }

    return {value: next};
  };

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index] as string;

    if (token === '--json') {
      json = true;

      continue;
    }

    if (token === '--workflows-dir' || token === '--baseline' || token === '--latest') {
      const taken = takePath(token, index);

      if ('error' in taken) {
        return {error: taken.error};
      }
      if (token === '--workflows-dir') {
        workflowsDir = taken.value;
      } else if (token === '--baseline') {
        baseline = taken.value;
      } else {
        latest = taken.value;
      }
      index += 1;

      continue;
    }

    return {error: `unknown flag: ${token}`};
  }

  if (latest !== undefined && baseline === undefined) {
    return {error: '--latest requires --baseline'};
  }

  return {baseline, json, latest, workflowsDir};
};

const safeReadFile = (filePath: string): string | null => {
  try {
    return readFileSync(filePath, 'utf8');
  } catch {
    return null;
  }
};

type RunOptions = {
  cwd?: string;
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
      subcommand: 'setup-ci check-audit-drift',
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
        'gaia setup-ci check-audit-drift must run inside a git repository',
      subcommand: 'setup-ci check-audit-drift',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const workflowsDir =
    parsed.workflowsDir ?? path.join(repoRoot, '.github', 'workflows');

  const installedPath = path.join(workflowsDir, 'code-review-audit.yml');
  const onDisk = safeReadFile(installedPath);

  const readTemplateOrFail = (
    templatePath: string
  ): {content: string} | {exitCode: number} => {
    try {
      return {content: readFileSync(templatePath, 'utf8')};
    } catch (error) {
      structuredError({
        code: 'template_unreadable',
        error: error instanceof Error ? error.message : String(error),
        subcommand: 'setup-ci check-audit-drift',
      });

      return {exitCode: EXIT_CODES.STORAGE_INACCESSIBLE};
    }
  };

  let state: AuditDriftState;

  if (onDisk === null) {
    state = 'missing';
  } else if (parsed.baseline === undefined) {
    // 2-way mode: installed vs the bundled template.
    const template = readTemplateOrFail(workflowAuditTemplatePath());

    if ('exitCode' in template) {
      return template.exitCode;
    }
    state = onDisk === template.content ? 'in_sync' : 'drifted';
  } else {
    // 3-way mode: installed vs baseline (prior release) and latest (this
    // release). The latest template is required; the baseline may be
    // unavailable (an older pre-template release), which collapses to
    // conflict so the caller never auto-writes on an unprovable comparison.
    const latest = readTemplateOrFail(parsed.latest ?? workflowAuditTemplatePath());

    if ('exitCode' in latest) {
      return latest.exitCode;
    }
    const baseline = safeReadFile(parsed.baseline);

    if (onDisk === latest.content || baseline === latest.content) {
      // Installed already at latest, OR the release did not touch the
      // template (baseline == latest) so there is nothing to apply.
      state = 'in_sync';
    } else if (baseline !== null && onDisk === baseline) {
      state = 'clean';
    } else {
      state = 'conflict';
    }
  }

  if (parsed.json) {
    process.stdout.write(`${JSON.stringify({state})}\n`);
  } else {
    process.stdout.write(`audit workflow: ${state}\n`);
  }

  return EXIT_CODES.OK;
};
