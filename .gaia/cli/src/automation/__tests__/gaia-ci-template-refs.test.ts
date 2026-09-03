/**
 * Maintainer drift-guard for the outbound references in the rendered
 * `gaia-ci` workflow templates: the four per-tool ones and the scheduler
 * that calls them.
 *
 * These templates render into an adopter's `.github/workflows/`, but the
 * maintainer repo runs none of them, so, unlike `code-review-audit.yml`
 * (guarded byte-for-byte by `audit-template-dogfood.test.ts`) there is no
 * in-tree counterpart to diff against. The snapshot and YAML-shape suites
 * guard the render *source*; nothing guards the GAIA skills and CLI
 * subcommands the templates invoke by name in their prompt and run steps.
 * Rename the `/gaia-wiki` skill, or the `wiki sync land` CLI verb, and an
 * adopter's CI silently invokes a command that no longer exists.
 *
 * This guard pins an explicit contract, the skills and CLI leaf commands
 * each template is expected to invoke, and asserts four things:
 *   1. the on-disk `gaia-ci` template set matches the contract keys, so a
 *      new template forces a contract entry;
 *   2. every declared reference still appears in its template, so a silent
 *      drop or divergence of the invocation fails here;
 *   3. every declared target still exists, the skill directory under
 *      `.claude/skills/`, and the CLI path against the live routers; and
 *   4. no template invokes a real skill it has not declared, so adding a
 *      `/<skill>` to an existing template forces a contract update rather
 *      than slipping through unguarded.
 *
 * Completeness has one accepted gap, and it is **check 4's alone**: an
 * *undeclared CLI* invocation added to an existing template is not
 * auto-detected. Template prompt prose mixes executed `gaia <cmd>` calls with
 * step labels (`- name: Run gaia wiki chain`), so EXTRACTING CLI invocations
 * from the text yields false positives; check 4 therefore covers skills only,
 * and the CLI half of the contract stays declared by hand. Skills carry no
 * such ambiguity, a `/<slug>` token preceded by whitespace or a backtick that
 * resolves to a real skill directory is unambiguously an invocation.
 *
 * The gap does not reach check 2, and reading it as though it did is what left
 * `#1271` sitting as a fork. Check 2 VERIFIES a string the contract already
 * declares; it extracts nothing, so widening how it recognizes that string
 * cannot admit a step label, because a step label is not in the contract. That
 * is why its CLI half matches through the shared `matchesInvocation`
 * (`util/gaia-invocation-matcher.ts`) and its skill half, which does extract,
 * keeps the narrower `SKILL_REF_PATTERN` lookbehind.
 *
 * The complementary `command-reachability.test.ts` guards the inverse
 * direction (every CLI leaf command has some external invoker). It cannot
 * catch this drift: `wiki sync land` and `update-deps run` are invoked from
 * skills and wiki pages too, so a stale template reference keeps a live
 * invoker elsewhere and that guard stays green.
 *
 * Maintainer-only by construction: `.gaia/cli/src` is release-excluded, so
 * this test is absent on adopter clones. It also skips gracefully on any
 * checkout where the templates or routers are missing, mirroring the
 * sibling guards.
 */
import {describe, expect, test} from 'vitest';
import {existsSync, readdirSync, readFileSync} from 'node:fs';
import path from 'node:path';
import type {ToolId} from '../../schemas/automation-config.js';
import {matchesInvocation} from '../../util/gaia-invocation-matcher.js';
import {resolveRepoRootFromImportMeta} from '../../util/repo-root-fixture.js';
import {workflowSchedulerTemplatePath, workflowTemplatePath} from '../paths.js';

type TemplateContract = {
  readonly cli: readonly string[];
  readonly skills: readonly string[];
};

// A contract key is a tool id, or `scheduler` for the `gaia-ci.yml` template
// that calls the tool workflows.
type TemplateKey = 'scheduler' | ToolId;

// The GAIA skills (`/<slug>`) and CLI leaf commands (`gaia <path>`) each
// template invokes. `pnpm-audit` and `stale-branches` are pure `gh`/shell and
// invoke neither; adding a GAIA invocation to either one must record it here,
// or test 2 does not cover it. Typing the map as `Record<TemplateKey, ...>`
// forces an entry when a new tool id is added.
//
// The scheduler earns its entry the same way a tool does, and needs it more:
// its `cron-decide` call is the single gate in front of every tool, so a
// rename that left it stale would stop all scheduled maintenance at once
// rather than one tool's.
const TEMPLATE_CONTRACT: Readonly<Record<TemplateKey, TemplateContract>> = {
  'pnpm-audit': {cli: [], skills: []},
  scheduler: {cli: ['automation cron-decide'], skills: []},
  'stale-branches': {cli: [], skills: []},
  'update-deps': {cli: ['update-deps run'], skills: ['update-deps']},
  wiki: {cli: ['wiki sync land'], skills: ['gaia-wiki']},
};

const templatePathFor = (key: TemplateKey): string =>
  key === 'scheduler' ?
    workflowSchedulerTemplatePath()
  : workflowTemplatePath(key);

const escapeRegExp = (value: string): string =>
  value.replaceAll(/[.*+?^${}()|[\]\\]/g, String.raw`\$&`);

// A router recognizes a dispatch token when the token is a
// `SUBCOMMAND_HANDLERS` map key (`'token': runX`) or an inline
// `subcommand === 'token'` branch. Tested per line (not multiline) to keep
// each regex a single bounded-length attempt, matching the sibling guard.
const isDispatchToken = (routerSource: string, token: string): boolean => {
  const escaped = escapeRegExp(token);
  const mapKey = new RegExp(String.raw`^\s*'?${escaped}'?\s*:\s*run[A-Z]`, 'u');
  const inlineIf = new RegExp(String.raw`===\s*'${escaped}'`, 'u');

  return routerSource
    .split('\n')
    .some((line) => mapKey.test(line) || inlineIf.test(line));
};

const readFileOrEmpty = (filePath: string): string =>
  existsSync(filePath) ? readFileSync(filePath, 'utf8') : '';

// Concatenated top-level `.ts` sources of a CLI domain directory (its router
// plus handler files, tests excluded). Reading the whole directory, not just
// `index.ts`, keeps the resolver robust to a sub-dispatch handler being
// extracted to its own file: `wiki sync land`'s `=== 'land'` branch lives
// inline in `wiki/index.ts` today but resolves equally if `runSync` moves to
// a dedicated file.
const readDomainSources = (cliSrc: string, domain: string): string => {
  const dir = path.join(cliSrc, domain);

  if (!existsSync(dir)) return '';

  return readdirSync(dir)
    .filter((name) => name.endsWith('.ts') && !name.endsWith('.test.ts'))
    .map((name) => readFileOrEmpty(path.join(dir, name)))
    .join('\n');
};

// A CLI path `<domain> <verb> [<subverb>]` exists when the domain is a
// registered top-level handler key and every remaining token is a dispatch
// token somewhere in the domain's sources.
const cliCommandExists = (cliSrc: string, commandPath: string): boolean => {
  const [domain, ...rest] = commandPath.split(' ');

  if (domain === undefined) return false;

  const rootRouter = readFileOrEmpty(path.join(cliSrc, 'index.ts'));

  if (!isDispatchToken(rootRouter, domain)) return false;

  const domainSources = readDomainSources(cliSrc, domain);

  return rest.every((token) => isDispatchToken(domainSources, token));
};

const skillExists = (repoRoot: string, slug: string): boolean =>
  existsSync(path.join(repoRoot, '.claude', 'skills', slug, 'SKILL.md'));

// Skill-shaped tokens (`/<slug>`) in template text, restricted to a `/`
// preceded by whitespace or a backtick so path segments inside a literal
// like `.claude/rules/wiki-style.md` are never mistaken for an invocation.
const SKILL_REF_PATTERN = /(?<=[\s`])\/([a-z][a-z0-9-]*)/gu;

const extractSkillRefs = (templateText: string): Set<string> => {
  const refs = new Set<string>();

  for (const [, slug] of templateText.matchAll(SKILL_REF_PATTERN)) {
    if (slug !== undefined) refs.add(slug);
  }

  return refs;
};

const repoRoot = resolveRepoRootFromImportMeta(import.meta.url);
const templatesDir = path.dirname(workflowTemplatePath('wiki'));
const cliSrc = path.join(repoRoot, '.gaia', 'cli', 'src');
const ready = existsSync(templatesDir) && existsSync(cliSrc);

// `gaia-ci.yml.tmpl` has no tool segment and resolves to `scheduler`, so the
// one template that is not a tool still has to appear in the contract.
const discoverTemplateKeys = (): string[] =>
  readdirSync(templatesDir)
    .map((name) => /^gaia-ci(?:-(.+))?\.yml\.tmpl$/u.exec(name))
    .filter((match): match is RegExpExecArray => match !== null)
    .map((match) => match[1] ?? 'scheduler')
    .toSorted((a, b) => a.localeCompare(b));

// Contract entries whose declared invocation no longer appears in the
// template text (silent drop / divergence at the invocation level).
const collectMissingReferences = (): string[] => {
  const missing: string[] = [];

  for (const [tool, contract] of Object.entries(TEMPLATE_CONTRACT)) {
    const template = readFileSync(templatePathFor(tool as TemplateKey), 'utf8');

    for (const slug of contract.skills) {
      if (!template.includes(`/${slug}`)) missing.push(`${tool}: /${slug}`);
    }

    // `matchesInvocation`, not a bare `includes('gaia ' + command)`: the
    // substring test requires a space immediately after the binary name, so a
    // template invoking a declared command through a quoted, release-resolved
    // path (`"$LATEST_DIR/.gaia/cli/gaia" wiki sync land`) satisfies the
    // contract in fact and fails it in the check. That false red misdirects
    // rather than merely annoying: it reports a reference as dropped from a
    // template that still invokes it, and the natural repair is to edit
    // working code to appease the checker. `#1037` fixed the same assumption
    // in `command-reachability.test.ts`, and the invocation form that broke it
    // there is a frozen contract in this repository.
    for (const command of contract.cli) {
      if (!matchesInvocation(command, template)) {
        missing.push(`${tool}: gaia ${command}`);
      }
    }
  }

  return missing;
};

// Contract targets that no longer resolve: a skill directory that is gone,
// or a CLI path the routers no longer dispatch. This is the core drift #630
// tracks, a maintainer rename that leaves the adopter template stale.
const collectMissingTargets = (): string[] => {
  const missing: string[] = [];

  for (const contract of Object.values(TEMPLATE_CONTRACT)) {
    for (const slug of contract.skills) {
      if (!skillExists(repoRoot, slug)) missing.push(`skill: /${slug}`);
    }

    for (const command of contract.cli) {
      if (!cliCommandExists(cliSrc, command)) {
        missing.push(`cli: gaia ${command}`);
      }
    }
  }

  return missing;
};

// Real skills a template invokes without declaring them (check 4). Only
// tokens that resolve to an actual skill directory are flagged, so a stray
// `/word` in prose that is not a skill is ignored; this keeps the check free
// of the false positives that rule out CLI auto-extraction.
const collectUndeclaredSkillRefs = (): string[] => {
  const undeclared: string[] = [];

  for (const [tool, contract] of Object.entries(TEMPLATE_CONTRACT)) {
    const template = readFileSync(templatePathFor(tool as TemplateKey), 'utf8');
    const declared = new Set(contract.skills);

    for (const ref of extractSkillRefs(template)) {
      if (skillExists(repoRoot, ref) && !declared.has(ref)) {
        undeclared.push(`${tool}: /${ref}`);
      }
    }
  }

  return undeclared;
};

describe('gaia-ci-* template reference drift-guard', () => {
  test.skipIf(!ready)(
    'the on-disk gaia-ci template set matches the contract keys',
    () => {
      expect(discoverTemplateKeys()).toEqual(
        Object.keys(TEMPLATE_CONTRACT).toSorted((a, b) => a.localeCompare(b))
      );
    }
  );

  test.skipIf(!ready)(
    'every declared skill and CLI reference appears in its template',
    () => {
      // The CLI half of this check must be able to return false, else the
      // assertion below passes vacuously. `collectMissingReferences` reads
      // from disk with no injection point, so the control exercises its
      // matcher against a real template directly.
      const anyTemplate = readFileSync(templatePathFor('wiki'), 'utf8');

      expect(matchesInvocation('zzz fabricated-command', anyTemplate)).toBe(
        false
      );

      expect(collectMissingReferences()).toEqual([]);
    }
  );

  // No `skipIf`: the declared commands are a literal in this file and the
  // haystack is synthesized, so this needs no template on disk.
  test('every declared CLI command survives a quoted binary path', () => {
    // Scoped to what this file owns: that the commands THIS contract declares
    // are matchable in the quoted form, whatever shape a later entry takes.
    // The matcher's own quoted-vs-unquoted behavior is asserted generically in
    // `util/gaia-invocation-matcher.test.ts` and is not re-derived here; the
    // rationale for admitting the quote is argued above the CLI loop in
    // `collectMissingReferences`.
    const declared = Object.values(TEMPLATE_CONTRACT).flatMap(
      (contract) => contract.cli
    );

    expect(declared.length).toBeGreaterThan(0);

    for (const command of declared) {
      expect(
        matchesInvocation(
          command,
          `      - run: "$LATEST_DIR/.gaia/cli/gaia" ${command} --json`
        )
      ).toBe(true);
    }
  });

  test.skipIf(!ready)(
    'every declared skill directory and CLI command still exists',
    () => {
      // The resolvers must be able to return false, else the check above
      // passes vacuously.
      expect(skillExists(repoRoot, 'zzz-fabricated-skill')).toBe(false);
      expect(cliCommandExists(cliSrc, 'zzz fabricated-command')).toBe(false);

      expect(collectMissingTargets()).toEqual([]);
    }
  );

  test.skipIf(!ready)(
    'no template invokes a real skill it has not declared',
    () => {
      expect(collectUndeclaredSkillRefs()).toEqual([]);
    }
  );
});
