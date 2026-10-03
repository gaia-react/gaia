/**
 * `gaia packages sync-settings [--check] [--repo-root <path>]`
 *
 * Writes `<package>/.claude/settings.json` for every registered package whose
 * path is not `.`, generated from the root `.claude/settings.json` plus the
 * optional `<package>/.claude/settings.overlay.json`. Exit 0 when written or up
 * to date, 1 when `--check` finds drift, 2 on a generation or usage error. A
 * generation error writes nothing for any package.
 */
import {existsSync, mkdirSync, readFileSync} from 'node:fs';
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {takeNonFlagValue} from '../util/argv.js';
import {atomicWriteFileSync} from '../util/atomic-write.js';
import {loadPackages} from '../util/packages.js';
import {resolveRepoRoot} from '../util/repo-root.js';
import {
  generateSettings,
  serializeSettings,
  SettingsGenerationError,
} from './settings-transform.js';
import type {JsonObject} from './settings-transform.js';

const HELP_TEXT = `Usage: gaia packages sync-settings [--check] [--repo-root <path>]

  Generates <package>/.claude/settings.json for every registered package not
  at the repo root, from .claude/settings.json plus the package's optional
  .claude/settings.overlay.json.

  --check   Write nothing. Exit 0 when every generated file is current, 1
            naming each file that is missing or out of date, 2 on an error.
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);
const EXIT_DRIFT = 1;
const SYNC_COMMAND = './.gaia/cli/gaia packages sync-settings';

type GeneratedFile = {content: string; file: string};

const readJsonObject = (file: string, label: string): JsonObject => {
  let parsed: unknown;

  try {
    parsed = JSON.parse(readFileSync(file, 'utf8')) as unknown;
  } catch {
    throw new SettingsGenerationError(
      `${label} is missing, unreadable, or not valid JSON. Next step: restore it from git.`
    );
  }

  if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
    throw new SettingsGenerationError(
      `${label} must be a JSON object. Next step: restore it from git.`
    );
  }

  return parsed as JsonObject;
};

const readOverlay = (file: string, label: string): unknown =>
  existsSync(file) ? readJsonObject(file, label) : {};

const generateAll = (
  repoRoot: string
): {error: string} | {files: GeneratedFile[]} => {
  const loaded = loadPackages(repoRoot);

  if (!loaded.ok) {
    return {error: loaded.message};
  }

  try {
    const rootSettings = readJsonObject(
      path.join(repoRoot, '.claude', 'settings.json'),
      '.claude/settings.json'
    );
    const files: GeneratedFile[] = [];

    for (const entry of loaded.packages.filter(
      ({path: where}) => where !== '.'
    )) {
      const overlayFile = `${entry.path}/.claude/settings.overlay.json`;

      try {
        const settings = generateSettings(
          rootSettings,
          readOverlay(path.join(repoRoot, overlayFile), overlayFile),
          entry.path
        );

        files.push({
          content: serializeSettings(settings),
          file: `${entry.path}/.claude/settings.json`,
        });
      } catch (error) {
        if (error instanceof SettingsGenerationError) {
          return {error: `${entry.path}: ${error.message}`};
        }

        throw error;
      }
    }

    return {files};
  } catch (error) {
    if (error instanceof SettingsGenerationError) {
      return {error: error.message};
    }

    throw error;
  }
};

const currentContent = (absolute: string): null | string =>
  existsSync(absolute) ? readFileSync(absolute, 'utf8') : null;

type Options = {check: boolean; repoRoot: string | undefined};

const parseArguments = (
  args: readonly string[]
): Options | {message: string} => {
  const options: Options = {check: false, repoRoot: undefined};

  for (let index = 0; index < args.length; index += 1) {
    const argument = args[index];

    if (argument === '--check') {
      options.check = true;
    } else if (argument === '--repo-root') {
      const value = takeNonFlagValue(args, index + 1, argument);

      if (!value.ok) {
        return {message: value.message};
      }
      options.repoRoot = value.value;
      index += 1;
    } else {
      return {message: `unknown argument: ${String(argument)}`};
    }
  }

  return options;
};

export const run = (args: readonly string[]): number => {
  if (args.some((argument) => HELP_TOKENS.has(argument))) {
    process.stdout.write(HELP_TEXT);

    return EXIT_CODES.OK;
  }
  const options = parseArguments(args);

  if ('message' in options) {
    structuredError({
      code: 'invalid_arguments',
      message: `${options.message}. Next step: see gaia packages sync-settings --help.`,
    });

    return EXIT_CODES.INVALID_ARGUMENTS;
  }
  let repoRoot: string;

  try {
    repoRoot = options.repoRoot ?? resolveRepoRoot();
  } catch {
    structuredError({
      code: 'repo_root_unresolved',
      message:
        'not inside a git working tree. Next step: run from the repository, or pass --repo-root <path>.',
    });

    return EXIT_CODES.INVALID_ARGUMENTS;
  }
  const generated = generateAll(repoRoot);

  if ('error' in generated) {
    structuredError({
      code: 'settings_generation_failed',
      message: generated.error,
    });

    return EXIT_CODES.INVALID_ARGUMENTS;
  }
  const stale = generated.files.filter(
    ({content, file}) => currentContent(path.join(repoRoot, file)) !== content
  );

  if (options.check) {
    if (stale.length === 0) {
      process.stdout.write('settings up to date\n');

      return EXIT_CODES.OK;
    }
    structuredError({
      code: 'settings_drift',
      files: stale.map(({file}) => file),
      message: `generated settings are out of date: ${stale.map(({file}) => file).join(', ')}. Next step: run ${SYNC_COMMAND} and stage the result.`,
    });

    return EXIT_DRIFT;
  }

  for (const {content, file} of stale) {
    const absolute = path.join(repoRoot, file);

    mkdirSync(path.dirname(absolute), {recursive: true});
    atomicWriteFileSync(absolute, content);
    process.stdout.write(`wrote ${file}\n`);
  }

  if (stale.length === 0) {
    process.stdout.write('settings up to date\n');
  }

  return EXIT_CODES.OK;
};
