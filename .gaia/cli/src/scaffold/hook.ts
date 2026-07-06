/**
 * `gaia scaffold hook <useFoo>` handler.
 *
 * Emits a custom React hook + its vitest under `app/hooks/`. The hook name
 * must start with `use` and be camelCase; the file name matches the hook
 * name verbatim.
 *
 * Naming convention:
 *   app/hooks/{name}.ts
 *   app/hooks/tests/{name}.test.ts
 *
 * No barrel; `app/hooks/` does not have an index.ts in this repo.
 *
 * Re-running is idempotent: identical files are reported in `skipped`,
 * differing files cause `writeFileIfAbsent` to throw to protect customizations.
 */
import {execSync} from 'node:child_process';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {writeFileIfAbsent} from './fs.js';
import {renderTemplate} from './template.js';
import type {ScaffoldResult} from './types.js';

const HOOK_NAME_PATTERN = /^use[A-Z][A-Za-z0-9]*$/u;

const TEMPLATE_DIR_NAME = 'hook';
const HOOK_TEMPLATE_FILE = 'hook.ts.tmpl';
const TEST_TEMPLATE_FILE = 'hook.test.ts.tmpl';

type Param = {name: string; type: string};

type ParsedFlags = {
  json: boolean;
  params: Param[];
  returns: string | undefined;
};

const parseParams = (raw: string | undefined): Param[] => {
  if (raw === undefined || raw.trim().length === 0) return [];

  return raw.split(',').flatMap((entry): Param[] => {
    const trimmed = entry.trim();

    if (trimmed.length === 0) return [];
    const colonIndex = trimmed.indexOf(':');

    if (colonIndex === -1) {
      return [{name: trimmed, type: 'unknown'}];
    }
    const name = trimmed.slice(0, colonIndex).trim();
    const type = trimmed.slice(colonIndex + 1).trim();

    return [{name, type: type.length > 0 ? type : 'unknown'}];
  });
};

type FlagReadResult = {
  flags: ParsedFlags;
  positional: string[];
};

const readFlags = (argv: readonly string[]): FlagReadResult => {
  const positional: string[] = [];
  let json = false;
  let paramsRaw: string | undefined;
  let returns: string | undefined;

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];

    if (token === '--json') {
      json = true;
      continue;
    }

    if (token === '--params') {
      paramsRaw = argv[index + 1];
      index += 1;
      continue;
    }

    if (token === '--returns') {
      returns = argv[index + 1];
      index += 1;
      continue;
    }

    if (token !== undefined && token.startsWith('--')) {
      // Unknown flag: surface upstream as a usage error.
      throw new Error(`unknown flag: ${token}`);
    }
    if (token !== undefined) positional.push(token);
  }

  return {
    flags: {
      json,
      params: parseParams(paramsRaw),
      returns:
        returns !== undefined && returns.length > 0 ? returns : undefined,
    },
    positional,
  };
};

const formatParamsString = (params: readonly Param[]): string =>
  params.map((param) => `${param.name}: ${param.type}`).join(', ');

const sentinelForType = (type: string): string => {
  const trimmed = type.trim();

  if (trimmed === 'string') return "''";
  if (trimmed === 'number') return '0';
  if (trimmed === 'boolean') return 'false';
  if (trimmed.endsWith('[]') || trimmed.startsWith('Array<')) return '[]';

  return 'undefined as never';
};

const formatCallArgs = (params: readonly Param[]): string =>
  params.map((param) => sentinelForType(param.type)).join(', ');

const resolveTemplateFile = (filename: string): string => {
  const here = fileURLToPath(import.meta.url);

  return path.join(
    path.dirname(here),
    'templates',
    TEMPLATE_DIR_NAME,
    filename
  );
};

const resolveRepoRoot = (): string => {
  try {
    const out = execSync('git rev-parse --show-toplevel', {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
    }).trim();

    return out.length > 0 ? out : process.cwd();
  } catch {
    return process.cwd();
  }
};

type EmitOptions = {
  hookFilePath: string;
  name: string;
  params: readonly Param[];
  returns: string | undefined;
  testFilePath: string;
};

const emitFiles = (options: EmitOptions): ScaffoldResult => {
  const {hookFilePath, name, params, returns, testFilePath} = options;
  const paramsString = formatParamsString(params);
  const returnsAnnotation = returns === undefined ? '' : `: ${returns}`;

  const hookContents = renderTemplate(resolveTemplateFile(HOOK_TEMPLATE_FILE), {
    // The default body (`// TODO: implement`) references no React hooks,
    // so the import block is empty.
    imports: '',
    name,
    paramsString,
    returnsAnnotation,
  });
  const testContents = renderTemplate(resolveTemplateFile(TEST_TEMPLATE_FILE), {
    callArgs: formatCallArgs(params),
    name,
  });

  const written: string[] = [];
  const skipped: string[] = [];

  for (const [filePath, contents] of [
    [hookFilePath, hookContents],
    [testFilePath, testContents],
  ] as const) {
    const result = writeFileIfAbsent(filePath, contents);

    if (result.written) {
      written.push(filePath);
    } else {
      skipped.push(filePath);
    }
  }

  return {edited: [], skipped, written};
};

const printResult = (result: ScaffoldResult, jsonMode: boolean): void => {
  if (jsonMode) {
    process.stdout.write(`${JSON.stringify(result)}\n`);

    return;
  }

  for (const file of result.written) {
    process.stdout.write(`written: ${file}\n`);
  }

  for (const file of result.skipped) {
    process.stdout.write(`skipped: ${file}\n`);
  }
};

type HandlerOptions = {
  /** Absolute path to the repo root; defaults to `git rev-parse --show-toplevel`. */
  repoRoot?: string;
};

export const run = (
  argv: readonly string[],
  options: HandlerOptions = {}
): number => {
  let parsed: FlagReadResult;

  try {
    parsed = readFlags(argv);
  } catch (error) {
    structuredError({
      code: 'invalid_flag',
      message: error instanceof Error ? error.message : String(error),
      subcommand: 'scaffold hook',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const name = parsed.positional[0];

  if (name === undefined) {
    structuredError({
      code: 'missing_argument',
      message: 'expected hook name (e.g. useFoo)',
      subcommand: 'scaffold hook',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  if (!HOOK_NAME_PATTERN.test(name)) {
    structuredError({
      code: 'invalid_hook_name',
      message: `hook name must start with 'use' and be camelCase; got '${name}'`,
      subcommand: 'scaffold hook',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const repoRoot = options.repoRoot ?? resolveRepoRoot();
  const hooksDir = path.join(repoRoot, 'app', 'hooks');
  const hookFilePath = path.join(hooksDir, `${name}.ts`);
  const testFilePath = path.join(hooksDir, 'tests', `${name}.test.ts`);

  let result: ScaffoldResult;

  try {
    result = emitFiles({
      hookFilePath,
      name,
      params: parsed.flags.params,
      returns: parsed.flags.returns,
      testFilePath,
    });
  } catch (error) {
    structuredError({
      code: 'scaffold_failed',
      message: error instanceof Error ? error.message : String(error),
      subcommand: 'scaffold hook',
    });

    return EXIT_CODES.PAYLOAD_VALIDATION_FAILED;
  }

  printResult(result, parsed.flags.json);

  return EXIT_CODES.OK;
};
