import {afterEach, beforeEach, describe, expect, test} from 'vitest';
import {mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {loadTemplate, renderTemplate, substituteVars} from './template.js';

type Sandbox = {
  cleanup: () => void;
  dir: string;
};

const setupSandbox = (): Sandbox => {
  const dir = mkdtempSync(path.join(tmpdir(), 'gaia-template-'));

  return {
    cleanup: () => {
      rmSync(dir, {force: true, recursive: true});
    },
    dir,
  };
};

const writeTemplateFile = (dir: string, name: string, body: string): string => {
  const filePath = path.join(dir, name);
  writeFileSync(filePath, body, 'utf8');

  return filePath;
};

describe('renderTemplate', () => {
  let sandbox: Sandbox;

  beforeEach(() => {
    sandbox = setupSandbox();
  });

  afterEach(() => {
    sandbox.cleanup();
  });

  test('substitutes scalar variables', () => {
    const filePath = writeTemplateFile(
      sandbox.dir,
      'scalar.tpl',
      'export const {{name}} = "{{value}}";'
    );

    const out = renderTemplate(filePath, {name: 'foo', value: 'bar'});

    expect(out).toBe('export const foo = "bar";');
  });

  test('omits boolean section when flag is false / missing', () => {
    const filePath = writeTemplateFile(
      sandbox.dir,
      'flag.tpl',
      'a{{#flag}}-x-{{/flag}}b'
    );

    expect(renderTemplate(filePath, {flag: false})).toBe('ab');
    expect(renderTemplate(filePath, {})).toBe('ab');
  });

  test('includes boolean section when flag is true', () => {
    const filePath = writeTemplateFile(
      sandbox.dir,
      'flag.tpl',
      'a{{#flag}}-x-{{/flag}}b'
    );

    expect(renderTemplate(filePath, {flag: true})).toBe('a-x-b');
  });

  test('iterates each blocks with {{this}}', () => {
    const filePath = writeTemplateFile(
      sandbox.dir,
      'each.tpl',
      '[{{#each items}}<{{this}}>{{/each}}]'
    );

    const out = renderTemplate(filePath, {items: ['a', 'b', 'c']});

    expect(out).toBe('[<a><b><c>]');
  });

  test('each block iterating empty array yields no body', () => {
    const filePath = writeTemplateFile(
      sandbox.dir,
      'each.tpl',
      'pre{{#each items}}X{{/each}}post'
    );

    expect(renderTemplate(filePath, {items: []})).toBe('prepost');
  });

  test('substitutes inside a true section body', () => {
    const filePath = writeTemplateFile(
      sandbox.dir,
      'mixed.tpl',
      '{{#story}}story for {{name}}{{/story}}'
    );

    const out = renderTemplate(filePath, {name: 'Foo', story: true});

    expect(out).toBe('story for Foo');
  });

  test('missing scalar renders as empty string', () => {
    const filePath = writeTemplateFile(
      sandbox.dir,
      'missing.tpl',
      'a-{{absent}}-b'
    );

    expect(renderTemplate(filePath, {})).toBe('a--b');
  });

  test('boolean scalar is stringified as true/false', () => {
    const filePath = writeTemplateFile(
      sandbox.dir,
      'bool.tpl',
      'flag={{flag}}'
    );

    expect(renderTemplate(filePath, {flag: true})).toBe('flag=true');
    expect(renderTemplate(filePath, {flag: false})).toBe('flag=false');
  });

  test('array scalar substitution joins with commas', () => {
    const filePath = writeTemplateFile(
      sandbox.dir,
      'array.tpl',
      'tags={{tags}}'
    );

    expect(renderTemplate(filePath, {tags: ['a', 'b']})).toBe('tags=a,b');
  });

  test('renders to empty when template is empty', () => {
    const filePath = writeTemplateFile(sandbox.dir, 'empty.tpl', '');

    expect(renderTemplate(filePath, {})).toBe('');
  });
});

describe('loadTemplate', () => {
  test('throws when the template file does not exist', () => {
    expect(() => loadTemplate('does-not-exist.tpl')).toThrow();
  });
});

describe('substituteVars', () => {
  let sandbox: Sandbox;

  beforeEach(() => {
    sandbox = setupSandbox();
  });

  afterEach(() => {
    sandbox.cleanup();
  });

  test('produces the same output as renderTemplate for the same body', () => {
    const body = '{{#flag}}hi {{name}}{{/flag}}';
    const filePath = writeTemplateFile(sandbox.dir, 'parity.tpl', body);
    const vars = {flag: true, name: 'world'};

    expect(substituteVars(body, vars)).toBe(renderTemplate(filePath, vars));
  });

  test('leaves GitHub Actions ${{ secrets.X }} expressions unchanged', () => {
    const out = substituteVars('GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}', {});

    expect(out).toBe('GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}');
  });
});
