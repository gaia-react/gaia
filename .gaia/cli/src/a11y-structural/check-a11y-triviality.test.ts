/**
 * Tests for the structural a11y-triviality floor AST helper
 * (`.gaia/scripts/a11y-structural/check-a11y-triviality.mjs`).
 *
 * The helper is the judge-INDEPENDENT producer of the non-triviality signal. It
 * inspects an a11y test file (one calling the emergent-signal a11y helpers
 * `expectNoA11yViolations` / `runAxe`) and flags a vacuous render as an advisory
 * non-triviality fix, with no LLM judge in the loop. It flags an a11y test when
 * EITHER its `render(...)` passes no props / only defaults, OR its rendered
 * markup carries no interactive or landmark node while the component's stories
 * declare interactive variants. The floor is ADVISORY: it surfaces a `fix`, it
 * never blocks.
 *
 * Maintainer-only by construction: `.gaia/scripts` is release-excluded, so the
 * helper and this test never ship to adopters.
 *
 * The helper resolves `typescript` from `node_modules`; this `.gaia/cli`
 * workspace carries its own `typescript` devDependency, so the test runner can
 * exec it. Synthetic test fixtures feed through `--stdin` (the path argument
 * names the file identity for `.ts`-vs-`.tsx` script kind; stdin supplies the
 * bytes); a stories fixture is written to a temp file and passed via
 * `--stories <path>`.
 */
import {execFileSync} from 'node:child_process';
import {existsSync, mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {afterEach, describe, expect, it} from 'vitest';

const resolveRepoRoot = (): string => {
  let dir = path.dirname(fileURLToPath(import.meta.url));

  for (let attempts = 0; attempts < 20; attempts += 1) {
    if (existsSync(path.join(dir, '.git'))) {
      return dir;
    }
    const parent = path.dirname(dir);

    if (parent === dir) break;
    dir = parent;
  }

  throw new Error('Could not find repo root (no .git directory found)');
};

const REPO_ROOT = resolveRepoRoot();
const HELPER = path.join(
  REPO_ROOT,
  '.gaia/scripts/a11y-structural/check-a11y-triviality.mjs'
);

// The helper resolves `typescript` by walking up from its own location to the
// repo-root node_modules. The CLI Tests CI job installs deps only in
// `.gaia/cli`, so typescript lives there, not at the (uninstalled) repo root.
// Expose `.gaia/cli/node_modules` via NODE_PATH so the exec'd helper resolves
// typescript whether or not the repo root is installed.
const HELPER_ENV = {
  ...process.env,
  NODE_PATH: path.join(REPO_ROOT, '.gaia/cli/node_modules'),
};

type Finding = {fullName: string; reason: string};
type Verdict = {
  file: string;
  findings: Finding[];
  verdict: 'non-trivial' | 'not-a11y' | 'trivial';
};

const tmpDirs: string[] = [];

afterEach(() => {
  while (tmpDirs.length > 0) {
    const dir = tmpDirs.pop();
    if (dir) rmSync(dir, {force: true, recursive: true});
  }
});

// Write a synthetic stories file to a temp dir and return its path.
const writeStories = (stories: string): string => {
  const dir = mkdtempSync(path.join(tmpdir(), 'a11y-stories-'));
  tmpDirs.push(dir);
  const file = path.join(dir, 'index.stories.tsx');
  writeFileSync(file, stories);
  return file;
};

// Check synthetic test-file bytes fed through stdin. `fileIdentity` is the
// repo-relative path used for script-kind selection. `stories`, when supplied,
// is written to a temp file and passed via `--stories <path>`.
const check = (
  fileIdentity: string,
  source: string,
  stories?: string
): Verdict => {
  const args = [HELPER, fileIdentity, '--stdin'];
  if (stories !== undefined) {
    args.push('--stories', writeStories(stories));
  }

  const out = execFileSync('node', args, {
    cwd: REPO_ROOT,
    encoding: 'utf8',
    input: source,
    env: HELPER_ENV,
  });

  return JSON.parse(out) as Verdict;
};

describe('check-a11y-triviality', () => {
  it('emits the {file, verdict, findings} contract shape', () => {
    const result = check(
      'app/components/Spinner/tests/index.test.tsx',
      [
        "import {expectNoA11yViolations} from 'test/a11y';",
        "import {render} from 'test/rtl';",
        "import Spinner from '..';",
        "test('a11y', async () => {",
        '  const {container} = render(<Spinner size="lg" />);',
        '  await expectNoA11yViolations(container);',
        '});',
      ].join('\n')
    );

    expect(result.file).toBe('app/components/Spinner/tests/index.test.tsx');
    expect(['non-trivial', 'not-a11y', 'trivial']).toContain(result.verdict);
    expect(Array.isArray(result.findings)).toBe(true);
  });

  describe('not an a11y test file', () => {
    it('returns not-a11y for a file with no a11y-helper call', () => {
      const result = check(
        'app/components/Foo/tests/index.test.tsx',
        [
          "import {render, screen} from 'test/rtl';",
          "import Foo from '..';",
          "test('renders', () => {",
          '  render(<Foo title="hi" />);',
          "  expect(screen.getByText('hi')).toBeInTheDocument();",
          '});',
        ].join('\n')
      );

      expect(result.verdict).toBe('not-a11y');
      expect(result.findings).toHaveLength(0);
    });
  });

  describe('condition A: render passes no props or only defaults', () => {
    it('flags an a11y test whose render passes NO props', () => {
      const result = check(
        'app/components/Button/tests/index.test.tsx',
        [
          "import {expectNoA11yViolations} from 'test/a11y';",
          "import {render} from 'test/rtl';",
          "import Button from '..';",
          "test('a11y', async () => {",
          '  const {container} = render(<Button>Test</Button>);',
          '  await expectNoA11yViolations(container);',
          '});',
        ].join('\n')
      );

      expect(result.verdict).toBe('trivial');
      expect(result.findings).toHaveLength(1);
      expect(result.findings[0].fullName).toBe('a11y');
      expect(result.findings[0].reason).toMatch(/no props|default/i);
    });

    it('flags a self-closing render with zero attributes', () => {
      // `runAxe` is an a11y signal too. A self-closing render with zero
      // attributes carries no props.
      const result = check(
        'app/components/Badge/tests/index.test.tsx',
        [
          "import {runAxe} from 'test/a11y';",
          "import {render} from 'test/rtl';",
          "import Badge from '..';",
          "test('axe', async () => {",
          '  const {container} = render(<Badge />);',
          '  const results = await runAxe(container);',
          '  expect(results.violations).toEqual([]);',
          '});',
        ].join('\n')
      );

      expect(result.verdict).toBe('trivial');
      expect(result.findings[0].reason).toMatch(/no props|default/i);
    });

    it('does NOT flag (condition A) an a11y test whose render passes real props', () => {
      // Props supplied AND no stories declaring interactive variants -> the
      // structural floor has nothing to flag.
      const result = check(
        'app/components/Avatar/tests/index.test.tsx',
        [
          "import {expectNoA11yViolations} from 'test/a11y';",
          "import {render} from 'test/rtl';",
          "import Avatar from '..';",
          "test('a11y', async () => {",
          '  const {container} = render(<Avatar src="/me.png" alt="Me" />);',
          '  await expectNoA11yViolations(container);',
          '});',
        ].join('\n')
      );

      expect(result.verdict).toBe('non-trivial');
      expect(result.findings).toHaveLength(0);
    });
  });

  describe('condition B: no interactive/landmark node while stories declare interactive variants', () => {
    it('flags a render with props but no interactive markup when stories declare interactive variants', () => {
      const stories = [
        "import type {Meta, StoryFn} from '@storybook/react-vite';",
        "import Card from '..';",
        'const meta: Meta = {component: Card};',
        'export default meta;',
        'export const Default: StoryFn = () => <Card title="hi" />;',
        'export const Clickable: StoryFn = () => (',
        '  <Card title="hi" onClick={() => undefined} />',
        ');',
      ].join('\n');

      const result = check(
        'app/components/Card/tests/index.test.tsx',
        [
          "import {expectNoA11yViolations} from 'test/a11y';",
          "import {render} from 'test/rtl';",
          "import Card from '..';",
          "test('a11y', async () => {",
          // props supplied (escapes condition A), but the rendered markup has no
          // interactive/landmark host node.
          '  const {container} = render(<Card title="hi" subtitle="yo" />);',
          '  await expectNoA11yViolations(container);',
          '});',
        ].join('\n'),
        stories
      );

      expect(result.verdict).toBe('trivial');
      expect(result.findings[0].reason).toMatch(/interactive|landmark|variant/i);
    });

    it('does NOT flag (condition B) when the render itself contains an interactive host node', () => {
      const stories = [
        "import type {Meta, StoryFn} from '@storybook/react-vite';",
        "import Field from '..';",
        'const meta: Meta = {component: Field};',
        'export default meta;',
        'export const Default: StoryFn = () => <Field />;',
        'export const WithInput: StoryFn = () => <Field onChange={() => undefined} />;',
      ].join('\n');

      const result = check(
        'app/components/Field/tests/index.test.tsx',
        [
          "import {expectNoA11yViolations} from 'test/a11y';",
          "import {render} from 'test/rtl';",
          "import Field from '..';",
          "test('a11y', async () => {",
          // an interactive host node (<button>) is present in the render markup.
          '  const {container} = render(',
          '    <Field label="Name"><button type="button">Go</button></Field>',
          '  );',
          '  await expectNoA11yViolations(container);',
          '});',
        ].join('\n'),
        stories
      );

      expect(result.verdict).toBe('non-trivial');
      expect(result.findings).toHaveLength(0);
    });

    it('does NOT flag (condition B) when stories declare no interactive variant', () => {
      const stories = [
        "import type {Meta, StoryFn} from '@storybook/react-vite';",
        "import Note from '..';",
        'const meta: Meta = {component: Note};',
        'export default meta;',
        'export const Default: StoryFn = () => <Note title="hi" body="yo" />;',
      ].join('\n');

      const result = check(
        'app/components/Note/tests/index.test.tsx',
        [
          "import {expectNoA11yViolations} from 'test/a11y';",
          "import {render} from 'test/rtl';",
          "import Note from '..';",
          "test('a11y', async () => {",
          '  const {container} = render(<Note title="hi" body="static text" />);',
          '  await expectNoA11yViolations(container);',
          '});',
        ].join('\n'),
        stories
      );

      expect(result.verdict).toBe('non-trivial');
      expect(result.findings).toHaveLength(0);
    });
  });

  describe('multiple tests in one file', () => {
    it('only flags the a11y test, never the behavior tests', () => {
      const result = check(
        'app/components/Toggle/tests/index.test.tsx',
        [
          "import userEvent from '@testing-library/user-event';",
          "import {expectNoA11yViolations} from 'test/a11y';",
          "import {render, screen} from 'test/rtl';",
          "import Toggle from '..';",
          "describe('Toggle', () => {",
          "  test('toggles on click', async () => {",
          '    render(<Toggle />);',
          "    await userEvent.click(screen.getByRole('switch'));",
          "    expect(screen.getByRole('switch')).toBeChecked();",
          '  });',
          "  test('a11y', async () => {",
          '    const {container} = render(<Toggle />);',
          '    await expectNoA11yViolations(container);',
          '  });',
          '});',
        ].join('\n')
      );

      expect(result.verdict).toBe('trivial');
      expect(result.findings).toHaveLength(1);
      expect(result.findings[0].fullName).toBe('Toggle a11y');
    });
  });
});
