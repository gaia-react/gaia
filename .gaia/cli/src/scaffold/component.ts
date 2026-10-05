/**
 * `gaia scaffold component <name>` handler.
 *
 * Replaces the prose-only `new-component` skill with deterministic file
 * emission. Produces two files under
 * `app/components/<kebab>/` matching the project's component convention
 * (`app/components/theme-switch/`, etc.).
 *
 * The name is kebab (`price-tag`) or PascalCase (`PriceBadge`). The export is
 * the PascalCase form and the folder is its lodash-style kebab form, the same
 * transform the linter's filename-match rule applies.
 *
 * Output shape (default invocation, `gaia scaffold component foo-bar`):
 *
 *   app/components/foo-bar/index.tsx
 *   app/components/foo-bar/tests/index.stories.tsx
 *
 * The story is the component's test: its play story renders the component in
 * Chromium and asserts on it, and the accessibility check runs on every story.
 *
 * `--parent` may name an existing folder under `app/components` or
 * `app/pages/<path>`. `app/components/ui` and everything under it is refused:
 * shadcn owns that folder.
 *
 * The retired `--no-story` flag is refused: a component without a story has
 * no test.
 *
 * The `--props "name:type,name:type"` flag emits a Props type alias and
 * annotates the destructured parameter with it (`({a, b}: NameProps) =>`);
 * without the flag the component takes no parameters. Each entry must be `name:type`; empty entries
 * and malformed pairs are rejected with exit 1. Only depth-0 commas separate
 * props, so comma-bearing types (`Record<K, V>`, `(a, b) => void`, tuples) are
 * supported within a single entry.
 *
 * The handler uses the shared scaffold utilities (`writeFileIfAbsent`,
 * `loadTemplate`, `renderTemplate`) so behavior matches the other
 * scaffolders shipped in Phase 2.
 */
import {existsSync, statSync} from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {takeNonFlagValue} from '../util/argv.js';
import {toPackageRelative} from '../util/package-target.js';
import {writeFileIfAbsent} from './fs.js';
import {resolveScaffoldTarget} from './resolve-target.js';
import {renderTemplate} from './template.js';
import type {ScaffoldResult} from './types.js';

const PASCAL_CASE_PATTERN = /^[A-Z][\dA-Za-z]*$/u;
const KEBAB_CASE_PATTERN = /^[a-z][\da-z]*(?:-[\da-z]+)*$/u;
const PROP_NAME_PATTERN = /^[A-Za-z_][\w$]*$/u;
// lodash's word split, ordinals included. Input is a validated identifier, so
// backtracking cost is bounded by its length.
/* eslint-disable sonarjs/super-linear-regex -- bounded identifier input */
const KEBAB_WORD_PATTERN =
  /[A-Z]+(?=[A-Z][a-z])|[A-Z]?[a-z]+|[A-Z]+|\d*(?:1ST|2ND|3RD|(?![123])\dTH)(?=\b|[a-z_])|\d*(?:1st|2nd|3rd|(?![123])\dth)(?=\b|[A-Z_])|\d+/gu;
/* eslint-enable sonarjs/super-linear-regex */
const TEMPLATES_DIR = 'component';
const COMPONENTS_DEFAULT_PARENT = 'app/components';
const APP_SEGMENT = 'app';
const COMPONENTS_SEGMENT = 'components';
const PAGES_SEGMENT = 'pages';
const UI_SEGMENT = 'ui';

const NO_STORY_MESSAGE =
  "--no-story is not supported: the story is the component's test (render, play and accessibility check), so a component cannot be scaffolded without one.";

const NAME_FORMS_MESSAGE =
  'use kebab-case (price-tag) or PascalCase (PriceBadge)';

/** `price-tag` -> `PriceTag`: capitalize each hyphen-separated part. */
const kebabToPascal = (kebab: string): string =>
  kebab
    .split('-')
    .map((part) => `${part.charAt(0).toUpperCase()}${part.slice(1)}`)
    .join('');

/**
 * lodash `kebabCase` for the ASCII alphanumeric names this command accepts:
 * words split on a lower-to-upper boundary, an acronym-to-word boundary
 * (`HTMLView` -> `HTML`, `View`) and every digit run (`Heading2` ->
 * `Heading`, `2`) except ordinals (`1st`), lowercased and joined with `-`. The linter's filename
 * transform uses lodash, so the folder name must come from the same split.
 */
const toKebabCase = (value: string): string =>
  (value.match(KEBAB_WORD_PATTERN) ?? []).join('-').toLowerCase();

const BRACKET_PAIRS: Record<string, string> = {
  '(': ')',
  '<': '>',
  '[': ']',
  '{': '}',
};
const CLOSERS = new Set(Object.values(BRACKET_PAIRS));

/**
 * Split a `--props` value on prop-separating commas only. A comma at bracket
 * depth 0 separates props; a comma inside a bracket pair (`<>`, `()`, `[]`,
 * `{}`) belongs to a comma-bearing type (`Record<string, unknown>`,
 * `(id: string, ev: Event) => void`, a tuple `[string, number]`) and is kept
 * intact inside its segment.
 */
const splitTopLevelCommas = (raw: string): string[] => {
  const segments: string[] = [];
  let depth = 0;
  let current = '';

  for (const char of raw) {
    if (char in BRACKET_PAIRS) {
      depth += 1;
    } else if (CLOSERS.has(char) && depth > 0) {
      depth -= 1;
    }

    if (char === ',' && depth === 0) {
      segments.push(current);
      current = '';
    } else {
      current += char;
    }
  }

  segments.push(current);

  return segments;
};

type FlagParseFailure = {
  message: string;
  ok: false;
};

type FlagParseResult = FlagParseFailure | FlagParseSuccess;

type FlagParseSuccess = {
  flags: ParsedFlags;
  ok: true;
};

type ParsedFlags = {
  json: boolean;
  name: string;
  parent: string;
  props: PropertyEntry[];
};

type PropertyEntry = {
  name: string;
  type: string;
};

const HELP_TEXT = `Usage: gaia scaffold component <name> [flags]

  <name>              kebab-case (price-tag) or PascalCase (PriceBadge); the
                      folder is the kebab form of the PascalCase export name
  --parent <dir>      Existing parent dir under app/components/ or app/pages/<path>
                      (default: app/components/), relative to the frontend
                      package. components/ui is refused: shadcn owns it.
  --props "a:string,b:number"
                      Typed props rendered as a Props type alias.
                      Comma-bearing types (Record<K, V>, (a, b) => void,
                      tuples) are supported; only top-level commas split props.
  --json              Emit ScaffoldResult JSON on stdout
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

// Splits on the first `:` rather than a single regex (avoids a `\s*`
// immediately preceding a `.+` catch-all, an overlapping-quantifier shape
// flagged by sonarjs/super-linear-regex).
const parsePropertyEntry = (entry: string): null | PropertyEntry => {
  const colonIndex = entry.indexOf(':');

  if (colonIndex === -1) return null;

  const name = entry.slice(0, colonIndex).trim();
  const type = entry.slice(colonIndex + 1).trim();

  if (!PROP_NAME_PATTERN.test(name) || type === '') return null;

  return {name, type};
};

const parseProps = (raw: string): FlagParseResult => {
  const segments = splitTopLevelCommas(raw);

  const entries = segments.flatMap((entry) => {
    const trimmed = entry.trim();

    return trimmed.length > 0 ? [trimmed] : [];
  });

  if (entries.length === 0) {
    return {
      message: '--props requires at least one name:type entry',
      ok: false,
    };
  }

  const props: PropertyEntry[] = [];

  for (const entry of entries) {
    const parsedEntry = parsePropertyEntry(entry);

    if (parsedEntry === null) {
      return {
        message: `--props entry must be name:type (got: "${entry}")`,
        ok: false,
      };
    }

    props.push(parsedEntry);
  }

  return {
    flags: {
      json: false,
      name: '',
      parent: '',
      props,
    },
    ok: true,
  };
};

type ParentFlagResult =
  {message: string; ok: false} | {ok: true; parent: string};

const parseParentFlag = (
  argv: readonly string[],
  index: number
): ParentFlagResult => {
  const parsedValue = takeNonFlagValue(argv, index + 1, '--parent');

  if (!parsedValue.ok) return parsedValue;

  return {ok: true, parent: parsedValue.value};
};

type PropsFlagResult =
  {message: string; ok: false} | {ok: true; props: PropertyEntry[]};

const parsePropsFlag = (
  argv: readonly string[],
  index: number
): PropsFlagResult => {
  const parsedValue = takeNonFlagValue(argv, index + 1, '--props');

  if (!parsedValue.ok) return parsedValue;

  const parsed = parseProps(parsedValue.value);

  if (!parsed.ok) return parsed;

  return {ok: true, props: parsed.flags.props};
};

type ApplyTokenResult = FlagParseFailure | {consumed: number};

type FlagsState = {
  json: boolean;
  name: string | undefined;
  parent: string;
  props: PropertyEntry[];
};

// One token's worth of dispatch, extracted so `parseFlags`'s own loop stays
// a flat dispatch table (kept `parseFlags`'s cognitive complexity under the
// frozen limit). `consumed` is how many EXTRA argv slots this token ate
// (its value, for flags that take one); the caller folds it into the loop
// counter via `+=`, matching the accepted `index += 1` idiom (a plain
// reassignment trips sonarjs/updated-loop-counter).
const applyToken = (
  argv: readonly string[],
  index: number,
  state: FlagsState
): ApplyTokenResult => {
  const token = argv[index];

  if (token === undefined) {
    return {message: 'unexpected end of arguments', ok: false};
  }

  if (token === '--no-story') {
    return {message: NO_STORY_MESSAGE, ok: false};
  }

  if (token === '--json') {
    state.json = true;

    return {consumed: 0};
  }

  if (token === '--parent') {
    const result = parseParentFlag(argv, index);

    if (!result.ok) return result;
    state.parent = result.parent;

    return {consumed: 1};
  }

  if (token === '--props') {
    const result = parsePropsFlag(argv, index);

    if (!result.ok) return result;
    state.props = result.props;

    return {consumed: 1};
  }

  if (token.startsWith('--')) {
    return {message: `unknown flag: ${token}`, ok: false};
  }

  if (state.name === undefined) {
    state.name = token;

    return {consumed: 0};
  }

  return {message: `unexpected positional argument: ${token}`, ok: false};
};

const parseFlags = (argv: readonly string[]): FlagParseResult => {
  const state: FlagsState = {
    json: false,
    name: undefined,
    parent: COMPONENTS_DEFAULT_PARENT,
    props: [],
  };

  for (let index = 0; index < argv.length; index += 1) {
    const result = applyToken(argv, index, state);

    if ('consumed' in result) {
      index += result.consumed;
    } else {
      return result;
    }
  }

  const {json, name, parent, props} = state;

  if (name === undefined) {
    return {message: 'component name is required', ok: false};
  }

  const isKebab = KEBAB_CASE_PATTERN.test(name);

  if (!isKebab && !PASCAL_CASE_PATTERN.test(name)) {
    return {
      message: `component name must be ${NAME_FORMS_MESSAGE} (got: "${name}")`,
      ok: false,
    };
  }

  // A kebab name round-trips only when lodash splits it where the author did.
  // lodash splits digit runs, so `heading2` exports `Heading2` and the
  // linter expects the folder `heading-2`: refuse rather than write a folder
  // the linter rejects.
  if (isKebab && toKebabCase(kebabToPascal(name)) !== name) {
    return {
      message: `component folder for "${name}" must be "${toKebabCase(kebabToPascal(name))}" (the folder the linter expects for export ${kebabToPascal(name)}); pass that name instead`,
      ok: false,
    };
  }

  return {
    flags: {
      json,
      name,
      parent,
      props,
    },
    ok: true,
  };
};

const buildPropsTypeBlock = (
  componentName: string,
  props: readonly PropertyEntry[]
): string => {
  if (props.length === 0) return '';
  const entries = props
    .map((property) => `  ${property.name}: ${property.type};`)
    .join('\n');

  return `type ${componentName}Props = {\n${entries}\n};\n\n`;
};

/**
 * A representative value literal for a prop, ready to splice into a JSX
 * attribute (`name={value}` or, for strings, the quoted form `name="value"`).
 * Primitives get an honest non-degenerate value so the scaffolded story
 * renders real DOM. Exotic types fall back to a typed cast the author replaces
 * (kept type-safe so the generated story still typechecks).
 */
const isFunctionType = (type: string): boolean =>
  type.includes('=>') || /\bFunction\b/u.test(type);

const buildPropertyAttribute = (property: PropertyEntry): string => {
  const {type} = property;

  if (type === 'string') return `${property.name}="${property.name}"`;
  if (type === 'number') return `${property.name}={0}`;
  if (type === 'boolean') return `${property.name}={true}`;
  if (type.endsWith('[]')) return `${property.name}={[]}`;

  // Function-typed props get a callable no-op cast: `({} as () => void)()`
  // throws TypeError the moment an author wires the prop into the render body,
  // so the fallback must be invocable, not an empty-object cast.
  if (isFunctionType(type)) {
    return `${property.name}={(() => undefined) as ${type}}`;
  }

  return `${property.name}={{} as ${type}}`;
};

const buildPropertyAttributes = (props: readonly PropertyEntry[]): string =>
  props.map(buildPropertyAttribute).join(' ');

/**
 * A story export that renders the component. With props, it renders an
 * instance carrying representative values so the play story and the
 * accessibility check have real DOM to work against; without props it renders
 * the bare component.
 */
const buildStoryExport = (
  exportName: string,
  componentName: string,
  props: readonly PropertyEntry[]
): string => {
  if (props.length === 0) {
    return `export const ${exportName}: StoryFn = () => <${componentName} />;`;
  }

  return [
    `export const ${exportName}: StoryFn = () => (`,
    `  <${componentName} ${buildPropertyAttributes(props)} />`,
    ');',
  ].join('\n');
};

/**
 * The story title is the path under `app/`, each folder in PascalCase display
 * form: `app/components/price-tag` -> `Components/PriceTag`,
 * `app/pages/index/promo-banner` -> `Pages/Index/PromoBanner`. `parent` is
 * package-relative and already normalized.
 */
const buildStoryTitle = (parent: string, folder: string): string =>
  [...parent.split('/').slice(1), folder].map(kebabToPascal).join('/');

type ParentCheck = {message: string; ok: false} | {ok: true; parent: string};

/**
 * Normalize a package-relative parent and refuse any that is not under
 * `app/components` (excluding `ui`) or `app/pages/<path>`.
 */
const checkParent = (rawParent: string): ParentCheck => {
  const normalized = path.posix.normalize(rawParent);
  const parent =
    normalized.endsWith('/') ? normalized.slice(0, -1) : normalized;
  const segments = parent.split('/');
  const [root, area, child] = segments;

  if (root !== APP_SEGMENT) {
    return {
      message: `--parent must be under app/components or app/pages (got: "${rawParent}")`,
      ok: false,
    };
  }

  if (area === COMPONENTS_SEGMENT && child === UI_SEGMENT) {
    return {
      message: `--parent "${rawParent}" is under components/ui: shadcn owns components/ui, so scaffold the component elsewhere`,
      ok: false,
    };
  }

  const underComponents = area === COMPONENTS_SEGMENT;
  const underPage = area === PAGES_SEGMENT && segments.length > 2;

  if (!underComponents && !underPage) {
    return {
      message: `--parent must be under app/components or app/pages/<path> (got: "${rawParent}")`,
      ok: false,
    };
  }

  return {ok: true, parent};
};

type RunOptions = {
  /** Directory the command runs in; defaults to `process.cwd()`. The package root comes from the registry. */
  cwd?: string;
  /** Returns true if `absPath` is an existing directory. Default uses fs. */
  isDirectory?: (absPath: string) => boolean;
};

const defaultIsDirectory = (absPath: string): boolean =>
  existsSync(absPath) && statSync(absPath).isDirectory();

type RenderFileOptions = {
  componentName: string;
  folder: string;
  parent: string;
  props: readonly PropertyEntry[];
  templatesRoot: string;
};

const renderComponentFile = (options: RenderFileOptions): string => {
  const {componentName, props, templatesRoot} = options;
  const templatePath = path.join(
    templatesRoot,
    `${TEMPLATES_DIR}/index.tsx.tmpl`
  );
  const propsTypeBlock = buildPropsTypeBlock(componentName, props);
  const propsParam =
    props.length === 0 ?
      ''
    : `{${props.map((property) => property.name).join(', ')}}: ${componentName}Props`;

  return renderTemplate(templatePath, {
    Name: componentName,
    propsParam,
    propsTypeBlock,
  });
};

const renderStoryFile = (options: RenderFileOptions): string => {
  const {componentName, folder, parent, props, templatesRoot} = options;
  const templatePath = path.join(
    templatesRoot,
    `${TEMPLATES_DIR}/index.stories.tsx.tmpl`
  );

  return renderTemplate(templatePath, {
    Name: componentName,
    storyDefault: buildStoryExport('Default', componentName, props),
    storyRenders: buildStoryExport('Renders', componentName, props),
    storyTitle: buildStoryTitle(parent, folder),
  });
};

const resolveTemplatesRoot = (): string => {
  // template.ts hard-codes the templates dir resolution; we mirror it here so
  // we can build per-file paths without re-implementing renderTemplate.
  const here = fileURLToPath(import.meta.url);

  return path.join(path.dirname(here), 'templates');
};

const writeOne = (
  absPath: string,
  contents: string,
  result: ScaffoldResult
): void => {
  const {written} = writeFileIfAbsent(absPath, contents);

  if (written) {
    result.written.push(absPath);
  } else {
    result.skipped.push(absPath);
  }
};

const printHumanResult = (
  result: ScaffoldResult,
  componentName: string
): void => {
  const lines = [`Scaffolded component ${componentName}.`];

  if (result.written.length > 0) {
    lines.push('Written:');
    for (const filePath of result.written) lines.push(`  ${filePath}`);
  }

  if (result.skipped.length > 0) {
    lines.push('Skipped (unchanged):');
    for (const filePath of result.skipped) lines.push(`  ${filePath}`);
  }
  process.stdout.write(`${lines.join('\n')}\n`);
};

export const run = (
  argv: readonly string[],
  options: RunOptions = {}
): number => {
  const subcommand = argv.at(0);

  if (subcommand !== undefined && HELP_TOKENS.has(subcommand)) {
    process.stdout.write(HELP_TEXT);

    return EXIT_CODES.OK;
  }

  const parsed = parseFlags(argv);

  if (!parsed.ok) {
    structuredError({
      code: 'invalid_arguments',
      message: parsed.message,
      subcommand: 'scaffold component',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const {flags} = parsed;
  const target = resolveScaffoldTarget(
    options.cwd ?? process.cwd(),
    'scaffold component'
  );

  if (target === undefined) return EXIT_CODES.CONFIG_INVALID;
  const isDirectory = options.isDirectory ?? defaultIsDirectory;
  const checked = checkParent(
    toPackageRelative(flags.parent, target.packagePath)
  );

  if (!checked.ok) {
    structuredError({
      code: 'invalid_parent',
      message: checked.message,
      subcommand: 'scaffold component',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const {parent} = checked;
  const parentAbs = path.resolve(target.packageDir, parent);

  if (!isDirectory(parentAbs)) {
    structuredError({
      code: 'parent_not_found',
      message: `parent dir does not exist: ${flags.parent}`,
      path: parentAbs,
      subcommand: 'scaffold component',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const componentName =
    PASCAL_CASE_PATTERN.test(flags.name) ?
      flags.name
    : kebabToPascal(flags.name);
  const folder = toKebabCase(componentName);
  const componentDir = path.join(parentAbs, folder);
  const indexPath = path.join(componentDir, 'index.tsx');
  const testsDir = path.join(componentDir, 'tests');
  const storyPath = path.join(testsDir, 'index.stories.tsx');

  const templatesRoot = resolveTemplatesRoot();
  const result: ScaffoldResult = {edited: [], skipped: [], written: []};

  const renderOptions: RenderFileOptions = {
    componentName,
    folder,
    parent,
    props: flags.props,
    templatesRoot,
  };

  try {
    writeOne(indexPath, renderComponentFile(renderOptions), result);
    writeOne(storyPath, renderStoryFile(renderOptions), result);
  } catch (error) {
    structuredError({
      code: 'write_failed',
      message: error instanceof Error ? error.message : String(error),
      subcommand: 'scaffold component',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  if (flags.json) {
    process.stdout.write(`${JSON.stringify(result)}\n`);
  } else {
    printHumanResult(result, componentName);
  }

  return EXIT_CODES.OK;
};
