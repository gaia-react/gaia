import {load as parseYaml} from 'js-yaml';
import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
import {execFileSync} from 'node:child_process';
import {mkdirSync, readFileSync, writeFileSync} from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {EXIT_CODES} from '../../exit.js';
import {NPM_ENTRY_LINES, run} from '../write-dependabot-config.js';
import {setupSandbox} from './sandbox.js';
import type {Sandbox} from './sandbox.js';

// Resolved relative to this test file so it works from any cwd and needs no
// hardcoded absolute path: the single source of truth every dep-bump-title
// consumer (tests.yml, chromatic.yml,
// pr-merge-audit-check.sh) shares.
const CHORE_DEPS_SKIP_SCRIPT = fileURLToPath(
  new URL('../../../../scripts/chore-deps-skip.sh', import.meta.url)
);

// A Dependabot security update touches only manifests, the one diff shape
// the chore(deps) skip predicate lets a matching title skip on.
const choreDepsSkip = (subject: string) =>
  execFileSync('bash', [CHORE_DEPS_SKIP_SCRIPT, subject], {
    encoding: 'utf8',
    input: 'package.json\npnpm-lock.yaml\n',
  }).trim();

const captureStdio = (): {
  err: string[];
  out: string[];
  restore: () => void;
} => {
  const out: string[] = [];
  const err: string[] = [];
  const stdoutSpy = vi
    .spyOn(process.stdout, 'write')
    .mockImplementation((chunk: unknown) => {
      out.push(typeof chunk === 'string' ? chunk : String(chunk));

      return true;
    });
  const stderrSpy = vi
    .spyOn(process.stderr, 'write')
    .mockImplementation((chunk: unknown) => {
      err.push(typeof chunk === 'string' ? chunk : String(chunk));

      return true;
    });

  return {
    err,
    out,
    restore: () => {
      stdoutSpy.mockRestore();
      stderrSpy.mockRestore();
    },
  };
};

const readOut = (
  stdio: ReturnType<typeof captureStdio>
): Record<string, unknown> =>
  JSON.parse(stdio.out.join('').trim()) as Record<string, unknown>;

const githubDir = (root: string): string => path.join(root, '.github');
const ymlPath = (root: string): string =>
  path.join(githubDir(root), 'dependabot.yml');
const yamlPath = (root: string): string =>
  path.join(githubDir(root), 'dependabot.yaml');

const EXPECTED_FRESH_FILE = `# Rendered by /setup-gaia (Dependabot security updates opt-in).
# open-pull-requests-limit: 0 disables version updates, so /update-deps owns
# routine upgrades; security-update pull requests are not subject to that
# limit. The group collapses each batch of security fixes into one pull
# request. cooldown does not apply to security updates; pnpm's
# minimumReleaseAge still does, so a fix younger than the window fails the
# pull request's install until it ages out or is excluded by hand. The
# "fix" prefix is deliberate: a chore(deps) title would trip the dep-bump
# bypass and skip the test suite and the audit.
version: 2
updates:
  - package-ecosystem: "npm"
    directory: "/"
    schedule:
      interval: "weekly"
    open-pull-requests-limit: 0
    groups:
      npm-security:
        applies-to: security-updates
        patterns:
          - "*"
    labels:
      - "dependencies"
      - "security"
    commit-message:
      prefix: "fix"
      include: "scope"
`;

describe('setup-ci write-dependabot-config', () => {
  let sandbox: Sandbox;
  let stdio: ReturnType<typeof captureStdio>;

  beforeEach(() => {
    sandbox = setupSandbox('gaia-setup-ci-write-dependabot-config-');
    stdio = captureStdio();
  });

  afterEach(() => {
    stdio.restore();
    sandbox.cleanup();
    vi.restoreAllMocks();
  });

  test('fresh render is byte-exact', () => {
    const exit = run([], {cwd: sandbox.root});
    expect(exit).toBe(EXIT_CODES.OK);

    const written = readFileSync(ymlPath(sandbox.root), 'utf8');
    expect(written).toBe(EXPECTED_FRESH_FILE);

    const parsed = readOut(stdio);
    expect(parsed.status).toBe('created');
    expect(parsed.path).toBe('.github/dependabot.yml');
  });

  test('fresh render parses to a single npm entry with the security-update shape', () => {
    run([], {cwd: sandbox.root});

    const parsed = parseYaml(readFileSync(ymlPath(sandbox.root), 'utf8')) as {
      updates: Record<string, unknown>[];
    };

    expect(parsed.updates).toHaveLength(1);
    const entry = parsed.updates[0] as Record<string, unknown>;
    expect(entry['package-ecosystem']).toBe('npm');
    expect(entry['open-pull-requests-limit']).toBe(0);

    const groups = entry.groups as Record<string, Record<string, unknown>>;
    const npmSecurityGroup = groups['npm-security'];
    expect(npmSecurityGroup?.['applies-to']).toBe('security-updates');
    expect(npmSecurityGroup?.patterns).toEqual(['*']);
  });

  test('merge into a file with a github-actions entry and comments keeps both and adds npm', () => {
    mkdirSync(githubDir(sandbox.root), {recursive: true});
    const original = `# existing comment
version: 2
updates:
  # keep this
  - package-ecosystem: "github-actions"
    directory: "/"
    schedule:
      interval: "daily"
`;
    writeFileSync(ymlPath(sandbox.root), original, 'utf8');

    const exit = run([], {cwd: sandbox.root});
    expect(exit).toBe(EXIT_CODES.OK);

    const written = readFileSync(ymlPath(sandbox.root), 'utf8');
    expect(written).toContain('# existing comment');
    expect(written).toContain('# keep this');

    const parsed = parseYaml(written) as {
      updates: Record<string, unknown>[];
    };
    expect(parsed.updates).toHaveLength(2);
    expect(parsed.updates[0]?.['package-ecosystem']).toBe('github-actions');
    expect(parsed.updates[1]?.['package-ecosystem']).toBe('npm');
    expect(parsed.updates[1]?.['open-pull-requests-limit']).toBe(0);

    expect(readOut(stdio).status).toBe('merged');
  });

  test('.yaml only is merged in place', () => {
    mkdirSync(githubDir(sandbox.root), {recursive: true});
    const original = `version: 2
updates:
  - package-ecosystem: "github-actions"
    directory: "/"
    schedule:
      interval: "daily"
`;
    writeFileSync(yamlPath(sandbox.root), original, 'utf8');

    const exit = run([], {cwd: sandbox.root});
    expect(exit).toBe(EXIT_CODES.OK);

    const parsed = readOut(stdio);
    expect(parsed.status).toBe('merged');
    expect(parsed.path).toBe('.github/dependabot.yaml');

    const written = parseYaml(readFileSync(yamlPath(sandbox.root), 'utf8')) as {
      updates: Record<string, unknown>[];
    };
    expect(written.updates).toHaveLength(2);
  });

  test('both .yml and .yaml present: .yml is preferred and .yaml is left untouched', () => {
    mkdirSync(githubDir(sandbox.root), {recursive: true});
    const ymlOriginal = `version: 2
updates:
  - package-ecosystem: "github-actions"
    directory: "/"
    schedule:
      interval: "daily"
`;
    const yamlOriginal = `version: 2
updates:
  - package-ecosystem: "docker"
    directory: "/"
    schedule:
      interval: "daily"
`;
    writeFileSync(ymlPath(sandbox.root), ymlOriginal, 'utf8');
    writeFileSync(yamlPath(sandbox.root), yamlOriginal, 'utf8');

    const exit = run([], {cwd: sandbox.root});
    expect(exit).toBe(EXIT_CODES.OK);

    const parsed = readOut(stdio);
    expect(parsed.path).toBe('.github/dependabot.yml');

    expect(readFileSync(yamlPath(sandbox.root), 'utf8')).toBe(yamlOriginal);

    const written = parseYaml(readFileSync(ymlPath(sandbox.root), 'utf8')) as {
      updates: Record<string, unknown>[];
    };
    expect(written.updates).toHaveLength(2);
  });

  test('an existing npm entry reports npm_entry_exists and leaves the file byte-unchanged', () => {
    mkdirSync(githubDir(sandbox.root), {recursive: true});
    const original = `version: 2
updates:
  - package-ecosystem: "npm"
    directory: "/"
    schedule:
      interval: "daily"
`;
    writeFileSync(ymlPath(sandbox.root), original, 'utf8');

    const exit = run([], {cwd: sandbox.root});
    expect(exit).toBe(EXIT_CODES.OK);
    expect(readOut(stdio).status).toBe('npm_entry_exists');
    expect(readFileSync(ymlPath(sandbox.root), 'utf8')).toBe(original);
  });

  test('malformed YAML is reported unmergeable/malformed and left unchanged', () => {
    mkdirSync(githubDir(sandbox.root), {recursive: true});
    const original = 'version: 2\nupdates: [1, 2\n';
    writeFileSync(ymlPath(sandbox.root), original, 'utf8');

    const exit = run([], {cwd: sandbox.root});
    expect(exit).toBe(EXIT_CODES.CONFIG_INVALID);

    const parsed = readOut(stdio);
    expect(parsed.status).toBe('unmergeable');
    expect(parsed.reason).toBe('malformed');
    expect(parsed.entry).toBe(NPM_ENTRY_LINES.join('\n'));
    expect(readFileSync(ymlPath(sandbox.root), 'utf8')).toBe(original);
  });

  test('a top-level key after `updates:` is reported unmergeable/updates_not_last and left unchanged', () => {
    mkdirSync(githubDir(sandbox.root), {recursive: true});
    const original = `version: 2
updates:
  - package-ecosystem: "github-actions"
    directory: "/"
    schedule:
      interval: "daily"
registries:
  npm-registry:
    type: npm-registry
`;
    writeFileSync(ymlPath(sandbox.root), original, 'utf8');

    const exit = run([], {cwd: sandbox.root});
    expect(exit).toBe(EXIT_CODES.CONFIG_INVALID);

    const parsed = readOut(stdio);
    expect(parsed.status).toBe('unmergeable');
    expect(parsed.reason).toBe('updates_not_last');
    expect(readFileSync(ymlPath(sandbox.root), 'utf8')).toBe(original);
  });

  test('4-space item indentation is honored', () => {
    mkdirSync(githubDir(sandbox.root), {recursive: true});
    const original = `version: 2
updates:
    - package-ecosystem: "github-actions"
      directory: "/"
      schedule:
        interval: "daily"
`;
    writeFileSync(ymlPath(sandbox.root), original, 'utf8');

    const exit = run([], {cwd: sandbox.root});
    expect(exit).toBe(EXIT_CODES.OK);

    const written = readFileSync(ymlPath(sandbox.root), 'utf8');
    expect(written).toContain('    - package-ecosystem: "npm"');

    const parsed = parseYaml(written) as {
      updates: Record<string, unknown>[];
    };
    expect(parsed.updates).toHaveLength(2);
    expect(parsed.updates[1]?.['package-ecosystem']).toBe('npm');
  });

  test('--json is accepted and does not change the output shape', () => {
    const exit = run(['--json'], {cwd: sandbox.root});
    expect(exit).toBe(EXIT_CODES.OK);
    expect(readOut(stdio).status).toBe('created');
  });

  test('rejects unknown flags', () => {
    const exit = run(['--bogus'], {cwd: sandbox.root});
    expect(exit).not.toBe(0);
    expect(stdio.err.join('')).toContain('unknown flag');
  });

  test('--help exits 0', () => {
    const exit = run(['--help'], {cwd: sandbox.root});
    expect(exit).toBe(0);
    expect(stdio.out.join('')).toContain('Usage:');
  });

  // Pins the criterion-0 hazard: a `chore(deps)` PR title makes the shipped
  // tests.yml skip the test suite and pr-merge-audit-check.sh
  // allow the merge without an audit. This entry must render `fix`, not
  // `chore`, on its commit-message prefix.
  test('the rendered commit-message prefix never trips the chore(deps) skip predicate', () => {
    const prefixLine = NPM_ENTRY_LINES.find((line) => line.includes('prefix:'));
    expect(prefixLine).toContain('"fix"');
    expect(prefixLine).not.toContain('chore');

    expect(choreDepsSkip('chore(deps): bump the npm-security group')).toBe(
      'true'
    );
    expect(choreDepsSkip('fix(deps): bump the npm-security group')).toBe(
      'false'
    );
    expect(choreDepsSkip('fix(deps-dev): bump x')).toBe('false');
  });
});
