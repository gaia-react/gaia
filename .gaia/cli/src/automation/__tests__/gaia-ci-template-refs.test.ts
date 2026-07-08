import {describe, expect, test} from 'vitest';
import {existsSync, readdirSync, readFileSync} from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import type {ToolId} from '../../schemas/automation-config.js';
import {workflowTemplatePath} from '../paths.js';
/**
 * Maintainer drift-guard for the outbound references in the four
 * `gaia-ci-*` workflow templates.
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
 *   1. the on-disk `gaia-ci-*` template set matches the contract keys, so a
 *      new template forces a contract entry;
 *   2. every declared reference still appears in its template, so a silent
 *      drop or divergence of the invocation fails here;
 *   3. every declared target still exists, the skill directory under
 *      `.claude/skills/`, and the CLI path against the live routers; and
 *   4. no template invokes a real skill it has not declared, so adding a
 *      `/<skill>` to an existing template forces a contract update rather
 *      than slipping through unguarded.
 *
 * Completeness has one accepted gap: an *undeclared CLI* invocation added to
 * an existing template is not auto-detected. Template prompt prose mixes
 * executed `gaia <cmd>` calls with step labels (`- name: Run gaia wiki
 * chain`), so extracting CLI invocations from the text yields false
 * positives; the CLI half stays contract-declared only. Skills carry no such
 * ambiguity, a `/<slug>` token preceded by whitespace or a backtick that
 * resolves to a real skill directory is unambiguously an invocation, so
 * check 4 covers them.
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

type TemplateContract = {
  readonly cli: readonly string[];
  readonly skills: readonly string[];
};

// The GAIA skills (`/<slug>`) and CLI leaf commands (`gaia <path>`) each
// `gaia-ci-*` template invokes. `pnpm-audit` and `stale-branches` are pure
// `gh`/shell and invoke neither; adding a GAIA invocation to either one must
// record it here, or test 2 does not cover it. Typing the map as
// `Record<ToolId, ...>` forces an entry when a new tool id is added.
const TEMPLATE_CONTRACT: Readonly<Record<ToolId, TemplateContract>> = {
  'pnpm-audit': {cli: [], skills: []},
  'stale-branches': {cli: [], skills: []},
  'update-deps': {cli: ['update-deps run'], skills: ['update-deps']},
  wiki: {cli: ['wiki sync land'], skills: ['gaia-wiki']},
};

const resolveRepoRoot = (): string => {
  // Walk up from this file's location to the repo root (contains .git).
  let dir = path.dirname(fileURLToPath(import.meta.url));

  for (let attempts = 0; attempts < 20; attempts += 1) {
    if (existsSync(path.join(dir, '.git'))) {
      return dir;
    }
    const parent = path.dirname(dir);

    if (parent === dir) break;
    dir = parent;
  }

  throw new Error('Could not find repo root (no .git directory found)');
};

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
// `wiki/sync.ts`.
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

  for (const match of templateText.matchAll(SKILL_REF_PATTERN)) {
    refs.add(match[1]);
  }

  return refs;
};

const repoRoot = resolveRepoRoot();
const templatesDir = path.dirname(workflowTemplatePath('wiki'));
const cliSrc = path.join(repoRoot, '.gaia', 'cli', 'src');
const ready = existsSync(templatesDir) && existsSync(cliSrc);

const discoverTemplateTools = (): string[] =>
  readdirSync(templatesDir)
    .map((name) => /^gaia-ci-(.+)\.yml\.tmpl$/u.exec(name)?.[1])
    .filter((tool): tool is string => tool !== undefined)
    .toSorted((a, b) => a.localeCompare(b));

// Contract entries whose declared invocation no longer appears in the
// template text (silent drop / divergence at the invocation level).
const collectMissingReferences = (): string[] => {
  const missing: string[] = [];

  for (const [tool, contract] of Object.entries(TEMPLATE_CONTRACT)) {
    const template = readFileSync(workflowTemplatePath(tool as ToolId), 'utf8');

    for (const slug of contract.skills) {
      if (!template.includes(`/${slug}`)) missing.push(`${tool}: /${slug}`);
    }

    for (const command of contract.cli) {
      if (!template.includes(`gaia ${command}`)) {
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
    const template = readFileSync(workflowTemplatePath(tool as ToolId), 'utf8');
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
    'the on-disk gaia-ci-* template set matches the contract keys',
    () => {
      expect(discoverTemplateTools()).toEqual(
        Object.keys(TEMPLATE_CONTRACT).toSorted((a, b) => a.localeCompare(b))
      );
    }
  );

  test.skipIf(!ready)(
    'every declared skill and CLI reference appears in its template',
    () => {
      expect(collectMissingReferences()).toEqual([]);
    }
  );

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
