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
import {
  afterEach,
  beforeEach,
  describe,
  expect,
  test,
  vi,
} from 'vitest';
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
    const exit = run(['Foo', '--parent', 'app/components'], {cwd: sandbox.root});

    expect(exit).toBe(0);

    const indexPath = path.join(sandbox.parent, 'Foo', 'index.tsx');
    const testPath = path.join(sandbox.parent, 'Foo', 'tests', 'index.test.tsx');
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
    expect(testContents).toContain(
      "import {composeStory} from '@storybook/react-vite';"
    );
    expect(testContents).toContain('const Foo = composeStory(Default, Meta);');
    expect(testContents).toContain("describe('Foo'");

    const storyContents = read(storyPath);
    expect(storyContents).toContain("import Foo from '..';");
    expect(storyContents).toContain("title: 'Components/Foo',");
    expect(storyContents).toContain('export const Default: StoryFn = () => <Foo />;');
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

    expect(() => read(storyPath)).toThrow();

    const testContents = read(
      path.join(sandbox.parent, 'Bar', 'tests', 'index.test.tsx')
    );
    expect(testContents).not.toContain('composeStory');
    expect(testContents).toContain("import Bar from '../index';");
  });

  test('--props renders a typed Props alias and destructured signature', () => {
    const exit = run(
      ['Card', '--parent', 'app/components', '--props', 'title:string,count:number'],
      {cwd: sandbox.root}
    );

    expect(exit).toBe(0);

    const indexContents = read(
      path.join(sandbox.parent, 'Card', 'index.tsx')
    );
    expect(indexContents).toContain('type CardProps = {');
    expect(indexContents).toContain('  title: string;');
    expect(indexContents).toContain('  count: number;');
    expect(indexContents).toContain(
      'const Card: FC<CardProps> = ({title, count}) => ('
    );
  });

  test('lowercase name exits 1 with PascalCase message', () => {
    const exit = run(['foo', '--parent', 'app/components'], {cwd: sandbox.root});

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
    const first = run(['Foo', '--parent', 'app/components'], {cwd: sandbox.root});
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
    const first = run(['Foo', '--parent', 'app/components'], {cwd: sandbox.root});
    expect(first).toBe(0);

    // Mutate the index file so the second run sees a conflict.
    const indexPath = path.join(sandbox.parent, 'Foo', 'index.tsx');
    const altered = `${read(indexPath)}\n// user customization\n`;
    writeFileSync(indexPath, altered, 'utf8');

    const second = run(['Foo', '--parent', 'app/components'], {cwd: sandbox.root});
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

  // Sanity check: the test setup is still valid even if templates move.
  test('templates dir resolves to an existing path', () => {
    expect(() => copyFileSync(
      path.join(TEMPLATES_SOURCE, 'index.tsx.tmpl'),
      path.join(sandbox.root, 'check.tmpl')
    )).not.toThrow();
  });
});
