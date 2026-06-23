/**
 * `gaia scaffold component <Name>` handler.
 *
 * Replaces the prose-only `new-component` skill with deterministic file
 * emission. Produces three files (or two with `--no-story`) under
 * `app/components/<Name>/` matching the project's existing component
 * convention (`app/components/Button/`, `app/components/GaiaLogo/`, etc.).
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
 * and malformed pairs are rejected with exit 1. Commas separate props, so
 * comma-bearing types (`Record<K, V>`, `(a, b) => void`, tuples) are not
 * supported and are rejected with exit 1; pass one `--props` flag per prop.
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
const PROP_ENTRY_PATTERN = /^([A-Za-z_][\w$]*)\s*:\s*(.+)$/u;
const TEMPLATES_DIR = 'component';
const COMPONENTS_DEFAULT_PARENT = 'app/components';

const BRACKET_PAIRS: Record<string, string> = {'(': ')', '<': '>', '[': ']', '{': '}'};
const CLOSERS = new Set(Object.values(BRACKET_PAIRS));

/**
 * Split a `--props` value on prop-separating commas only. A comma at bracket
 * depth 0 separates props; a comma inside a bracket pair (`<>`, `()`, `[]`,
 * `{}`) belongs to a comma-bearing type (`Record<string, unknown>`,
 * `(id: string, ev: Event) => void`, a tuple `[string, number]`).
 *
 * `hasNestedComma` is true when any depth>0 comma is present. The honest-reject
 * path uses that flag today; the segment list it returns is the seam a future
 * change would use to split on depth-0 commas instead of rejecting.
 */
const splitTopLevelCommas = (
  raw: string
): {hasNestedComma: boolean; segments: string[]} => {
  const segments: string[] = [];
  let depth = 0;
  let current = '';
  let hasNestedComma = false;

  for (const char of raw) {
    if (char in BRACKET_PAIRS) {
      depth += 1;
    } else if (CLOSERS.has(char) && depth > 0) {
      depth -= 1;
    }

    if (char === ',') {
      if (depth > 0) {
        hasNestedComma = true;
      } else {
        segments.push(current);
        current = '';
        continue;
      }
    }

    current += char;
  }

  segments.push(current);

  return {hasNestedComma, segments};
};

type ParsedFlags = {
  json: boolean;
  name: string;
  parent: string;
  props: PropEntry[];
  story: boolean;
};

type PropEntry = {
  name: string;
  type: string;
};

type FlagParseSuccess = {
  flags: ParsedFlags;
  ok: true;
};

type FlagParseFailure = {
  message: string;
  ok: false;
};

type FlagParseResult = FlagParseFailure | FlagParseSuccess;

const HELP_TEXT = `Usage: gaia scaffold component <Name> [flags]

  --no-story          Skip the index.stories.tsx file
  --parent <dir>      Parent dir under app/components/ (default: app/components/)
  --props "a:string,b:number"
                      Typed props rendered as a Props type alias.
                      Comma-bearing types (Record<K, V>, (a, b) => void,
                      tuples) are not supported; pass one --props flag per prop.
  --json              Emit ScaffoldResult JSON on stdout
`;

const HELP_TOKENS = new Set(['--help', '-h', 'help']);

const parseProps = (raw: string): FlagParseResult => {
  const {hasNestedComma, segments} = splitTopLevelCommas(raw);

  if (hasNestedComma) {
    return {
      message: `--props value contains a comma-bearing type (got: "${raw}"); comma-bearing types (Record<K, V>, (a, b) => void, tuples) are not supported. Pass one --props flag per prop, or split the type out.`,
      ok: false,
    };
  }

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

  const props: PropEntry[] = [];

  for (const entry of entries) {
    const match = PROP_ENTRY_PATTERN.exec(entry);

    if (match === null) {
      return {
        message: `--props entry must be name:type (got: "${entry}")`,
        ok: false,
      };
    }

    props.push({name: match[1] as string, type: (match[2] as string).trim()});
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

const takeValue = (
  argv: readonly string[],
  index: number,
  flag: string
): FlagParseResult | string => {
  const value = argv[index];

  if (value === undefined || value.startsWith('--')) {
    return {message: `${flag} requires a value`, ok: false};
  }

  return value;
};

const parseFlags = (argv: readonly string[]): FlagParseResult => {
  let name: string | undefined;
  let parent = COMPONENTS_DEFAULT_PARENT;
  let story = true;
  let json = false;
  let props: PropEntry[] = [];

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index] as string;

    if (token === '--no-story') {
      story = false;
      continue;
    }

    if (token === '--json') {
      json = true;
      continue;
    }

    if (token === '--parent') {
      const value = takeValue(argv, index + 1, '--parent');

      if (typeof value !== 'string') return value;
      parent = value;
      index += 1;
      continue;
    }

    if (token === '--props') {
      const value = takeValue(argv, index + 1, '--props');

      if (typeof value !== 'string') return value;
      const parsed = parseProps(value);

      if (!parsed.ok) return parsed;
      props = parsed.flags.props;
      index += 1;
      continue;
    }

    if (token.startsWith('--')) {
      return {message: `unknown flag: ${token}`, ok: false};
    }

    if (name === undefined) {
      name = token;
      continue;
    }

    return {message: `unexpected positional argument: ${token}`, ok: false};
  }

  if (name === undefined) {
    return {message: 'component name is required', ok: false};
  }

  if (!PASCAL_CASE_PATTERN.test(name)) {
    return {
      message: `component name must be PascalCase (got: "${name}")`,
      ok: false,
    };
  }

  return {flags: {json, name, parent, props, story}, ok: true};
};

const buildPropsTypeBlock = (
  componentName: string,
  props: readonly PropEntry[]
): string => {
  if (props.length === 0) return '';
  const entries = props
    .map((prop) => `  ${prop.name}: ${prop.type};`)
    .join('\n');

  return `\ntype ${componentName}Props = {\n${entries}\n};\n`;
};

const buildPropsGeneric = (
  componentName: string,
  props: readonly PropEntry[]
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

const buildPropAttribute = (prop: PropEntry): string => {
  const type = prop.type;

  if (type === 'string') return `${prop.name}="${prop.name}"`;
  if (type === 'number') return `${prop.name}={0}`;
  if (type === 'boolean') return `${prop.name}={true}`;
  if (type.endsWith('[]')) return `${prop.name}={[]}`;
  // Function-typed props get a callable no-op cast: `({} as () => void)()`
  // throws TypeError the moment an author wires the prop into the render body,
  // so the fallback must be invocable, not an empty-object cast.
  if (isFunctionType(type)) {
    return `${prop.name}={(() => undefined) as ${type}}`;
  }

  return `${prop.name}={{} as ${type}}`;
};

const buildPropAttributes = (props: readonly PropEntry[]): string =>
  props.map(buildPropAttribute).join(' ');

/**
 * The JSX the test renders. With a story, the test renders the composed
 * `Default` (props live on the story). Without a story, the component is
 * rendered directly, so required props must be supplied at the render site.
 */
const buildRenderJsx = (
  componentName: string,
  props: readonly PropEntry[],
  withStory: boolean
): string => {
  if (withStory || props.length === 0) return `<${componentName} />`;

  return `<${componentName} ${buildPropAttributes(props)} />`;
};

/**
 * The `Default` story export. With props, `Default` renders a non-degenerate
 * instance carrying representative values so the story-driven a11y check has
 * real DOM to assert against; without props it renders the bare component.
 */
const buildStoryDefault = (
  componentName: string,
  props: readonly PropEntry[]
): string => {
  if (props.length === 0) {
    return `export const Default: StoryFn = () => <${componentName} />;`;
  }

  return [
    'export const Default: StoryFn = () => (',
    `  <${componentName} ${buildPropAttributes(props)} />`,
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
  props: readonly PropEntry[];
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
    props.length === 0 ? '' : `{${props.map((prop) => prop.name).join(', ')}}`;

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
  const subcommand = argv[0];

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
