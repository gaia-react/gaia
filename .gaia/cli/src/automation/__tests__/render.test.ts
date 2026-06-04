import {mkdirSync, mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {afterEach, beforeEach, describe, expect, it} from 'vitest';
import {renderWorkflowTemplate, resolvePartials} from '../render.js';
import type {WorkflowTemplateVars} from '../workflow-vars.js';

type Sandbox = {
  cleanup: () => void;
  partialsDir: string;
  root: string;
  writePartial: (name: string, body: string) => void;
  writeTemplate: (name: string, body: string) => string;
};

const setupSandbox = (): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-render-'));
  const partialsDir = path.join(root, 'partials');
  mkdirSync(partialsDir, {recursive: true});

  return {
    cleanup: () => rmSync(root, {force: true, recursive: true}),
    partialsDir,
    root,
    writePartial: (name, body) => {
      writeFileSync(path.join(partialsDir, `${name}.yml.tmpl`), body, 'utf8');
    },
    writeTemplate: (name, body) => {
      const filePath = path.join(root, name);
      writeFileSync(filePath, body, 'utf8');

      return filePath;
    },
  };
};

const baseVars: WorkflowTemplateVars = {
  config_key: 'wiki',
  cost_ceiling_dollars: 5,
  cron: '0 4 * * *',
  enable_auto_merge: true,
  enable_diff_size_check: true,
  enable_major_bump_split: false,
  enable_security_pr: false,
  enable_stale_branch_delete: false,
  needs_human_review_label: 'needs-human-review',
  pr_label: 'gaia-ci',
  schedule: 'daily',
  state_file: '.gaia/automation.state-wiki.json',
  tool_id: 'wiki',
  workflow_name: 'GAIA CI - Test',
};

describe('resolvePartials', () => {
  let sandbox: Sandbox;

  beforeEach(() => {
    sandbox = setupSandbox();
  });

  afterEach(() => {
    sandbox.cleanup();
  });

  it('replaces a partial token with the partial body', () => {
    sandbox.writePartial('foo', 'concurrency: {group: gaia-ci-test}');

    const out = resolvePartials(
      'pre {{> partials/foo }} post',
      sandbox.partialsDir
    );

    expect(out).toBe('pre concurrency: {group: gaia-ci-test} post');
  });

  it('tolerates whitespace variants of the partial token', () => {
    sandbox.writePartial('foo', 'X');

    expect(resolvePartials('{{>partials/foo}}', sandbox.partialsDir)).toBe('X');
    expect(resolvePartials('{{>  partials/foo  }}', sandbox.partialsDir)).toBe(
      'X'
    );
    expect(resolvePartials('{{> partials/foo }}', sandbox.partialsDir)).toBe(
      'X'
    );
  });

  it('replaces multiple partial tokens in one pass', () => {
    sandbox.writePartial('foo', 'F');
    sandbox.writePartial('bar', 'B');

    const out = resolvePartials(
      '{{> partials/foo }} | {{> partials/bar }}',
      sandbox.partialsDir
    );

    expect(out).toBe('F | B');
  });

  it('supports kebab-case partial names', () => {
    sandbox.writePartial('auto-merge', 'AM');
    sandbox.writePartial('cost-accounting', 'CA');

    const out = resolvePartials(
      '{{> partials/auto-merge }} | {{> partials/cost-accounting }}',
      sandbox.partialsDir
    );

    expect(out).toBe('AM | CA');
  });

  it('throws when a partial body contains {{>', () => {
    sandbox.writePartial('outer', '{{> partials/inner }}');
    sandbox.writePartial('inner', 'body');

    expect(() =>
      resolvePartials('{{> partials/outer }}', sandbox.partialsDir)
    ).toThrow(/partial 'outer' contains '\{\{>'/u);
  });

  it('throws with a clear message when a partial file is missing', () => {
    expect(() =>
      resolvePartials('{{> partials/nope }}', sandbox.partialsDir)
    ).toThrow(/partial 'nope' could not be read/u);
  });

  it('returns the input unchanged when no partial tokens are present', () => {
    expect(resolvePartials('plain content here', sandbox.partialsDir)).toBe(
      'plain content here'
    );
  });
});

describe('renderWorkflowTemplate', () => {
  let sandbox: Sandbox;

  beforeEach(() => {
    sandbox = setupSandbox();
  });

  afterEach(() => {
    sandbox.cleanup();
  });

  it('substitutes scalar variables', () => {
    const tmpl = sandbox.writeTemplate(
      'scalar.yml.tmpl',
      'name: {{workflow_name}}\ncron: {{cron}}'
    );

    const out = renderWorkflowTemplate(tmpl, sandbox.partialsDir, baseVars);

    expect(out).toBe('name: GAIA CI - Test\ncron: 0 4 * * *');
  });

  it('renders boolean section bodies based on flag value', () => {
    const tmpl = sandbox.writeTemplate(
      'flag.yml.tmpl',
      'a{{#enable_diff_size_check}}-on-{{/enable_diff_size_check}}b'
    );

    expect(renderWorkflowTemplate(tmpl, sandbox.partialsDir, baseVars)).toBe(
      'a-on-b'
    );

    expect(
      renderWorkflowTemplate(tmpl, sandbox.partialsDir, {
        ...baseVars,
        enable_diff_size_check: false,
      })
    ).toBe('ab');
  });

  it('inlines a partial then resolves variables inside it', () => {
    sandbox.writePartial('header', 'name: {{workflow_name}}');
    const tmpl = sandbox.writeTemplate(
      'with-partial.yml.tmpl',
      '{{> partials/header }}\nrest'
    );

    const out = renderWorkflowTemplate(tmpl, sandbox.partialsDir, baseVars);

    expect(out).toBe('name: GAIA CI - Test\nrest');
  });

  it('produces output with no remaining {{ or }} tokens', () => {
    sandbox.writePartial('hdr', 'name: {{workflow_name}}\ncron: {{cron}}');
    const tmpl = sandbox.writeTemplate(
      'full.yml.tmpl',
      '{{> partials/hdr }}\n{{#enable_diff_size_check}}flag-on{{/enable_diff_size_check}}'
    );

    const out = renderWorkflowTemplate(tmpl, sandbox.partialsDir, baseVars);

    expect(out).not.toContain('{{');
    expect(out).not.toContain('}}');
  });

  it('preserves GitHub Actions ${{ secrets.X }} expressions verbatim', () => {
    const tmpl = sandbox.writeTemplate(
      'gh.yml.tmpl',
      'env:\n  GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}\n  TOOL: {{tool_id}}'
    );

    const out = renderWorkflowTemplate(tmpl, sandbox.partialsDir, baseVars);

    expect(out).toContain('${{ secrets.GITHUB_TOKEN }}');
    expect(out).toContain('TOOL: wiki');
  });

  it('throws when a partial recursively includes another partial', () => {
    sandbox.writePartial('outer', '{{> partials/inner }}');
    sandbox.writePartial('inner', 'X');
    const tmpl = sandbox.writeTemplate('t.yml.tmpl', '{{> partials/outer }}');

    expect(() =>
      renderWorkflowTemplate(tmpl, sandbox.partialsDir, baseVars)
    ).toThrow(/partial 'outer' contains '\{\{>'/u);
  });
});
