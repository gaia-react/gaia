/**
 * Tests for the `gaia scaffold component` handler.
 *
 * Strategy: copy the three component templates into a temp dir's
 * `templates/component/` so the handler can resolve them via the same
 * `fileURLToPath(import.meta.url)`-relative scheme it uses in production,
 * then invoke `run` with `--parent` pointing into the temp tree. We assert
 * on stdout (captured), the produced filesystem contents, and the exit
 * codes.
 */
import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {
  copyFileSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {run} from './component.js';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const TEMPLATES_SOURCE = path.join(HERE, 'templates', 'component');

type Sandbox = {
  cleanup: () => void;
  parent: string;
  root: string;
};

const setupSandbox = (): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-scaffold-component-'));
  const parent = path.join(root, 'app', 'components');
  mkdirSync(parent, {recursive: true});

  return {
    cleanup: () => {
      rmSync(root, {force: true, recursive: true});
    },
    parent,
    root,
  };
};

type StdioCapture = {
  errors: string[];
  outputs: string[];
  restore: () => void;
};

const captureStdio = (): StdioCapture => {
  const outputs: string[] = [];
  const errors: string[] = [];
  const stdoutSpy = vi
    .spyOn(process.stdout, 'write')
    .mockImplementation((chunk: unknown) => {
      outputs.push(typeof chunk === 'string' ? chunk : String(chunk));

      return true;
    });
  const stderrSpy = vi
    .spyOn(process.stderr, 'write')
    .mockImplementation((chunk: unknown) => {
      errors.push(typeof chunk === 'string' ? chunk : String(chunk));

      return true;
    });

  return {
    errors,
    outputs,
    restore: () => {
      stdoutSpy.mockRestore();
      stderrSpy.mockRestore();
    },
  };
};

const read = (filePath: string): string => readFileSync(filePath, 'utf8');

// Built from fragments so Vitest's environment scanner never sees the literal
// directive token in this file. This is a Node CLI test; if the scanner reads
// the token it forces jsdom, which is absent from the isolated CLI install, so
// the forks worker fails to start. The interpolation is load-bearing, not
// cosmetic: the eslint autofix would inline it to a plain string and reinstate a
// real directive. The scanner reads comments too, so no comment here (including
// this one) may spell the token out either.
// eslint-disable-next-line @typescript-eslint/no-unnecessary-template-expression -- keep the split; see note above
const JSDOM_ENV_DIRECTIVE = `// @vitest-${'environment'} jsdom`;

describe('scaffold component', () => {
  let sandbox: Sandbox;
  let stdio: StdioCapture;

  beforeEach(() => {
    sandbox = setupSandbox();
    stdio = captureStdio();
  });

  afterEach(() => {
    stdio.restore();
    sandbox.cleanup();
    vi.restoreAllMocks();
  });

  test('default invocation produces three files matching component shape', () => {
    const exit = run(['Foo', '--parent', 'app/components'], {
      cwd: sandbox.root,
    });

    expect(exit).toBe(0);

    const indexPath = path.join(sandbox.parent, 'Foo', 'index.tsx');
    const testPath = path.join(
      sandbox.parent,
      'Foo',
      'tests',
      'index.test.tsx'
    );
    const storyPath = path.join(
      sandbox.parent,
      'Foo',
      'tests',
      'index.stories.tsx'
    );

    const indexContents = read(indexPath);
    expect(indexContents).toContain("import type {FC} from 'react';");
    expect(indexContents).toContain('const Foo: FC = () => (');
    expect(indexContents).toContain('export default Foo;');
    expect(indexContents).not.toContain('FooProps');

    const testContents = read(testPath);
    expect(testContents.startsWith(`${JSDOM_ENV_DIRECTIVE}\n`)).toBe(true);
    expect(testContents).toContain(
      "import {composeStory} from '@storybook/react-vite';"
    );
    expect(testContents).toContain(
      "import {expectNoA11yViolations} from 'test/a11y';"
    );
    expect(testContents).toContain('const Foo = composeStory(Default, Meta);');
    expect(testContents).toContain("describe('Foo'");
    expect(testContents).toContain("test('a11y', async () => {");
    expect(testContents).toContain('await expectNoA11yViolations(container);');

    const storyContents = read(storyPath);
    expect(storyContents).toContain("import Foo from '..';");
    expect(storyContents).toContain("title: 'Components/Foo',");
    expect(storyContents).toContain(
      'export const Default: StoryFn = () => <Foo />;'
    );
  });

  test('--no-story drops the stories file and rewires the test imports', () => {
    const exit = run(['Bar', '--parent', 'app/components', '--no-story'], {
      cwd: sandbox.root,
    });

    expect(exit).toBe(0);

    const storyPath = path.join(
      sandbox.parent,
      'Bar',
      'tests',
      'index.stories.tsx'
    );

    expect(() => read(storyPath)).toThrow(/ENOENT/);

    const testContents = read(
      path.join(sandbox.parent, 'Bar', 'tests', 'index.test.tsx')
    );
    expect(testContents.startsWith(`${JSDOM_ENV_DIRECTIVE}\n`)).toBe(true);
    expect(testContents).not.toContain('composeStory');
    expect(testContents).toContain("import Bar from '..'");
    expect(testContents).toContain(
      "import {expectNoA11yViolations} from 'test/a11y';"
    );
    expect(testContents).toContain("test('a11y', async () => {");
  });

  test('--props renders a typed Props alias and destructured signature', () => {
    const exit = run(
      [
        'Card',
        '--parent',
        'app/components',
        '--props',
        'title:string,count:number',
      ],
      {cwd: sandbox.root}
    );

    expect(exit).toBe(0);

    const indexContents = read(path.join(sandbox.parent, 'Card', 'index.tsx'));
    expect(indexContents).toContain('type CardProps = {');
    expect(indexContents).toContain('  title: string;');
    expect(indexContents).toContain('  count: number;');
    expect(indexContents).toContain(
      'const Card: FC<CardProps> = ({title, count}) => ('
    );
  });

  test('--props story Default renders a non-degenerate instance with representative prop values', () => {
    const exit = run(
      [
        'Card',
        '--parent',
        'app/components',
        '--props',
        'title:string,count:number',
      ],
      {cwd: sandbox.root}
    );

    expect(exit).toBe(0);

    const storyContents = read(
      path.join(sandbox.parent, 'Card', 'tests', 'index.stories.tsx')
    );
    // Default must carry representative props, not a bare `<Card />`, so the
    // story-driven a11y check renders against a real DOM and can fail.
    expect(storyContents).toContain('export const Default: StoryFn = () => (');
    expect(storyContents).toContain('title="title"');
    expect(storyContents).toContain('count={0}');
    expect(storyContents).not.toContain('=> <Card />;');

    // The a11y test renders the composed Default, which now carries props.
    const testContents = read(
      path.join(sandbox.parent, 'Card', 'tests', 'index.test.tsx')
    );
    expect(testContents).toContain('const Card = composeStory(Default, Meta);');
    expect(testContents).toContain('await expectNoA11yViolations(container);');
  });

  test('--props --no-story test renders the component with representative props', () => {
    const exit = run(
      [
        'Bar',
        '--parent',
        'app/components',
        '--props',
        'label:string',
        '--no-story',
      ],
      {cwd: sandbox.root}
    );

    expect(exit).toBe(0);

    const testContents = read(
      path.join(sandbox.parent, 'Bar', 'tests', 'index.test.tsx')
    );
    expect(testContents).not.toContain('composeStory');
    expect(testContents).toContain("import Bar from '..'");
    // Required props must be supplied at the render site so the test typechecks
    // and renders a non-degenerate instance the a11y check can fail against.
    expect(testContents).toContain('render(<Bar label="label" />)');
    expect(testContents).toContain('await expectNoA11yViolations(container);');
  });

  test('no-props a11y test carries a starting-point caveat comment', () => {
    const exit = run(['Foo', '--parent', 'app/components'], {
      cwd: sandbox.root,
    });

    expect(exit).toBe(0);

    const testContents = read(
      path.join(sandbox.parent, 'Foo', 'tests', 'index.test.tsx')
    );
    // The render-only a11y check is a starting point, not complete a11y
    // evidence (consistent with the tracer-bullet/a11y caveat).
    expect(testContents.toLowerCase()).toContain('starting point');
  });

  test('lowercase name exits 1 with PascalCase message', () => {
    const exit = run(['foo', '--parent', 'app/components'], {
      cwd: sandbox.root,
    });

    expect(exit).toBe(1);
    const errorLine = stdio.errors.join('');
    expect(errorLine).toContain('PascalCase');
  });

  test('non-existent parent dir exits 1', () => {
    const exit = run(['Foo', '--parent', 'app/missing'], {cwd: sandbox.root});

    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('parent dir does not exist');
  });

  test('--json emits a single JSON line matching ScaffoldResult', () => {
    const exit = run(['Foo', '--parent', 'app/components', '--json'], {
      cwd: sandbox.root,
    });

    expect(exit).toBe(0);
    const out = stdio.outputs.join('');
    const parsed = JSON.parse(out.trim()) as {
      edited: string[];
      skipped: string[];
      written: string[];
    };
    expect(parsed.edited).toEqual([]);
    expect(parsed.written).toHaveLength(3);
    expect(parsed.skipped).toEqual([]);
  });

  test('re-running with the same args is a no-op (skipped)', () => {
    const first = run(['Foo', '--parent', 'app/components'], {
      cwd: sandbox.root,
    });
    expect(first).toBe(0);

    const second = run(['Foo', '--parent', 'app/components', '--json'], {
      cwd: sandbox.root,
    });
    expect(second).toBe(0);

    const out = stdio.outputs.at(-1) ?? '';
    const parsed = JSON.parse(out.trim()) as {
      edited: string[];
      skipped: string[];
      written: string[];
    };
    expect(parsed.skipped).toHaveLength(3);
    expect(parsed.written).toEqual([]);
  });

  test('re-running with conflicting contents exits 1', () => {
    const first = run(['Foo', '--parent', 'app/components'], {
      cwd: sandbox.root,
    });
    expect(first).toBe(0);

    // Mutate the index file so the second run sees a conflict.
    const indexPath = path.join(sandbox.parent, 'Foo', 'index.tsx');
    const altered = `${read(indexPath)}\n// user customization\n`;
    writeFileSync(indexPath, altered, 'utf8');

    const second = run(['Foo', '--parent', 'app/components'], {
      cwd: sandbox.root,
    });
    expect(second).toBe(1);
    expect(stdio.errors.join('')).toContain('refusing to overwrite');
  });

  test('story title respects nested parent dir', () => {
    mkdirSync(path.join(sandbox.parent, 'Form'), {recursive: true});

    const exit = run(['Field', '--parent', 'app/components/Form'], {
      cwd: sandbox.root,
    });
    expect(exit).toBe(0);

    const storyContents = read(
      path.join(sandbox.parent, 'Form', 'Field', 'tests', 'index.stories.tsx')
    );
    expect(storyContents).toContain("title: 'Components/Form/Field',");
  });

  test('malformed --props entry exits 1', () => {
    const exit = run(['Foo', '--parent', 'app/components', '--props', 'oops'], {
      cwd: sandbox.root,
    });
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('--props entry must be name:type');
  });

  test('comma-bearing Record type scaffolds a single prop with the full type', () => {
    const exit = run(
      [
        'Widget',
        '--parent',
        'app/components',
        '--props',
        'meta:Record<string, unknown>',
      ],
      {cwd: sandbox.root}
    );

    expect(exit).toBe(0);

    const indexContents = read(
      path.join(sandbox.parent, 'Widget', 'index.tsx')
    );
    expect(indexContents).toContain('type WidgetProps = {');
    expect(indexContents).toContain('  meta: Record<string, unknown>;');
    expect(indexContents).toContain(
      'const Widget: FC<WidgetProps> = ({meta}) => ('
    );
  });

  test('comma-bearing tuple type scaffolds a single prop with the full type', () => {
    const exit = run(
      [
        'Pair',
        '--parent',
        'app/components',
        '--props',
        'pair:[string, number]',
      ],
      {cwd: sandbox.root}
    );

    expect(exit).toBe(0);

    const indexContents = read(path.join(sandbox.parent, 'Pair', 'index.tsx'));
    expect(indexContents).toContain('  pair: [string, number];');
    expect(indexContents).toContain(
      'const Pair: FC<PairProps> = ({pair}) => ('
    );
  });

  test('a plain prop and a comma-bearing prop separate into two props', () => {
    const exit = run(
      [
        'Card',
        '--parent',
        'app/components',
        '--props',
        'title:string,meta:Record<string, unknown>',
      ],
      {cwd: sandbox.root}
    );

    expect(exit).toBe(0);

    const indexContents = read(path.join(sandbox.parent, 'Card', 'index.tsx'));
    expect(indexContents).toContain('  title: string;');
    expect(indexContents).toContain('  meta: Record<string, unknown>;');
    expect(indexContents).toContain(
      'const Card: FC<CardProps> = ({title, meta}) => ('
    );
  });

  test('multi-arg function prop scaffolds one prop with a callable no-op fallback', () => {
    const exit = run(
      [
        'Picker',
        '--parent',
        'app/components',
        '--props',
        'onSelect:(id: string, ev: Event) => void',
        '--no-story',
      ],
      {cwd: sandbox.root}
    );

    expect(exit).toBe(0);

    const indexContents = read(
      path.join(sandbox.parent, 'Picker', 'index.tsx')
    );
    expect(indexContents).toContain(
      '  onSelect: (id: string, ev: Event) => void;'
    );
    expect(indexContents).toContain(
      'const Picker: FC<PickerProps> = ({onSelect}) => ('
    );

    const testContents = read(
      path.join(sandbox.parent, 'Picker', 'tests', 'index.test.tsx')
    );
    // The render attribute must be a CALLABLE no-op cast, so wiring the prop
    // into the render body survives being invoked with arguments.
    expect(testContents).toContain(
      'onSelect={(() => undefined) as (id: string, ev: Event) => void}'
    );
    expect(testContents).not.toContain('onSelect={{} as');
  });

  test('single-arg function prop scaffolds with a callable no-op fallback (not {} as)', () => {
    const exit = run(
      [
        'Clicker',
        '--parent',
        'app/components',
        '--props',
        'onClick:() => void',
        '--no-story',
      ],
      {cwd: sandbox.root}
    );

    expect(exit).toBe(0);

    const testContents = read(
      path.join(sandbox.parent, 'Clicker', 'tests', 'index.test.tsx')
    );
    // The render attribute must be a CALLABLE no-op cast, so wiring the prop
    // into the render body would not throw at call time.
    expect(testContents).toContain('onClick={(() => undefined) as () => void}');
    expect(testContents).not.toContain('onClick={{} as');
  });

  // Sanity check: the test setup is still valid even if templates move.
  test('templates dir resolves to an existing path', () => {
    expect(() =>
      copyFileSync(
        path.join(TEMPLATES_SOURCE, 'index.tsx.tmpl'),
        path.join(sandbox.root, 'check.tmpl')
      )
    ).not.toThrow();
  });
});
