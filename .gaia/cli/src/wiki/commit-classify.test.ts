import {afterEach, beforeEach, describe, expect, test, vi} from 'vitest';
/**
 * Tests for `gaia wiki commit-classify`.
 *
 * Strategy: build a sandbox repo, commit a deterministic series of changes,
 * then ask the handler to classify them since the initial baseline. We
 * snapshot the suggestion + reason for each commit and assert against it.
 */
import {execFileSync} from 'node:child_process';
import {mkdirSync, mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {COMMIT_TYPES} from '../util/conventional-commit.js';
import {run} from './commit-classify.js';
import type {CommitClassification} from './commit-classify.js';

type Sandbox = {
  cleanup: () => void;
  commit: (message: string, files: Record<string, string>) => string;
  initialSha: string;
  root: string;
};

const setupSandbox = (): Sandbox => {
  const root = mkdtempSync(path.join(tmpdir(), 'gaia-wiki-classify-'));
  execFileSync('git', ['init', '-q', '-b', 'main'], {cwd: root});
  execFileSync('git', ['config', 'user.email', 'test@example.com'], {
    cwd: root,
  });
  execFileSync('git', ['config', 'user.name', 'Test'], {cwd: root});
  execFileSync('git', ['config', 'commit.gpgsign', 'false'], {cwd: root});

  const commit = (message: string, files: Record<string, string>): string => {
    for (const [relativePath, contents] of Object.entries(files)) {
      const absPath = path.join(root, relativePath);
      mkdirSync(path.dirname(absPath), {recursive: true});
      writeFileSync(absPath, contents, 'utf8');
    }
    execFileSync('git', ['add', '-A'], {cwd: root});
    execFileSync('git', ['commit', '-q', '-m', message], {cwd: root});

    return execFileSync('git', ['rev-parse', 'HEAD'], {
      cwd: root,
      encoding: 'utf8',
    }).trim();
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
});
