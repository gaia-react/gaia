import {afterEach, beforeEach, describe, expect, test} from 'vitest';
import {mkdirSync, mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {
  isDependabotSecurityUpdates,
  isIsolationPolicy,
  projectConfigPath,
  ProjectConfigSchema,
  readProjectConfig,
} from '../project-config.js';

describe('ProjectConfigSchema', () => {
  test('parses a config with every key', () => {
    expect(
      ProjectConfigSchema.parse({
        dependabot_security_updates: 'on',
        isolation_policy: 'prefer-branch',
        sandbox_recommended: true,
        version: 1,
      })
    ).toEqual({
      dependabot_security_updates: 'on',
      isolation_policy: 'prefer-branch',
      sandbox_recommended: true,
      version: 1,
    });
  });

  test('an empty object parses, with version degrading to 1', () => {
    expect(ProjectConfigSchema.parse({})).toEqual({version: 1});
  });

  test('invalid or wrong-typed values degrade to undefined instead of malforming', () => {
    const parsed = ProjectConfigSchema.parse({
      dependabot_security_updates: 'sometimes',
      isolation_policy: 'worktree-ish',
      sandbox_recommended: 'yes',
      version: 9,
    });

    expect(parsed.dependabot_security_updates).toBeUndefined();
    expect(parsed.isolation_policy).toBeUndefined();
    expect(parsed.sandbox_recommended).toBeUndefined();
    expect(parsed.version).toBe(1);
  });

  test('the guards accept only the known literals', () => {
    expect(isIsolationPolicy('always-worktree')).toBe(true);
    expect(isIsolationPolicy('worktree')).toBe(false);
    expect(isDependabotSecurityUpdates('off')).toBe(true);
    expect(isDependabotSecurityUpdates('maybe')).toBe(false);
  });
});

describe('readProjectConfig', () => {
  let root: string;

  beforeEach(() => {
    root = mkdtempSync(path.join(tmpdir(), 'gaia-project-config-'));
  });

  afterEach(() => {
    rmSync(root, {force: true, recursive: true});
  });

  const write = (text: string): void => {
    mkdirSync(path.join(root, '.gaia'), {recursive: true});
    writeFileSync(projectConfigPath(root), text, 'utf8');
  };

  test('projectConfigPath names .gaia/project.json under the root', () => {
    expect(projectConfigPath(root)).toBe(
      path.join(root, '.gaia', 'project.json')
    );
  });

  test('reports missing when the file is absent', () => {
    expect(readProjectConfig(root)).toEqual({status: 'missing'});
  });

  test('reports ok with the unstripped raw object', () => {
    write(JSON.stringify({isolation_policy: 'prefer-worktree', other: 1}));

    expect(readProjectConfig(root)).toEqual({
      config: {isolation_policy: 'prefer-worktree', version: 1},
      raw: {isolation_policy: 'prefer-worktree', other: 1},
      status: 'ok',
    });
  });

  test('narrows an unknown isolation value to undefined while keeping it in raw', () => {
    write(JSON.stringify({isolation_policy: 'bogus'}));

    const result = readProjectConfig(root);

    expect(result.status).toBe('ok');
    expect(result).toMatchObject({
      config: {isolation_policy: undefined},
      raw: {isolation_policy: 'bogus'},
    });
  });

  test('reports malformed for invalid JSON, naming the file', () => {
    write('{not json');

    const result = readProjectConfig(root);

    expect(result).toMatchObject({status: 'malformed'});
    expect(JSON.stringify(result)).toContain('project.json');
  });

  test('reports malformed when the JSON is not an object', () => {
    write('[]');

    expect(readProjectConfig(root).status).toBe('malformed');
  });
});
