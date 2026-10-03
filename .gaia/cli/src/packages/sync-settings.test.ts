/**
 * Strategy: the transform is pure, so the contract (re-anchoring, byte-for-byte
 * hooks and statusLine, union-only overlay) is asserted on objects; the run
 * wrapper is driven over a temp tree for exit codes and the no-write promise
 * on every refusal.
 */
import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {writeFrontendRegistry} from '../util/package-fixture.js';
import {
  generateSettings,
  reanchorRule,
  reanchorSpec,
  SettingsGenerationError,
} from './settings-transform.js';
import {run} from './sync-settings.js';

const HOOK = {
  hooks: [
    {command: '"$(git rev-parse --show-toplevel)/h.sh"', type: 'command'},
  ],
  matcher: 'Bash',
};

const ROOT_SETTINGS = {
  hooks: {PreToolUse: [HOOK]},
  permissions: {
    allow: ['Bash(pnpm lint)', 'Edit(frontend/app/**)', 'Edit(//abs/x)'],
    deny: [
      'Edit(.env)',
      'Edit(pnpm-lock.yaml)',
      'Bash(git reset --hard HEAD~*)',
    ],
  },
  sandbox: {
    filesystem: {allowRead: ['**/.env.example'], denyRead: ['.env', '**/.env']},
  },
  statusLine: {
    command: 'bash "$(git rev-parse --show-toplevel)/s.sh"',
    type: 'command',
  },
};

describe('reanchoring', () => {
  test('prepends the prefix, drops a leading ./ or /, leaves ** // ~ alone', () => {
    expect(reanchorSpec('.env', '../')).toBe('../.env');
    expect(reanchorSpec('./a/b', '../')).toBe('../a/b');
    expect(reanchorSpec('/a', '../../')).toBe('../../a');
    expect(reanchorSpec('**/.env', '../')).toBe('**/.env');
    expect(reanchorSpec('//abs', '../')).toBe('//abs');
    expect(reanchorSpec('~/x', '../')).toBe('~/x');
  });

  test('a rule without a path copies unchanged', () => {
    expect(reanchorRule('Bash(git status)', '../', 'x')).toBe(
      'Bash(git status)'
    );
    expect(reanchorRule('WebFetch(domain:a.com)', '../', 'x')).toBe(
      'WebFetch(domain:a.com)'
    );
  });
});

describe('generateSettings', () => {
  test('re-anchors path rules and sandbox entries, copies the rest', () => {
    const output = generateSettings(ROOT_SETTINGS, {}, 'frontend') as Record<
      string,
      any
    >;

    expect(output.permissions.deny).toEqual([
      'Edit(../.env)',
      'Edit(../pnpm-lock.yaml)',
      'Bash(git reset --hard HEAD~*)',
    ]);
    expect(output.permissions.allow).toContain('Edit(../frontend/app/**)');
    expect(output.permissions.allow).toContain('Edit(//abs/x)');
    expect(output.permissions.allow).toContain('Bash(pnpm lint)');
    expect(output.permissions.additionalDirectories).toEqual(['..']);
    expect(output.sandbox.filesystem.denyRead).toEqual(['../.env', '**/.env']);
    expect(output.hooks).toEqual(ROOT_SETTINGS.hooks);
    expect(output.statusLine).toEqual(ROOT_SETTINGS.statusLine);
  });

  test('a depth-two package reaches the root with two levels', () => {
    const output = generateSettings(ROOT_SETTINGS, {}, 'a/b') as Record<
      string,
      any
    >;

    expect(output.permissions.deny[0]).toBe('Edit(../../.env)');
    expect(output.permissions.additionalDirectories).toEqual(['../..']);
  });

  test('an overlay adds allow, deny, ask, and env entries', () => {
    const output = generateSettings(
      ROOT_SETTINGS,
      {
        env: {FOO: '1'},
        permissions: {
          allow: ['Edit(app/x/**)'],
          ask: ['Bash(x)'],
          deny: ['Edit(a)'],
        },
      },
      'frontend'
    ) as Record<string, any>;

    expect(output.permissions.allow).toContain('Edit(app/x/**)');
    expect(output.permissions.ask).toEqual(['Bash(x)']);
    expect(output.permissions.deny).toContain('Edit(a)');
    expect(output.env).toEqual({FOO: '1'});
  });

  test.each([
    ['a hooks key', {hooks: {}}],
    ['a sandbox key', {sandbox: {}}],
    [
      'an additionalDirectories key',
      {permissions: {additionalDirectories: []}},
    ],
    [
      'an allow entry equal to a root deny entry',
      {permissions: {allow: ['Edit(pnpm-lock.yaml)']}},
    ],
    [
      'an ask entry equal to a re-anchored root deny entry',
      {permissions: {ask: ['Edit(../.env)']}},
    ],
    [
      'a path with a command substitution',
      {permissions: {allow: ['Edit(a$(x))']}},
    ],
    ['an env key that changes the root value', {env: {A: 'b'}}],
  ])('refuses %s', (_name, overlay) => {
    const root = {...ROOT_SETTINGS, env: {A: 'a'}};

    expect(() => generateSettings(root, overlay, 'frontend')).toThrow(
      SettingsGenerationError
    );
  });

  test('refuses a root path rule outside the charset', () => {
    const hostile = {permissions: {allow: ['Edit(a b)']}};

    expect(() => generateSettings(hostile, {}, 'frontend')).toThrow(
      /characters outside/
    );
  });
});

describe('run', () => {
  let root: string;
  const generatedFile = () => path.join(root, 'frontend/.claude/settings.json');
  const overlayFile = () =>
    path.join(root, 'frontend/.claude/settings.overlay.json');

  beforeEach(() => {
    root = mkdtempSync(path.join(tmpdir(), 'sync-settings-'));
    writeFrontendRegistry(root, 'frontend');
    mkdirSync(path.join(root, '.claude'), {recursive: true});
    mkdirSync(path.join(root, 'frontend/.claude'), {recursive: true});
    writeFileSync(
      path.join(root, '.claude/settings.json'),
      JSON.stringify(ROOT_SETTINGS)
    );
    vi.spyOn(process.stderr, 'write').mockReturnValue(true);
    vi.spyOn(process.stdout, 'write').mockReturnValue(true);
  });

  afterEach(() => {
    vi.restoreAllMocks();
    rmSync(root, {force: true, recursive: true});
  });

  test('writes the file, then reports up to date, then --check agrees', () => {
    expect(run(['--repo-root', root])).toBe(0);
    expect(readFileSync(generatedFile(), 'utf8').endsWith('}\n')).toBe(true);
    const before = statSync(generatedFile()).mtimeMs;

    expect(run(['--repo-root', root])).toBe(0);
    expect(statSync(generatedFile()).mtimeMs).toBe(before);
    expect(run(['--check', '--repo-root', root])).toBe(0);
  });

  test('--check exits 1 naming a missing file and writes nothing', () => {
    expect(run(['--check', '--repo-root', root])).toBe(1);
    expect(() => statSync(generatedFile())).toThrow(/ENOENT/);
  });

  test('a change to the overlay alone is drift', () => {
    run(['--repo-root', root]);
    writeFileSync(
      overlayFile(),
      JSON.stringify({permissions: {allow: ['Edit(extra/**)']}})
    );

    expect(run(['--check', '--repo-root', root])).toBe(1);
  });

  test('a change to a root hook command is drift', () => {
    run(['--repo-root', root]);
    const changed = structuredClone(ROOT_SETTINGS);

    changed.hooks.PreToolUse[0]!.hooks[0]!.command = 'other.sh';
    writeFileSync(
      path.join(root, '.claude/settings.json'),
      JSON.stringify(changed)
    );

    expect(run(['--check', '--repo-root', root])).toBe(1);
  });

  test.each([
    ['a hooks key', {hooks: {}}],
    ['a sandbox key', {sandbox: {}}],
    ['a removal attempt', {permissions: {allow: ['Edit(pnpm-lock.yaml)']}}],
    ['a hostile rule path', {permissions: {allow: ['Edit(a$(x))']}}],
  ])(
    'an overlay with %s exits 2 and leaves the file untouched',
    (_name, overlay) => {
      run(['--repo-root', root]);
      const before = statSync(generatedFile()).mtimeMs;
      const bytes = readFileSync(generatedFile(), 'utf8');

      writeFileSync(overlayFile(), JSON.stringify(overlay));

      expect(run(['--repo-root', root])).toBe(2);
      expect(statSync(generatedFile()).mtimeMs).toBe(before);
      expect(readFileSync(generatedFile(), 'utf8')).toBe(bytes);
      expect(run(['--check', '--repo-root', root])).toBe(2);
    }
  );

  test.each(['front end', 'frontend/../x'])(
    'a hostile registry path %j exits 2 and writes nothing',
    (hostile) => {
      writeFileSync(
        path.join(root, '.gaia/packages.json'),
        JSON.stringify([{name: 'frontend', path: hostile}])
      );

      expect(run(['--repo-root', root])).toBe(2);
      expect(() => statSync(generatedFile())).toThrow(/ENOENT/);
    }
  );

  test('unreadable root settings exit 2', () => {
    writeFileSync(path.join(root, '.claude/settings.json'), '{not json');

    expect(run(['--repo-root', root])).toBe(2);
  });

  test('an unknown argument exits 2', () => {
    expect(run(['--bogus'])).toBe(2);
  });

  test('a registry with only a root package generates nothing', () => {
    writeFrontendRegistry(root, '.');

    expect(run(['--check', '--repo-root', root])).toBe(0);
  });
});
