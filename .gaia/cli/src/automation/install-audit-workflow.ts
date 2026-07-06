/**
 * `gaia automation install-audit-workflow --out-dir <path> [--dry-run]`
 *
 * Copies the canonical `code-review-audit.yml` template verbatim to the
 * caller-supplied `--out-dir`. The audit workflow has zero scaffold template
 * variables (it reads `.gaia/audit-ci.yml` at runtime), so it installs as a
 * static copy rather than a rendered template.
 *
 * `/setup-gaia` Step 8 calls this with `--out-dir .github/workflows`.
 */
import {mkdirSync, readFileSync, writeFileSync} from 'node:fs';
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {resolveRepoRoot} from '../wiki/util/git.js';
import {workflowAuditTemplatePath} from './paths.js';

const HELP_TEXT = `Usage: gaia automation install-audit-workflow --out-dir <path> [--dry-run]

  Copies the canonical code-review-audit.yml template verbatim to <out-dir>.
  The audit workflow reads .gaia/audit-ci.yml at runtime; it has no scaffold
  template variables and installs as a static file.

  --out-dir <path>     Required. Destination directory.
                       Created with mkdir -p semantics if missing.
  --dry-run            Optional. Print byte count + target; write nothing.
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

type ParsedArgs = {
  dryRun: boolean;
  outDir: string;
};

const parseArgs = (argv: readonly string[]): ParsedArgs | {error: string} => {
  let outDir: string | undefined;
  let dryRun = false;

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];

    if (token === '--out-dir') {
      // `noUncheckedIndexedAccess` is off, so TS types `argv[index + 1]` as
      // `string`, not `string | undefined`; check the bound explicitly
      // instead of comparing the indexed value to `undefined`.
      if (index + 1 >= argv.length || argv[index + 1].startsWith('--')) {
        return {error: '--out-dir requires a path argument'};
      }
      outDir = argv[index + 1];
      index += 1;
    } else if (token === '--dry-run') {
      dryRun = true;
    } else {
      return {error: `unexpected argument: ${token}`};
    }
  }

  if (outDir === undefined) {
    return {error: '--out-dir is required'};
  }

  return {dryRun, outDir};
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
      subcommand: 'automation install-audit-workflow',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  try {
    resolveRepoRoot(options.cwd ?? process.cwd());
  } catch {
    structuredError({
      code: 'not_a_git_repo',
      message:
        'gaia automation install-audit-workflow must run inside a git repository',
      subcommand: 'automation install-audit-workflow',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  let templateBytes: Buffer;

  try {
    templateBytes = readFileSync(workflowAuditTemplatePath());
  } catch (error) {
    structuredError({
      code: 'template_unreadable',
      error: error instanceof Error ? error.message : String(error),
      subcommand: 'automation install-audit-workflow',
    });

    return EXIT_CODES.STORAGE_INACCESSIBLE;
  }

  const outPath = path.join(parsed.outDir, 'code-review-audit.yml');

  if (parsed.dryRun) {
    process.stdout.write(
      `code-review-audit: ${String(templateBytes.length)} bytes -> ${outPath}\n`
    );

    return EXIT_CODES.OK;
  }

  mkdirSync(parsed.outDir, {recursive: true});
  writeFileSync(outPath, templateBytes);
  process.stdout.write(`wrote ${outPath}\n`);

  return EXIT_CODES.OK;
};
