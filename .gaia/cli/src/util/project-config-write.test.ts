import {afterEach, beforeEach, describe, expect, test} from 'vitest';
import {
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
import {projectConfigPath} from '../schemas/project-config.js';
import {updateProjectConfig} from './project-config-write.js';

describe('updateProjectConfig', () => {
  let root: string;

  beforeEach(() => {
    root = mkdtempSync(path.join(tmpdir(), 'gaia-project-config-write-'));
  });

  afterEach(() => {
    rmSync(root, {force: true, recursive: true});
  });

  const seed = (text: string): void => {
    mkdirSync(path.join(root, '.gaia'), {recursive: true});
    writeFileSync(projectConfigPath(root), text, 'utf8');
  };

  const read = (): string => readFileSync(projectConfigPath(root), 'utf8');

  test('creates .gaia and the file with version 1 when both are absent', () => {
    updateProjectConfig(root, {isolation_policy: 'prefer-worktree'});

    expect(read()).toBe(
      '{\n  "version": 1,\n  "isolation_policy": "prefer-worktree"\n}\n'
    );
  });

  test('merges onto existing keys and keeps unknown keys', () => {
    seed(
      JSON.stringify({
        future: 'x',
        isolation_policy: 'prefer-branch',
        version: 1,
      })
    );

    updateProjectConfig(root, {sandbox_recommended: true});

    expect(JSON.parse(read())).toEqual({
      future: 'x',
      isolation_policy: 'prefer-branch',
      sandbox_recommended: true,
      version: 1,
    });
  });

  test.each(['on', 'off', 'maybe'])(
    'carries a retired dependabot_security_updates value %j through byte-for-byte',
    (value) => {
      seed(
        `{\n  "version": 1,\n  "dependabot_security_updates": "${value}"\n}\n`
      );

      updateProjectConfig(root, {isolation_policy: 'prefer-branch'});

      expect(read()).toBe(
        `{\n  "version": 1,\n  "dependabot_security_updates": "${value}",\n  "isolation_policy": "prefer-branch"\n}\n`
      );
    }
  );

  test('sets version 1 on an existing file that lacks it', () => {
    seed(JSON.stringify({isolation_policy: 'prefer-branch'}));

    updateProjectConfig(root, {sandbox_recommended: false});

    expect(JSON.parse(read())).toMatchObject({version: 1});
  });

  test('leaves no temporary file beside the target after a write', () => {
    updateProjectConfig(root, {sandbox_recommended: true});

    expect(readdirSync(path.join(root, '.gaia'))).toEqual(['project.json']);
  });

  test.each([{isolation_policy: 'sometimes'}, {sandbox_recommended: 'true'}])(
    'refuses an invalid known key %j and writes nothing',
    (patch) => {
      expect(() => {
        updateProjectConfig(root, patch);
      }).toThrow(expect.objectContaining({kind: 'invalid_value'}));
      expect(existsSync(projectConfigPath(root))).toBe(false);
    }
  );

  test('an invalid known key leaves an existing file byte-identical', () => {
    seed('{"version": 1, "future": "x"}\n');
    const before = read();

    expect(() => {
      updateProjectConfig(root, {isolation_policy: 'sometimes'});
    }).toThrow(expect.objectContaining({kind: 'invalid_value'}));
    expect(read()).toBe(before);
  });

  test('throws a malformed error naming the file and leaves it unchanged', () => {
    seed('{not json');

    expect(() => {
      updateProjectConfig(root, {isolation_policy: 'prefer-branch'});
    }).toThrow(expect.objectContaining({kind: 'malformed'}));
    expect(() => {
      updateProjectConfig(root, {isolation_policy: 'prefer-branch'});
    }).toThrow(/project\.json/u);
    expect(read()).toBe('{not json');
  });

  test('refuses a non-object file as malformed', () => {
    seed('[]');

    expect(() => {
      updateProjectConfig(root, {sandbox_recommended: true});
    }).toThrow(expect.objectContaining({kind: 'malformed'}));
    expect(read()).toBe('[]');
  });
});
