/**
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
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {writeFrontendRegistry} from '../util/package-fixture.js';
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
  writeFrontendRegistry(root);

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

  test('default invocation produces the component and its story, no test file', () => {
    const exit = run(['Foo', '--parent', 'app/components'], {
      cwd: sandbox.root,
    });

    expect(exit).toBe(0);

    const indexPath = path.join(sandbox.parent, 'foo', 'index.tsx');
    const testPath = path.join(
      sandbox.parent,
      'foo',
      'tests',
      'index.test.tsx'
    );
    const storyPath = path.join(
      sandbox.parent,
      'foo',
      'tests',
      'index.stories.tsx'
    );

    const indexContents = read(indexPath);
    expect(indexContents).not.toMatch(/\bFC\b/);
    expect(indexContents.startsWith('\n')).toBe(false);
    expect(indexContents).toContain('const Foo = () => (');
    expect(indexContents).toContain('<section aria-label="Foo">');
    expect(indexContents).toContain('export default Foo;');
    expect(indexContents).not.toContain('FooProps');

    expect(existsSync(testPath)).toBe(false);

    const storyContents = read(storyPath);
    expect(storyContents).toContain("import Foo from '..';");
    expect(storyContents).toContain(
      "import {expect, within} from 'storybook/test';"
    );
    expect(storyContents).toContain("title: 'Components/Foo',");
    expect(storyContents).toContain(
      'export const Default: StoryFn = () => <Foo />;'
    );
    expect(storyContents).toContain(
      'export const Renders: StoryFn = () => <Foo />;'
    );
    expect(storyContents).toContain('Renders.play = async');
    expect(storyContents).toContain("getByRole('region', {name: 'Foo'})");
  });

  test('--no-story is refused: exit 1, nothing written, the story named as the test', () => {
    const exit = run(['Bar', '--parent', 'app/components', '--no-story'], {
      cwd: sandbox.root,
    });

    expect(exit).toBe(1);
    expect(existsSync(path.join(sandbox.parent, 'bar'))).toBe(false);

    const errorLine = stdio.errors.join('');
    expect(errorLine).toContain('--no-story is not supported');
    expect(errorLine).toContain("the story is the component's test");
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

    const indexContents = read(path.join(sandbox.parent, 'card', 'index.tsx'));
    expect(indexContents).toContain('type CardProps = {');
    expect(indexContents).toContain('  title: string;');
    expect(indexContents).toContain('  count: number;');
    expect(indexContents).not.toMatch(/\bFC\b/);
    expect(indexContents.startsWith('\n')).toBe(false);
    expect(indexContents).toContain(
      'const Card = ({title, count}: CardProps) => ('
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
      path.join(sandbox.parent, 'card', 'tests', 'index.stories.tsx')
    );
    // Default must carry representative props, not a bare `<Card />`, so the
    // accessibility check renders against a real DOM and can fail.
    expect(storyContents).toContain('export const Default: StoryFn = () => (');
    expect(storyContents).toContain('title="title"');
    expect(storyContents).toContain('count={0}');
    expect(storyContents).not.toContain('=> <Card />;');

    // The play story renders the same representative instance.
    expect(storyContents).toContain('export const Renders: StoryFn = () => (');
    expect(storyContents.match(/title="title"/g)).toHaveLength(2);
    expect(
      existsSync(path.join(sandbox.parent, 'card', 'tests', 'index.test.tsx'))
    ).toBe(false);
  });

  test('the play story carries a starting-point caveat comment', () => {
    const exit = run(['Foo', '--parent', 'app/components'], {
      cwd: sandbox.root,
    });

    expect(exit).toBe(0);

    const storyContents = read(
      path.join(sandbox.parent, 'foo', 'tests', 'index.stories.tsx')
    );
    // The render check is a starting point, not complete evidence.
    expect(storyContents.toLowerCase()).toContain('starting point');
  });

  test('a name in neither accepted form exits 1 and names both forms', () => {
    const exit = run(['price_tag', '--parent', 'app/components'], {
      cwd: sandbox.root,
    });

    expect(exit).toBe(1);
    const errorLine = stdio.errors.join('');
    expect(errorLine).toContain('kebab-case');
    expect(errorLine).toContain('PascalCase');
  });

  test('non-existent parent dir exits 1', () => {
    const exit = run(['Foo', '--parent', 'app/components/missing'], {
      cwd: sandbox.root,
    });

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
    expect(parsed.written).toHaveLength(2);
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
    expect(parsed.skipped).toHaveLength(2);
    expect(parsed.written).toEqual([]);
  });

  test('re-running with conflicting contents exits 1', () => {
    const first = run(['Foo', '--parent', 'app/components'], {
      cwd: sandbox.root,
    });
    expect(first).toBe(0);

    // Mutate the index file so the second run sees a conflict.
    const indexPath = path.join(sandbox.parent, 'foo', 'index.tsx');
    const altered = `${read(indexPath)}\n// user customization\n`;
    writeFileSync(indexPath, altered, 'utf8');

    const second = run(['Foo', '--parent', 'app/components'], {
      cwd: sandbox.root,
    });
    expect(second).toBe(1);
    expect(stdio.errors.join('')).toContain('refusing to overwrite');
  });

  test('story title respects nested parent dir', () => {
    mkdirSync(path.join(sandbox.parent, 'form'), {recursive: true});

    const exit = run(['Field', '--parent', 'app/components/form'], {
      cwd: sandbox.root,
    });
    expect(exit).toBe(0);

    const storyContents = read(
      path.join(sandbox.parent, 'form', 'field', 'tests', 'index.stories.tsx')
    );
    expect(storyContents).toContain("title: 'Components/Form/Field',");
  });

  describe('naming', () => {
    test('a kebab name exports the PascalCase form into the kebab folder', () => {
      const exit = run(['price-tag'], {cwd: sandbox.root});

      expect(exit).toBe(0);
      const indexContents = read(
        path.join(sandbox.parent, 'price-tag', 'index.tsx')
      );
      expect(indexContents).toContain('const PriceTag = () => (');
      expect(indexContents).toContain('export default PriceTag;');
      const storyContents = read(
        path.join(sandbox.parent, 'price-tag', 'tests', 'index.stories.tsx')
      );
      expect(storyContents).toContain("title: 'Components/PriceTag',");
    });

    test('a PascalCase name exports as given into the kebab folder', () => {
      const exit = run(['PriceBadge'], {cwd: sandbox.root});

      expect(exit).toBe(0);
      const indexContents = read(
        path.join(sandbox.parent, 'price-badge', 'index.tsx')
      );
      expect(indexContents).toContain('export default PriceBadge;');
    });

    test('an acronym PascalCase name gets the folder lodash kebabCase gives', () => {
      const exit = run(['HTMLView'], {cwd: sandbox.root});

      expect(exit).toBe(0);
      expect(
        read(path.join(sandbox.parent, 'html-view', 'index.tsx'))
      ).toContain('export default HTMLView;');
    });

    test('a PascalCase name with a digit gets a digit-split folder', () => {
      const exit = run(['Heading2'], {cwd: sandbox.root});

      expect(exit).toBe(0);
      expect(
        read(path.join(sandbox.parent, 'heading-2', 'index.tsx'))
      ).toContain('export default Heading2;');
    });

    test.each(['heading2', 'item2-card', 'h1-title'])(
      'the digit-bearing kebab name %s refuses and writes nothing',
      (name) => {
        const exit = run([name], {cwd: sandbox.root});

        expect(exit).toBe(1);
        expect(readdirSync(sandbox.parent)).toEqual([]);
        expect(stdio.errors.join('')).toContain(
          'the folder the linter expects'
        );
      }
    );

    test('the heading2 refusal names the folder the linter expects', () => {
      run(['heading2'], {cwd: sandbox.root});

      expect(stdio.errors.join('')).toContain(
        String.raw`must be \"heading-2\"`
      );
    });

    test.each(['price_tag', 'Price-Tag', '2fast', 'price-', 'priceTag'])(
      'the invalid name %s refuses and writes nothing',
      (name) => {
        const exit = run([name], {cwd: sandbox.root});

        expect(exit).toBe(1);
        expect(readdirSync(sandbox.parent)).toEqual([]);
        expect(stdio.errors.join('')).toContain('PascalCase');
      }
    );
  });

  describe('--parent', () => {
    test('a pages parent writes under the page folder with a Pages title', () => {
      mkdirSync(path.join(sandbox.root, 'app', 'pages', 'index'), {
        recursive: true,
      });

      const exit = run(['promo-banner', '--parent', 'app/pages/index'], {
        cwd: sandbox.root,
      });

      expect(exit).toBe(0);
      const dir = path.join(
        sandbox.root,
        'app',
        'pages',
        'index',
        'promo-banner'
      );
      expect(read(path.join(dir, 'index.tsx'))).toContain(
        'export default PromoBanner;'
      );
      expect(read(path.join(dir, 'tests', 'index.stories.tsx'))).toContain(
        "title: 'Pages/Index/PromoBanner',"
      );
    });

    test.each([
      'app/components/ui',
      'app/components/ui/x',
      'app/components/ui/',
    ])('the ui parent %s refuses and creates nothing', (parent) => {
      const ui = path.join(sandbox.parent, 'ui');
      mkdirSync(path.join(ui, 'x'), {recursive: true});

      const exit = run(['probe', '--parent', parent], {cwd: sandbox.root});

      expect(exit).toBe(1);
      expect(stdio.errors.join('')).toContain('shadcn');
      expect(readdirSync(ui)).toEqual(['x']);
      expect(readdirSync(path.join(ui, 'x'))).toEqual([]);
    });

    test('a ui parent that does not exist is not created', () => {
      const exit = run(['probe', '--parent', 'app/components/ui'], {
        cwd: sandbox.root,
      });

      expect(exit).toBe(1);
      expect(existsSync(path.join(sandbox.parent, 'ui'))).toBe(false);
    });

    test.each([
      'app/services',
      'app',
      'app/pages',
      'app/components/../services',
      'app/components/../components/ui',
      '../outside',
    ])('the parent %s outside the allowed folders refuses', (parent) => {
      mkdirSync(path.join(sandbox.root, 'app', 'services'), {recursive: true});
      mkdirSync(path.join(sandbox.root, 'app', 'pages'), {recursive: true});

      const exit = run(['probe', '--parent', parent], {cwd: sandbox.root});

      expect(exit).toBe(1);
      expect(stdio.errors.join('')).toContain('--parent');
      expect(readdirSync(sandbox.parent)).toEqual([]);
    });
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
      path.join(sandbox.parent, 'widget', 'index.tsx')
    );
    expect(indexContents).toContain('type WidgetProps = {');
    expect(indexContents).toContain('  meta: Record<string, unknown>;');
    expect(indexContents).toContain(
      'const Widget = ({meta}: WidgetProps) => ('
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

    const indexContents = read(path.join(sandbox.parent, 'pair', 'index.tsx'));
    expect(indexContents).toContain('  pair: [string, number];');
    expect(indexContents).toContain('const Pair = ({pair}: PairProps) => (');
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

    const indexContents = read(path.join(sandbox.parent, 'card', 'index.tsx'));
    expect(indexContents).toContain('  title: string;');
    expect(indexContents).toContain('  meta: Record<string, unknown>;');
    expect(indexContents).toContain(
      'const Card = ({title, meta}: CardProps) => ('
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
      ],
      {cwd: sandbox.root}
    );

    expect(exit).toBe(0);

    const indexContents = read(
      path.join(sandbox.parent, 'picker', 'index.tsx')
    );
    expect(indexContents).toContain(
      '  onSelect: (id: string, ev: Event) => void;'
    );
    expect(indexContents).toContain(
      'const Picker = ({onSelect}: PickerProps) => ('
    );

    const testContents = read(
      path.join(sandbox.parent, 'picker', 'tests', 'index.stories.tsx')
    );
    // The story attribute must be a CALLABLE no-op cast, so wiring the prop
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
      ],
      {cwd: sandbox.root}
    );

    expect(exit).toBe(0);

    const testContents = read(
      path.join(sandbox.parent, 'clicker', 'tests', 'index.stories.tsx')
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
