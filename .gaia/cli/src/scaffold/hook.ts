/**
 * `gaia scaffold hook <useFoo>` handler.
 *
 * Emits a custom React hook + its vitest under the frontend package's `app/hooks/`. The hook name
 * is `use-kebab` (`use-toggle`) or `useCamel` (`useToggle`); the export is the
 * camelCase name and the file name is its kebab form.
 *
 * Naming convention:
 *   app/hooks/use-{kebab}.ts
 *   app/hooks/tests/use-{kebab}.test.ts
 *
 * No barrel; `app/hooks/` does not have an index.ts in this repo.
 *
 * Re-running is idempotent: identical files are reported in `skipped`,
 * differing files cause `writeFileIfAbsent` to throw to protect customizations.
 */
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {writeFileIfAbsent} from './fs.js';
import {resolveScaffoldTarget} from './resolve-target.js';
import {renderTemplate} from './template.js';
import type {ScaffoldResult} from './types.js';

const KEBAB_HOOK_PATTERN = /^use(?:-[a-z\d]+)+$/u;
const CAMEL_HOOK_PATTERN = /^use[A-Z][A-Za-z\d]*$/u;

/** `use-toggle` -> `useToggle`. */
const kebabToCamel = (kebab: string): string =>
  kebab
    .split('-')
    .map((part, index) =>
      index === 0 ? part : `${part.charAt(0).toUpperCase()}${part.slice(1)}`
    )
    .join('');

/** `useToggleOpen` -> `use-toggle-open`, splitting before each capital. */
const camelToKebab = (camel: string): string =>
  camel
    .replaceAll(/(?<lower>[a-z\d])(?<upper>[A-Z])/gu, '$<lower>-$<upper>')
    .toLowerCase();

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

    if (token !== undefined) {
      if (token === '--json') {
        json = true;
      } else if (token === '--params') {
        paramsRaw = argv[index + 1];
        index += 1;
      } else if (token === '--returns') {
        returns = argv[index + 1];
        index += 1;
      } else if (token.startsWith('--')) {
        // Unknown flag: surface upstream as a usage error.
        throw new Error(`unknown flag: ${token}`);
      } else {
        positional.push(token);
      }
    }
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

type EmitOptions = {
  fileStem: string;
  hookFilePath: string;
  name: string;
  params: readonly Param[];
  returns: string | undefined;
  testFilePath: string;
};

const emitFiles = (options: EmitOptions): ScaffoldResult => {
  const {fileStem, hookFilePath, name, params, returns, testFilePath} = options;
  const paramsString = formatParamsString(params);
  const returnsAnnotation = `: ${returns ?? 'void'}`;

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
    fileStem,
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
  /** Directory the command runs in; defaults to `process.cwd()`. The package root comes from the registry, never from this directory itself. */
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

  const name = parsed.positional.at(0);

  if (name === undefined) {
    structuredError({
      code: 'missing_argument',
      message: 'expected hook name (e.g. use-foo or useFoo)',
      subcommand: 'scaffold hook',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const isKebab = KEBAB_HOOK_PATTERN.test(name);

  if (!isKebab && !CAMEL_HOOK_PATTERN.test(name)) {
    structuredError({
      code: 'invalid_hook_name',
      message: `hook name must be use-kebab (use-toggle) or useCamel (useToggle); got '${name}'`,
      subcommand: 'scaffold hook',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const target = resolveScaffoldTarget(
    options.repoRoot ?? process.cwd(),
    'scaffold hook'
  );

  if (target === undefined) return EXIT_CODES.CONFIG_INVALID;
  const exportName = isKebab ? kebabToCamel(name) : name;
  const fileStem = isKebab ? name : camelToKebab(name);
  const hooksDir = path.join(target.packageDir, 'app', 'hooks');
  const hookFilePath = path.join(hooksDir, `${fileStem}.ts`);
  const testFilePath = path.join(hooksDir, 'tests', `${fileStem}.test.ts`);

  let result: ScaffoldResult;

  try {
    result = emitFiles({
      fileStem,
      hookFilePath,
      name: exportName,
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
