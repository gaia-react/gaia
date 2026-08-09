/**
 * Tests for `gaia wiki commit-classify`.
 *
 * Strategy: build a sandbox repo, commit a deterministic series of changes,
 * then ask the handler to classify them since the initial baseline. We
 * snapshot the suggestion + reason for each commit and assert against it.
 */
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
import {COMMIT_TYPES} from '../util/conventional-commit.js';
import {execGaiaGit} from '../util/git-env.js';
import {run} from './commit-classify.js';
import type {CommitClassification} from './commit-classify.js';

type Sandbox = {
  cleanup: () => void;
  commit: (message: string, files: Record<string, string>) => string;
  initialSha: string;
  root: string;
};

/**
 * What the sandbox actually looked like when a git command failed in it.
 *
 * `git commit` reports a broken object store as a bare
 * `fatal: could not parse HEAD` and nothing else, so a failure that only
 * appears under CI load leaves no evidence unless the fixture reads the
 * repository back itself. Every probe is best-effort: this runs on a repo
 * already known to be unhappy, so a probe that also fails records its own
 * error rather than replacing the original one.
 */
const describeSandbox = (root: string): string => {
  const probe = (args: string[]): string => {
    try {
      return execGaiaGit(args, root).replaceAll('\n', ' ');
    } catch (error) {
      // Keep the whole message, collapsed to this row's single line. Node puts
      // the failed command on the first line and git's own explanation on the
      // lines after it, so taking only the first line reports that `fsck`
      // failed while discarding the one thing that says why.
      return `<${(error instanceof Error ? error.message : String(error)).replaceAll('\n', ' ').trim()}>`;
    }
  };

  return [
    `  HEAD ref: ${probe(['rev-parse', '--symbolic-full-name', 'HEAD'])}`,
    `  HEAD sha: ${probe(['rev-parse', 'HEAD'])}`,
    `  objects:  ${probe(['count-objects', '-v'])}`,
    `  fsck:     ${probe(['fsck', '--no-progress', '--connectivity-only'])}`,
  ].join('\n');
};

/**
 * Run one git command against the sandbox.
 *
 * Routes through `execGaiaGit` rather than a bare `execFileSync('git', ...)`,
 * for the reason its docblock gives: an ambient `GIT_DIR`, `GIT_WORK_TREE`, or
 * `GIT_COMMON_DIR` overrides repository discovery for every git subprocess no
 * matter what `cwd` says, and a sandbox that inherits one silently commits
 * into whatever repository the variable names instead of into itself.
 */
const sandboxGit = (root: string, args: string[]): string => {
  try {
    return execGaiaGit(args, root);
  } catch (error) {
    const detail = error instanceof Error ? error.message : String(error);

    throw new Error(
      `sandbox git ${args.join(' ')} failed in ${root}\n${detail}\n${describeSandbox(root)}`
    );
  }
};

/**
 * Every git config a repository this fixture creates needs, identity included.
 *
 * The maintenance entries are the load-bearing ones. Every `git commit`
 * otherwise spawns a detached `git maintenance run --auto --quiet --detach`,
 * so a 25-commit scenario leaves background git processes running against a
 * sandbox that `afterEach` deletes out from under them, and one that repacks
 * while the next `git commit` is running leaves the repository holding several
 * packfiles and a HEAD whose commit object that commit can no longer parse.
 *
 * One key alone will not do it, because the spelling that gates this moved
 * when `git maintenance` replaced `git gc --auto`, and the git the fixture
 * runs under is whatever the machine or the CI runner supplies:
 *
 * - `maintenance.auto=false` is the documented gate on the spawn, and it covers
 *   the whole task set, including the `loose-objects` and `incremental-repack`
 *   tasks, which are the ones that pack.
 * - `gc.auto=0` is the gate for git predating that task set, which reaches the
 *   repository through `git gc --auto` instead. On git 2.55 it also suppresses
 *   the modern spawn on its own, so what failed in CI is not established to be
 *   this key being the weaker one; what is established is that a single key was
 *   not enough on the git that ran there.
 * - `gc.autoDetach=false` and `maintenance.autoDetach=false` are the fallback
 *   for both: a run that starts anyway finishes before the command that
 *   triggered it returns, so it can neither outlive the test nor race the next
 *   `git commit`. Both spellings are here for the control repository below
 *   rather than for the sandbox, which needs neither once the gates hold.
 *   Neither is a gate, so the control inherits both, and the control is the one
 *   repository that deliberately leaves maintenance switched on. Modern git
 *   resolves `maintenance.autoDetach` ahead of `gc.autoDetach`, so dropping it
 *   as redundant would let a global `maintenance.autoDetach = true` detach the
 *   control's run and leave it working in a directory `rmSync` is about to
 *   delete, which is the orphan this whole list exists to prevent.
 *
 * Measured on git 2.55, over the whole list rather than per entry: one spawned
 * maintenance run per commit with none of these set, zero with them. The test
 * at the bottom of this file is what keeps that true.
 */
const SANDBOX_GIT_CONFIG: [string, string][] = [
  ['user.email', 'test@example.com'],
  ['user.name', 'Test'],
  ['commit.gpgsign', 'false'],
  ['gc.auto', '0'],
  ['maintenance.auto', 'false'],
  ['gc.autoDetach', 'false'],
  ['maintenance.autoDetach', 'false'],
];

/**
 * The gates, paired with the value that explicitly turns each one off.
 *
 * The control repository cannot establish "ungated" by leaving these out.
 * Repo-local config beats global, so the sandbox is immune to whatever the
 * machine's own `~/.gitconfig` says, but a control that merely omits these
 * keys inherits it, and `gc.auto = 0` is a common thing to carry in a personal
 * dotfile. The control would then spawn nothing and the arm asserting git
 * still spawns maintenance would fail against a fixture behaving perfectly.
 * Writing git's own defaults into the control makes its condition its own.
 *
 * Named beside the list it subtracts from so the two cannot drift into
 * disagreeing about which entries are the gates.
 */
const MAINTENANCE_GATE_DEFAULTS: [string, string][] = [
  ['gc.auto', '6700'],
  ['maintenance.auto', 'true'],
];

const MAINTENANCE_GATES = new Set(
  MAINTENANCE_GATE_DEFAULTS.map(([key]) => key)
);

/** Initialize one repository this fixture owns, suppression included. */
const initSandboxRepo = (root: string, omit?: ReadonlySet<string>): void => {
  sandboxGit(root, ['init', '-q', '-b', 'main']);

  for (const [key, value] of SANDBOX_GIT_CONFIG) {
    if (!omit?.has(key)) {
      sandboxGit(root, ['config', key, value]);
    }
  }
};

const setupSandbox = (): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-wiki-classify-'));
  initSandboxRepo(root);

  const commit = (message: string, files: Record<string, string>): string => {
    for (const [relativePath, contents] of Object.entries(files)) {
      const absPath = path.join(root, relativePath);
      mkdirSync(path.dirname(absPath), {recursive: true});
      writeFileSync(absPath, contents, 'utf8');
    }
    sandboxGit(root, ['add', '-A']);
    sandboxGit(root, ['commit', '-q', '-m', message]);

    return sandboxGit(root, ['rev-parse', 'HEAD']);
  };

  // Initial baseline commit.
  const initialSha = commit('initial commit', {'README.md': '# repo\n'});

  return {
    cleanup: () => {
      rmSync(root, {force: true, recursive: true});
    },
    commit,
    initialSha,
    root,
  };
};

const captureStdio = (): {
  errors: string[];
  outputs: string[];
  restore: () => void;
} => {
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

const classify = (sandbox: Sandbox): CommitClassification => {
  let out = '';
  const stdoutSpy = vi
    .spyOn(process.stdout, 'write')
    .mockImplementation((chunk: unknown) => {
      out += typeof chunk === 'string' ? chunk : String(chunk);

      return true;
    });
  const exit = run(['--since', sandbox.initialSha, '--json'], {
    cwd: sandbox.root,
  });
  stdoutSpy.mockRestore();
  expect(exit).toBe(0);

  return JSON.parse(out.trim()) as CommitClassification;
};

const withConfig = (wikiClassify: unknown): string =>
  `${JSON.stringify({gaia: {wikiClassify}, name: 'sandbox'}, null, 2)}\n`;

const commitManyTo = (
  sandbox: Sandbox,
  count: number,
  subject: string,
  file: string
): void => {
  for (let index = 0; index < count; index += 1) {
    sandbox.commit(`${subject} ${index}`, {[file]: `body ${index}\n`});
  }
};

describe('wiki commit-classify', () => {
  let sandbox: Sandbox;
  let stdio: ReturnType<typeof captureStdio>;

  beforeEach(() => {
    stdio = captureStdio();
    sandbox = setupSandbox();
  });

  afterEach(() => {
    stdio.restore();
    sandbox.cleanup();
    vi.restoreAllMocks();
  });

  test('chore(deps): bumps without architecture body → SKIP', () => {
    sandbox.commit('chore(deps): bump foo from 1.0.0 to 1.0.1', {
      'package.json': '{"version": "1.0.1"}\n',
    });

    const json = classify(sandbox);
    expect(json.commits).toHaveLength(1);
    expect(json.commits[0]?.suggestion).toBe('SKIP');
    expect(json.commits[0]?.suggestion_reason).toContain('chore(deps)');
  });

  test('chore(deps): with BREAKING CHANGE body → WORTHY', () => {
    sandbox.commit(
      'chore(deps): swap axios for ofetch\n\nBREAKING CHANGE: server-side fetch surface changed',
      {'package.json': '{"version": "2.0.0"}\n'}
    );

    const json = classify(sandbox);
    expect(json.commits[0]?.suggestion).toBe('WORTHY');
  });

  test('feat: touching app/** non-test → WORTHY', () => {
    sandbox.commit('feat: add new module', {
      'app/foo.ts': 'export const x = 1;\n',
    });

    const json = classify(sandbox);
    expect(json.commits[0]?.suggestion).toBe('WORTHY');
    expect(json.commits[0]?.suggestion_reason).toContain('source-bearing');
  });

  test('feat: only inventory paths without decision keywords → SKIP', () => {
    sandbox.commit('feat: add Button variant', {
      'app/components/Button/index.tsx': 'export const Button = () => null;\n',
    });

    const json = classify(sandbox);
    expect(json.commits[0]?.suggestion).toBe('SKIP');
    expect(json.commits[0]?.suggestion_reason).toContain('inventory');
  });

  test('test: prefix → SKIP', () => {
    sandbox.commit('test: add coverage', {'app/foo.test.ts': 'test ...\n'});

    const json = classify(sandbox);
    expect(json.commits[0]?.suggestion).toBe('SKIP');
  });

  test('docs(decision): → WORTHY', () => {
    sandbox.commit('docs(decision): adopt zod', {
      'docs/decisions/zod.md': '# zod\n',
    });

    const json = classify(sandbox);
    expect(json.commits[0]?.suggestion).toBe('WORTHY');
    expect(json.commits[0]?.suggestion_reason).toContain('ADR');
  });

  test('Merge pull request → SKIP', () => {
    sandbox.commit('Merge pull request #42 from feature/foo', {
      'README.md': '# repo updated\n',
    });

    const json = classify(sandbox);
    expect(json.commits[0]?.suggestion).toBe('SKIP');
  });

  test('chore(release): → SKIP', () => {
    sandbox.commit('chore(release): 1.0.0', {'CHANGELOG.md': '# 1.0.0\n'});

    const json = classify(sandbox);
    expect(json.commits[0]?.suggestion).toBe('SKIP');
  });

  test('touching app/middleware → WORTHY (flows-relevant)', () => {
    sandbox.commit('feat: middleware tweak', {
      'app/middleware/foo.ts': 'export const foo = () => null;\n',
    });

    const json = classify(sandbox);
    expect(json.commits[0]?.suggestion).toBe('WORTHY');
    expect(json.commits[0]?.suggestion_reason).toContain('flows');
  });

  test('touching wiki/concepts/ → WORTHY', () => {
    sandbox.commit('chore: rewrite concept', {
      'wiki/concepts/Foo.md': '# Foo\n',
    });

    const json = classify(sandbox);
    expect(json.commits[0]?.suggestion).toBe('WORTHY');
    expect(json.commits[0]?.suggestion_reason).toContain('wiki-heavy');
  });

  // This repo writes scoped subjects (`fix(hooks):`) essentially exclusively.
  // A rule table that only matches the unscoped form is unreachable in
  // practice: every commit falls through to the fail-open default and the
  // first-pass filter stops filtering. Parity is the property that catches it.
  describe('scoped subjects reach the same decision as unscoped', () => {
    const parityCases = [
      {path: 'app/foo.ts', type: 'feat'},
      {path: 'app/foo.ts', type: 'fix'},
      {path: 'app/foo.ts', type: 'refactor'},
      {path: 'app/foo.ts', type: 'debt'},
      {path: 'app/foo.ts', type: 'style'},
      {path: 'app/foo.test.ts', type: 'test'},
      {path: 'docs/guide.md', type: 'docs'},
      {path: 'tooling/thing.cfg', type: 'chore'},
    ];

    test.each(parityCases)(
      '$type: and $type(scope): agree',
      ({path: filePath, type}) => {
        sandbox.commit(`${type}: unscoped subject`, {[filePath]: 'unscoped\n'});
        sandbox.commit(`${type}(scope): scoped subject`, {
          [filePath]: 'scoped\n',
        });

        const {commits} = classify(sandbox);
        expect(commits).toHaveLength(2);
        expect(commits[1]?.suggestion).toBe(commits[0]?.suggestion);
        expect(commits[1]?.suggestion_reason).toBe(
          commits[0]?.suggestion_reason
        );
      }
    );
  });

  test('feat(scope)!: → WORTHY (breaking)', () => {
    sandbox.commit('feat(api)!: drop the legacy endpoint', {
      'app/api.ts': 'export const api = null;\n',
    });

    const json = classify(sandbox);
    expect(json.commits[0]?.suggestion).toBe('WORTHY');
    expect(json.commits[0]?.suggestion_reason).toContain('breaking');
  });

  // Once every rule matches breaking-agnostically, the `!` no longer breaks a
  // prefix match by accident, so a breaking subject on a SKIP-rule type would
  // be silently skipped unless rule 2 claims it first.
  test.each([
    'chore(cli)!: drop the legacy flag',
    'refactor(components)!: rename the exported prop',
    'fix(hooks)!: change the return shape',
  ])('%s → WORTHY (breaking beats every SKIP rule)', (subject) => {
    sandbox.commit(subject, {'app/components/Thing/index.tsx': 'export {};\n'});

    const json = classify(sandbox);
    expect(json.commits[0]?.suggestion).toBe('WORTHY');
    expect(json.commits[0]?.suggestion_reason).toContain('breaking');
  });

  // Rule 1 is deliberately "SKIP regardless", ahead of the breaking signal:
  // both its categories are mechanical, so a `!` on them is either
  // meaningless (formatting cannot break a contract) or still just plumbing.
  test.each(['style!: reformat everything', 'chore(release)!: 2.0.0'])(
    '%s → SKIP (rule 1 outranks the breaking marker)',
    (subject) => {
      sandbox.commit(subject, {'app/foo.ts': 'export const x = 1;\n'});

      const json = classify(sandbox);
      expect(json.commits[0]?.suggestion).toBe('SKIP');
    }
  );

  test.each(['docs(decision): adopt zod', 'docs(decisions): adopt zod'])(
    '%s → WORTHY (ADR signal outside a wiki-heavy path)',
    (subject) => {
      // Deliberately outside wiki/{decisions,concepts,...}, so rule 3 cannot
      // rescue it and the ADR rule is the only thing standing between this
      // commit and rule 8's `docs: prose-only` SKIP.
      sandbox.commit(subject, {'.claude/rules/zod.md': '# zod\n'});

      const json = classify(sandbox);
      expect(json.commits[0]?.suggestion).toBe('WORTHY');
      expect(json.commits[0]?.suggestion_reason).toContain('ADR');
    }
  );

  test('scoped chore(deps): still beats the generic chore rule', () => {
    sandbox.commit('chore(deps): bump foo from 1.0.0 to 1.0.1', {
      'package.json': '{"version": "1.0.1"}\n',
    });

    const json = classify(sandbox);
    expect(json.commits[0]?.suggestion).toBe('SKIP');
    expect(json.commits[0]?.suggestion_reason).toContain('chore(deps)');
  });

  test('debt: touching app/** non-test → WORTHY', () => {
    sandbox.commit('debt(cli): remove the dead telemetry write', {
      'app/foo.ts': 'export const x = 1;\n',
    });

    const json = classify(sandbox);
    expect(json.commits[0]?.suggestion).toBe('WORTHY');
    expect(json.commits[0]?.suggestion_reason).toContain('source-bearing');
  });

  test('debt: tests-only → SKIP', () => {
    sandbox.commit('debt(shell-lint): drop the redundant case', {
      'app/foo.test.ts': 'test ...\n',
    });

    const json = classify(sandbox);
    expect(json.commits[0]?.suggestion).toBe('SKIP');
    expect(json.commits[0]?.suggestion_reason).toContain('tests-only');
  });

  test('ci: without an architecture body → SKIP', () => {
    sandbox.commit('ci(release): add the distribution gate', {
      '.github/workflows/release.yml': 'on: push\n',
    });

    const json = classify(sandbox);
    expect(json.commits[0]?.suggestion).toBe('SKIP');
    expect(json.commits[0]?.suggestion_reason).toContain('ci');
  });

  test('ci: with an architecture body → WORTHY', () => {
    sandbox.commit(
      'ci(gaia): run the bats gate under bash 5\n\nRecords the decision to pin the CI shell.',
      {'.github/workflows/tests.yml': 'on: push\n'}
    );

    const json = classify(sandbox);
    expect(json.commits[0]?.suggestion).toBe('WORTHY');
  });

  test('build: without an architecture body → SKIP', () => {
    sandbox.commit('build(cli): rebundle the gaia binary', {
      'dist/gaia': 'binary\n',
    });

    const json = classify(sandbox);
    expect(json.commits[0]?.suggestion).toBe('SKIP');
    expect(json.commits[0]?.suggestion_reason).toContain('build');
  });

  test('a non-conforming subject still defers to human review', () => {
    sandbox.commit('Harden the Code Audit Team merge gate (#793)', {
      'app/gate.ts': 'export const gate = null;\n',
    });

    const json = classify(sandbox);
    expect(json.commits[0]?.suggestion).toBe('WORTHY');
    expect(json.commits[0]?.suggestion_reason).toContain('no matching prefix');
  });

  test('exits 1 when --since missing', () => {
    const exit = run(['--json'], {cwd: sandbox.root});
    expect(exit).toBe(1);
    expect(stdio.errors.join('')).toContain('--since');
  });

  test('returns empty list when no commits exist after the baseline', () => {
    const json = classify(sandbox);
    expect(json.commits).toEqual([]);
  });

  test('without --json, prints a tabular summary', () => {
    sandbox.commit('feat: real feature', {'app/foo.ts': 'x\n'});
    const exit = run(['--since', sandbox.initialSha], {cwd: sandbox.root});
    expect(exit).toBe(0);
    expect(stdio.outputs.join('')).toContain('Classified');
    expect(stdio.outputs.join('')).toContain('WORTHY');
  });

  // Every declared type must reach a DISCRIMINATING rule. A type in steady
  // use with no rule written for it (`debt` was exactly this) is invisible:
  // it lands on a fail-open default, gets promoted to WORTHY, and nothing
  // reports the gap.
  //
  // Asserted via `health.deferred` rather than by substring-matching a reason
  // string, so rewording a reason cannot silently disarm the guard. The
  // fixture sits under a source-bearing path on purpose: with a neutral path
  // the five path-discriminated types pass by landing on rule 7's deferred
  // tail, which is the very outcome this is supposed to reject.
  describe('declared commit-type vocabulary', () => {
    test.each([...COMMIT_TYPES])(
      '%s: reaches a discriminating rule',
      (type) => {
        sandbox.commit(`${type}(scope): a subject`, {
          'app/thing.ts': `export const x = '${type}';\n`,
        });

        const {health} = classify(sandbox);
        expect(health.evaluated).toBe(1);
        expect(health.deferred).toBe(0);
      }
    );

    test('an undeclared type still falls open to rule 9', () => {
      sandbox.commit('spike(scope): try a thing', {
        'app/thing.ts': 'export const x = 1;\n',
      });

      const {commits, health} = classify(sandbox);
      expect(commits[0]?.suggestion).toBe('WORTHY');
      expect(commits[0]?.suggestion_reason).toContain('no matching prefix');
      expect(health.deferred).toBe(1);
    });
  });

  // Rules 6/7 used to hardcode `app/**`. A repo whose source lives elsewhere
  // matched none of the three discriminating branches, so every source commit
  // fell to rule 7's tail with a plausible-looking reason.
  describe('configurable path vocabulary', () => {
    test('a configured source path is recognized outside app/**', () => {
      sandbox.commit('chore: configure', {
        'package.json': withConfig({sourcePaths: ['cli/src/']}),
      });
      sandbox.commit('fix(cli): repair the parser', {
        'cli/src/parse.ts': 'export const x = 1;\n',
      });

      const {commits} = classify(sandbox);
      expect(commits[1]?.suggestion).toBe('WORTHY');
      expect(commits[1]?.suggestion_reason).toContain('source-bearing');
    });

    test('a configured test path counts as tests-only', () => {
      sandbox.commit('chore: configure', {
        'package.json': withConfig({testPaths: ['suite/']}),
      });
      sandbox.commit('fix(hooks): tighten the guard case', {
        'suite/guard.bats': '@test "guard" { true; }\n',
      });

      const {commits} = classify(sandbox);
      expect(commits[1]?.suggestion).toBe('SKIP');
      expect(commits[1]?.suggestion_reason).toContain('tests-only');
    });

    test('a configured inventory path skips without decision keywords', () => {
      sandbox.commit('chore: configure', {
        'package.json': withConfig({inventoryPaths: ['lib/widgets/']}),
      });
      sandbox.commit('feat(widgets): add a variant', {
        'lib/widgets/Thing.ts': 'export const Thing = null;\n',
      });

      const {commits} = classify(sandbox);
      expect(commits[1]?.suggestion).toBe('SKIP');
      expect(commits[1]?.suggestion_reason).toContain('inventory');
    });

    // An empty `sourcePaths` matches no file at all, so every source commit
    // would land on rule 7's fail-open tail: the exact inertness this module
    // exists to prevent, reachable through the config surface and invisible
    // below the health signal's minimum sample. It must be rejected loudly
    // rather than accepted as "match nothing".
    test('an empty sourcePaths is rejected, not honored as match-nothing', () => {
      sandbox.commit('chore: configure', {
        'package.json': withConfig({sourcePaths: []}),
      });
      sandbox.commit('fix(cli): repair the parser', {
        'app/foo.ts': 'export const x = 1;\n',
      });

      const {commits, health} = classify(sandbox);
      expect(commits[1]?.suggestion_reason).toContain('source-bearing');
      expect(health.deferred).toBe(0);
      expect(stdio.errors.join('')).toContain('malformed gaia.wikiClassify');
    });

    // The other two lists have legitimate empty forms: `testPaths: []` is the
    // shipped default, and `inventoryPaths: []` turns the inventory skip off.
    test('an empty inventoryPaths is honored, disabling the inventory skip', () => {
      sandbox.commit('chore: configure', {
        'package.json': withConfig({inventoryPaths: []}),
      });
      sandbox.commit('feat: add Button variant', {
        'app/components/Button/index.tsx': 'export const Button = null;\n',
      });

      const {commits} = classify(sandbox);
      expect(commits[1]?.suggestion_reason).toContain('source-bearing');
      expect(stdio.errors.join('')).toBe('');
    });

    // Adopters get today's behavior with no config, and a malformed config
    // must degrade to it rather than fail a sync: this is a cheap pre-filter
    // ahead of an expensive read, not a correctness gate.
    test.each([
      ['absent gaia key', '{"name": "sandbox"}\n'],
      ['malformed JSON', '{not json\n'],
      ['wrong value type', '{"gaia": {"wikiClassify": {"sourcePaths": 7}}}\n'],
    ])('%s falls back to the app/** defaults', (_label, contents) => {
      sandbox.commit('chore: configure', {'package.json': contents});
      sandbox.commit('feat: add a module', {
        'app/foo.ts': 'export const x = 1;\n',
      });

      const {commits} = classify(sandbox);
      expect(commits[1]?.suggestion).toBe('WORTHY');
      expect(commits[1]?.suggestion_reason).toContain('source-bearing');
    });
  });

  // The health signal, not any individual commit, is what reports that the
  // rule table has gone inert. Both fail-open defaults count: rule 9, and
  // rule 7's tail, which emits a specific-sounding reason and would otherwise
  // hide a path vocabulary that matches nothing.
  describe('health signal', () => {
    test('counts rule-9 fallthrough as deferred, without calling it inert', () => {
      commitManyTo(
        sandbox,
        4,
        'Not a conventional subject',
        'tooling/thing.cfg'
      );

      const {health} = classify(sandbox);
      expect(health.evaluated).toBe(4);
      expect(health.deferred).toBe(4);
      expect(health.deferral_rate).toBe(1);
      // Below HEALTH_MIN_SAMPLE, so a bad rate alone never fires.
      expect(health.inert).toBe(false);
    });

    test("counts rule 7's tail as deferred despite its specific reason", () => {
      commitManyTo(
        sandbox,
        4,
        'fix(cli): repair the thing',
        'tooling/thing.cfg'
      );

      const {commits, health} = classify(sandbox);
      expect(commits[0]?.suggestion_reason).toContain('defer to human review');
      expect(health.deferred).toBe(4);
    });

    test('a discriminating rule is not deferral', () => {
      commitManyTo(sandbox, 4, 'docs: prose', 'notes/thing.md');

      const {health} = classify(sandbox);
      expect(health.deferred).toBe(0);
      expect(health.deferral_rate).toBe(0);
    });

    test('a large sample over the threshold reports inert and warns', () => {
      commitManyTo(
        sandbox,
        25,
        'Not a conventional subject',
        'tooling/thing.cfg'
      );

      const {health} = classify(sandbox);
      expect(health.evaluated).toBe(25);
      expect(health.inert).toBe(true);
      expect(stdio.errors.join('')).toContain('fail-open default');
    });

    test('a large healthy sample reports neither inert nor a warning', () => {
      commitManyTo(sandbox, 25, 'docs: prose', 'notes/thing.md');

      const {health} = classify(sandbox);
      expect(health.evaluated).toBe(25);
      expect(health.inert).toBe(false);
      expect(stdio.errors.join('')).toBe('');
    });

    // WORTHY rate is reported alongside deferral so configuring the path
    // vocabulary cannot quietly turn "I could not tell" into "definitely
    // read this" while the deep-read cost stays exactly the same.
    test('worthy_rate stays visible when deferral is zero', () => {
      commitManyTo(sandbox, 4, 'feat: add a module', 'app/foo.ts');

      const {health} = classify(sandbox);
      expect(health.deferred).toBe(0);
      expect(health.worthy_rate).toBe(1);
    });

    // The threshold is calibrated against both observed inert cases, not
    // picked round. The path-vocabulary failure sat at 55% deferral, so a
    // threshold above that would have missed the case #945 describes while
    // still catching the 68% type-vocabulary one.
    test('a ~50% deferral rate fires, the rate the path failure produced', () => {
      commitManyTo(
        sandbox,
        11,
        'fix(cli): repair the thing',
        'tooling/thing.cfg'
      );
      commitManyTo(sandbox, 11, 'docs: prose', 'notes/thing.md');

      const {health} = classify(sandbox);
      expect(health.evaluated).toBe(22);
      expect(health.deferred).toBe(11);
      expect(health.inert).toBe(true);
    });

    test('an empty range reports zeroed rates rather than NaN', () => {
      const {health} = classify(sandbox);
      expect(health.evaluated).toBe(0);
      expect(health.deferral_rate).toBe(0);
      expect(health.worthy_rate).toBe(0);
      expect(health.inert).toBe(false);
    });
  });

  // Without a propagated failure, git breaking is indistinguishable from the
  // genuinely empty range the test directly above covers: both answer "there
  // is nothing to review" with exit 0, so anything downstream of
  // `/gaia-wiki sync` that trusts a zero count reads a transient git failure
  // as a clean, up-to-date wiki.
  test('a failing git log reports git_failed, not an empty range', () => {
    // Well-formed but absent from the sandbox, so `git log <sha>..HEAD` exits
    // non-zero rather than resolving. Nothing validates `--since` ahead of the
    // call, which is what lets a bad revision reach `commitDetails` at all.
    const absentSha = 'deadbeef'.repeat(5);

    const exit = run(['--since', absentSha, '--json'], {cwd: sandbox.root});

    expect(exit).toBe(EXIT_CODES.UNKNOWN_SUBCOMMAND);

    const payload = JSON.parse(stdio.errors.join('').trim()) as {
      code: string;
      subcommand: string;
    };
    expect(payload.code).toBe('git_failed');
    expect(payload.subcommand).toBe('wiki commit-classify');
    // No classification on stdout: a zeroed payload here is the wrong answer
    // this test exists to keep out.
    expect(stdio.outputs.join('')).toBe('');
  });
});

/**
 * Every auto-maintenance child process git's own trace recorded.
 *
 * `GIT_TRACE2_EVENT` writes a `child_start` event, carrying the child's argv,
 * into the trace of the process that spawned it, so a run detached with
 * `--detach` is still visible without waiting on it or racing its exit. An
 * absent file means git spawned nothing and so wrote nothing.
 *
 * Both spellings count. Modern git spawns `git maintenance run --auto`; git
 * predating that task set spawns `git gc --auto`, which the config list above
 * names as a version it suppresses, so a filter matching only the first would
 * assert nothing on exactly the git the second entry exists for.
 */
const autoMaintenanceSpawns = (tracePath: string): string[] =>
  (existsSync(tracePath) ? readFileSync(tracePath, 'utf8') : '')
    .split('\n')
    .filter(
      (line) =>
        line.includes('"child_start"') &&
        (line.includes('"maintenance"') || line.includes('"gc"'))
    );

/**
 * The fixture's own hermeticity. Every scenario above takes it on faith that
 * the repository it commits into is the one `setupSandbox` created; nothing
 * asserted it, and a bare `execFileSync('git', ...)` hands that assumption to
 * whatever `GIT_DIR` the ambient environment happens to be carrying.
 */
describe('commit-classify sandbox fixture', () => {
  test('commits into its own repository under an ambient GIT_DIR', () => {
    const decoy = mkdtempSync(path.join(tmpdir(), 'gaia-wiki-classify-decoy-'));
    initSandboxRepo(decoy);
    execGaiaGit(
      ['commit', '-q', '--allow-empty', '-m', 'decoy baseline'],
      decoy
    );
    const decoyHeadBefore = execGaiaGit(['rev-parse', 'HEAD'], decoy);
    vi.stubEnv('GIT_DIR', path.join(decoy, '.git'));

    let sandbox: Sandbox | undefined;

    try {
      sandbox = setupSandbox();
      const sha = sandbox.commit('docs: prose 0', {'notes/thing.md': 'body\n'});

      expect(execGaiaGit(['rev-parse', 'HEAD'], sandbox.root)).toBe(sha);
      expect(execGaiaGit(['rev-parse', 'HEAD'], decoy)).toBe(decoyHeadBefore);
    } finally {
      vi.unstubAllEnvs();
      sandbox?.cleanup();
      rmSync(decoy, {force: true, recursive: true});
    }
  });

  // A bare "no maintenance was spawned" assertion passes just as well when the
  // trace recorded nothing at all, which is how a guard against a background
  // process goes vacuous without anyone noticing. The control repository, which
  // sets everything the sandbox sets except the two suppression gates, proves in
  // the same run that git still spawns maintenance on commit and that the trace
  // captures it.
  test('the sandbox config suppresses maintenance a bare repo spawns', () => {
    const traceRoot = mkdtempSync(
      path.join(tmpdir(), 'gaia-wiki-classify-trace-')
    );
    const controlRoot = mkdtempSync(
      path.join(tmpdir(), 'gaia-wiki-classify-control-')
    );
    let sandbox: Sandbox | undefined;

    try {
      // Everything the sandbox sets except the gates, which are then written
      // back at git's own defaults so the control's ungated state is its own
      // rather than inherited from the machine's global config. `gc.autoDetach`
      // is not a gate and so stays, which keeps the control's own maintenance
      // run a foreground child; without it this test would leak the very
      // orphaned background process it exists to keep out of the suite.
      initSandboxRepo(controlRoot, MAINTENANCE_GATES);

      for (const [key, value] of MAINTENANCE_GATE_DEFAULTS) {
        sandboxGit(controlRoot, ['config', key, value]);
      }

      const controlTrace = path.join(traceRoot, 'control.json');
      vi.stubEnv('GIT_TRACE2_EVENT', controlTrace);
      execGaiaGit(
        ['commit', '-q', '--allow-empty', '-m', 'control baseline'],
        controlRoot
      );

      const controlSpawns = autoMaintenanceSpawns(controlTrace);
      expect(controlSpawns.length).toBeGreaterThan(0);
      // The control's own run must stay in the foreground, or the `finally`
      // below deletes `controlRoot` out from under a live background git. A
      // count alone cannot see that: the parent records the child either way,
      // so this test would pass green while leaking the orphan the whole
      // fixture exists to prevent. Asserted as an absence to stay portable,
      // git predating the task set spawns `git gc --auto`, which carries no
      // detach flag at all and passes, while modern git catches a
      // `maintenance.autoDetach` that a later edit dropped as redundant.
      expect(controlSpawns.some((line) => line.includes('"--detach"'))).toBe(
        false
      );

      const sandboxTrace = path.join(traceRoot, 'sandbox.json');
      vi.stubEnv('GIT_TRACE2_EVENT', sandboxTrace);
      sandbox = setupSandbox();
      commitManyTo(sandbox, 4, 'docs: prose', 'notes/thing.md');

      expect(autoMaintenanceSpawns(sandboxTrace)).toEqual([]);
    } finally {
      vi.unstubAllEnvs();
      sandbox?.cleanup();
      rmSync(controlRoot, {force: true, recursive: true});
      rmSync(traceRoot, {force: true, recursive: true});
    }
  });
});
