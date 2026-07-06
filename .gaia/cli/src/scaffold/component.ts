/**
 * `gaia scaffold component <Name>` handler.
 *
 * Replaces the prose-only `new-component` skill with deterministic file
 * emission. Produces three files (or two with `--no-story`) under
 * `app/components/<Name>/` matching the project's existing component
 * convention (`app/components/Button/`, etc.).
 *
 * Output shape (default invocation, `gaia scaffold component Foo`):
 *
 *   app/components/Foo/index.tsx
 *   app/components/Foo/tests/index.test.tsx
 *   app/components/Foo/tests/index.stories.tsx
 *
 * The `--no-story` flag drops the stories file and rewires the test imports
 * so the test is self-contained (no `composeStory` round-trip).
 *
 * The `--props "name:type,name:type"` flag turns the bare `FC` signature
 * into a typed `FC<NameProps>` and emits a Props type alias plus a
 * destructured signature. Each entry must be `name:type`; empty entries
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
import {writeFileIfAbsent} from './fs.js';
import {renderTemplate} from './template.js';
import type {ScaffoldResult} from './types.js';

const PASCAL_CASE_PATTERN = /^[A-Z][\dA-Za-z]*$/u;
const PROP_NAME_PATTERN = /^[A-Za-z_][\w$]*$/u;
const TEMPLATES_DIR = 'component';
const COMPONENTS_DEFAULT_PARENT = 'app/components';

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
  story: boolean;
};

type PropertyEntry = {
  name: string;
  type: string;
};

const HELP_TEXT = `Usage: gaia scaffold component <Name> [flags]

  --no-story          Skip the index.stories.tsx file
  --parent <dir>      Parent dir under app/components/ (default: app/components/)
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
      story: true,
    },
    ok: true,
  };
};

type TakeValueResult = {message: string; ok: false} | {ok: true; value: string};

const takeValue = (
  argv: readonly string[],
  index: number,
  flag: string
): TakeValueResult => {
  const value = argv.at(index);

  if (value === undefined || value.startsWith('--')) {
    return {message: `${flag} requires a value`, ok: false};
  }

  return {ok: true, value};
};

type ParentFlagResult =
  {message: string; ok: false} | {ok: true; parent: string};

const parseParentFlag = (
  argv: readonly string[],
  index: number
): ParentFlagResult => {
  const parsedValue = takeValue(argv, index + 1, '--parent');

  if (!parsedValue.ok) return parsedValue;

  return {ok: true, parent: parsedValue.value};
};

type PropsFlagResult =
  {message: string; ok: false} | {ok: true; props: PropertyEntry[]};

const parsePropsFlag = (
  argv: readonly string[],
  index: number
): PropsFlagResult => {
  const parsedValue = takeValue(argv, index + 1, '--props');

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
  story: boolean;
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

  if (token === '--no-story') {
    state.story = false;

    return {consumed: 0};
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
    story: true,
  };

  for (let index = 0; index < argv.length; index += 1) {
    const result = applyToken(argv, index, state);

    if ('consumed' in result) {
      index += result.consumed;
    } else {
      return result;
    }
  }

  const {json, name, parent, props, story} = state;

  if (name === undefined) {
    return {message: 'component name is required', ok: false};
  }

  if (!PASCAL_CASE_PATTERN.test(name)) {
    return {
      message: `component name must be PascalCase (got: "${name}")`,
      ok: false,
    };
  }

  return {
    flags: {
      json,
      name,
      parent,
      props,
      story,
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

  return `\ntype ${componentName}Props = {\n${entries}\n};\n`;
};

const buildPropsGeneric = (
  componentName: string,
  props: readonly PropertyEntry[]
): string => (props.length === 0 ? '' : `<${componentName}Props>`);

/**
 * A representative value literal for a prop, ready to splice into a JSX
 * attribute (`name={value}` or, for strings, the quoted form `name="value"`).
 * Primitives get an honest non-degenerate value so the scaffolded a11y test
 * renders real DOM. Exotic types fall back to a typed cast the author replaces
 * (kept type-safe so the generated test still typechecks).
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
 * The JSX the test renders. With a story, the test renders the composed
 * `Default` (props live on the story). Without a story, the component is
 * rendered directly, so required props must be supplied at the render site.
 */
const buildRenderJsx = (
  componentName: string,
  props: readonly PropertyEntry[],
  withStory: boolean
): string => {
  if (withStory || props.length === 0) return `<${componentName} />`;

  return `<${componentName} ${buildPropertyAttributes(props)} />`;
};

/**
 * The `Default` story export. With props, `Default` renders a non-degenerate
 * instance carrying representative values so the story-driven a11y check has
 * real DOM to assert against; without props it renders the bare component.
 */
const buildStoryDefault = (
  componentName: string,
  props: readonly PropertyEntry[]
): string => {
  if (props.length === 0) {
    return `export const Default: StoryFn = () => <${componentName} />;`;
  }

  return [
    'export const Default: StoryFn = () => (',
    `  <${componentName} ${buildPropertyAttributes(props)} />`,
    ');',
  ].join('\n');
};

const buildTestImports = (
  componentName: string,
  withStory: boolean
): string => {
  if (withStory) {
    return [
      "import {composeStory} from '@storybook/react-vite';",
      "import {describe, expect, test} from 'vitest';",
      "import {render} from 'test/rtl';",
      "import Meta, {Default} from './index.stories';",
      '',
      `const ${componentName} = composeStory(Default, Meta);`,
    ].join('\n');
  }

  return [
    "import {describe, expect, test} from 'vitest';",
    "import {render} from 'test/rtl';",
    `import ${componentName} from '..';`,
  ].join('\n');
};

const buildStoryTitle = (parent: string, componentName: string): string => {
  // parent is repo-relative, e.g. "app/components" or "app/components/Form".
  // Strip the "app/components" prefix so titles look like "Components/Foo"
  // (matching the existing pattern, see app/components/Button/tests/index.stories.tsx).
  const stripped = parent.replace(/^app\/components\/?/u, '');

  if (stripped === '') return `Components/${componentName}`;

  return `Components/${stripped}/${componentName}`;
};

type RunOptions = {
  /** Repo root used to resolve relative paths. Defaults to `process.cwd()`. */
  cwd?: string;
  /** Returns true if `absPath` is an existing directory. Default uses fs. */
  isDirectory?: (absPath: string) => boolean;
};

const defaultIsDirectory = (absPath: string): boolean =>
  existsSync(absPath) && statSync(absPath).isDirectory();

type RenderFileOptions = {
  componentName: string;
  parent: string;
  props: readonly PropertyEntry[];
  templatesRoot: string;
  withStory: boolean;
};

const renderComponentFile = (options: RenderFileOptions): string => {
  const {componentName, props, templatesRoot} = options;
  const templatePath = path.join(
    templatesRoot,
    `${TEMPLATES_DIR}/index.tsx.tmpl`
  );
  const propsTypeBlock = buildPropsTypeBlock(componentName, props);
  const propsGeneric = buildPropsGeneric(componentName, props);
  const propsParam =
    props.length === 0 ?
      ''
    : `{${props.map((property) => property.name).join(', ')}}`;

  return renderTemplate(templatePath, {
    Name: componentName,
    propsGeneric,
    propsParam,
    propsTypeBlock,
  });
};

const renderTestFile = (options: RenderFileOptions): string => {
  const {componentName, props, templatesRoot, withStory} = options;
  const templatePath = path.join(
    templatesRoot,
    `${TEMPLATES_DIR}/index.test.tsx.tmpl`
  );

  return renderTemplate(templatePath, {
    Name: componentName,
    renderJsx: buildRenderJsx(componentName, props, withStory),
    testImports: buildTestImports(componentName, withStory),
  });
};

const renderStoryFile = (options: RenderFileOptions): string => {
  const {componentName, parent, props, templatesRoot} = options;
  const templatePath = path.join(
    templatesRoot,
    `${TEMPLATES_DIR}/index.stories.tsx.tmpl`
  );

  return renderTemplate(templatePath, {
    Name: componentName,
    storyDefault: buildStoryDefault(componentName, props),
    storyTitle: buildStoryTitle(parent, componentName),
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
  const cwd = options.cwd ?? process.cwd();
  const isDirectory = options.isDirectory ?? defaultIsDirectory;
  const parentAbs = path.resolve(cwd, flags.parent);

  if (!isDirectory(parentAbs)) {
    structuredError({
      code: 'parent_not_found',
      message: `parent dir does not exist: ${flags.parent}`,
      path: parentAbs,
      subcommand: 'scaffold component',
    });

    return EXIT_CODES.UNKNOWN_SUBCOMMAND;
  }

  const componentDir = path.join(parentAbs, flags.name);
  const indexPath = path.join(componentDir, 'index.tsx');
  const testsDir = path.join(componentDir, 'tests');
  const testPath = path.join(testsDir, 'index.test.tsx');
  const storyPath = path.join(testsDir, 'index.stories.tsx');

  const templatesRoot = resolveTemplatesRoot();
  const result: ScaffoldResult = {edited: [], skipped: [], written: []};

  const renderOptions: RenderFileOptions = {
    componentName: flags.name,
    parent: flags.parent,
    props: flags.props,
    templatesRoot,
    withStory: flags.story,
  };

  try {
    writeOne(indexPath, renderComponentFile(renderOptions), result);
    writeOne(testPath, renderTestFile(renderOptions), result);

    if (flags.story) {
      writeOne(storyPath, renderStoryFile(renderOptions), result);
    }
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
    printHumanResult(result, flags.name);
  }

  return EXIT_CODES.OK;
};
