import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import {writeFrontendRegistry} from '../util/package-fixture.js';
import {run as runConfigureI18n} from './configure-i18n.js';
import {run as runRename} from './rename.js';
import {run as runStripBranding} from './strip-branding.js';

const write = (root: string, relative: string, contents: string): void => {
  mkdirSync(path.dirname(path.join(root, relative)), {recursive: true});
  writeFileSync(path.join(root, relative), contents, 'utf8');
};

const read = (root: string, relative: string): string =>
  readFileSync(path.join(root, relative), 'utf8');

const PREVIEW = `const BRAND = {
  brandTarget: '_blank',
  brandTitle: 'GAIA',
  brandUrl: 'https://gaiareact.com/docs/',
};
`;

describe('gaia init commands resolve the frontend package root', () => {
  let root: string;
  let stderrWrites: string[];

  beforeEach(() => {
    root = mkdtempSync(path.join(tmpdir(), 'gaia-init-package-root-'));
    stderrWrites = [];
    vi.spyOn(process.stderr, 'write').mockImplementation((chunk: unknown) => {
      stderrWrites.push(String(chunk));

      return true;
    });
    vi.spyOn(process.stdout, 'write').mockImplementation(() => true);
  });

  afterEach(() => {
    vi.restoreAllMocks();
    rmSync(root, {force: true, recursive: true});
  });

  test('configure-i18n edits frontend/app and touches no root app/', () => {
    write(
      root,
      'frontend/app/i18n.ts',
      "const i18n = {\n  fallbackLng: 'en',\n};\n"
    );
    write(root, 'frontend/app/languages/index.ts', 'export {};\n');

    expect(
      runConfigureI18n(['--locales', 'fr,en', '--strip', 'false'], {cwd: root})
    ).toBe(EXIT_CODES.OK);

    expect(read(root, 'frontend/app/i18n.ts')).toContain("fallbackLng: 'fr'");
    expect(read(root, 'frontend/app/languages/index.ts')).toContain(
      "LANGUAGES = ['fr', 'en']"
    );
    expect(existsSync(path.join(root, 'app'))).toBe(false);
  });

  test('rename edits the frontend language files and touches no root app/', () => {
    write(root, 'package.json', '{"name": "gaia"}\n');
    write(root, 'CLAUDE.md', '# GAIA React\n\nBody\n');
    write(
      root,
      'frontend/app/languages/en/common.ts',
      "export default {\n  meta: {\n    siteName: 'GAIA',\n  },\n};\n"
    );

    expect(
      runRename(['--title', 'Hello World', '--kebab', 'hello-world'], {
        cwd: root,
      })
    ).toBe(EXIT_CODES.OK);

    expect(read(root, 'frontend/app/languages/en/common.ts')).toContain(
      "siteName: 'Hello World'"
    );
    expect(existsSync(path.join(root, 'app'))).toBe(false);
  });

  test('strip-branding de-brands frontend/.storybook and touches no root .storybook', () => {
    write(root, 'frontend/.storybook/preview.ts', PREVIEW);
    write(root, '.gaia/templates/README.md', '# {{PROJECT_TITLE}}\n');

    expect(runStripBranding(['--title', 'Hello World'], {cwd: root})).toBe(
      EXIT_CODES.OK
    );

    expect(read(root, 'frontend/.storybook/preview.ts')).toContain(
      'Hello World'
    );
    expect(existsSync(path.join(root, '.storybook'))).toBe(false);
  });

  test('a path-"." registry keeps the edits at the repo root', () => {
    writeFrontendRegistry(root, '.');
    write(root, '.storybook/preview.ts', PREVIEW);
    write(root, '.gaia/templates/README.md', '# {{PROJECT_TITLE}}\n');

    expect(runStripBranding(['--title', 'Hello World'], {cwd: root})).toBe(
      EXIT_CODES.OK
    );

    expect(read(root, '.storybook/preview.ts')).toContain('Hello World');
    expect(existsSync(path.join(root, 'frontend'))).toBe(false);
  });

  test.each([
    [
      'configure-i18n',
      () =>
        runConfigureI18n(['--locales', 'en', '--strip', 'false'], {cwd: root}),
    ],
    ['rename', () => runRename(['--title', 'T', '--kebab', 't'], {cwd: root})],
    ['strip-branding', () => runStripBranding(['--title', 'T'], {cwd: root})],
  ])(
    '%s refuses on a malformed registry and writes nothing',
    (_name, invoke) => {
      write(root, '.gaia/packages.json', '{not json');
      write(root, 'package.json', '{"name": "gaia"}\n');
      write(root, 'CLAUDE.md', '# GAIA React\n');

      expect(invoke()).toBe(EXIT_CODES.CONFIG_INVALID);

      expect(stderrWrites.join('')).toContain('gaia-packages:');
      expect(read(root, 'package.json')).toBe('{"name": "gaia"}\n');
      expect(read(root, 'CLAUDE.md')).toBe('# GAIA React\n');
      expect(existsSync(path.join(root, '.gaia/local'))).toBe(false);
    }
  );
});
