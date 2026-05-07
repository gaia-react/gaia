/**
 * Dispatch-time coaching injection.
 *
 * `maybeInjectCoaching` reads `profile.md`'s `## Active adaptations`
 * section, filters by relevance to the dispatch context, and returns
 * the coaching block text to prepend to the agent's system prompt.
 *
 * Returns "" when:
 *   - mentorship is disabled (config short-circuit)
 *   - profile.md is absent
 *   - profile.md has no active adaptations
 *   - no active adaptation is relevant to the dispatch context
 *
 * In the empty-string case, callers' prepend logic noops, so the resulting
 * system prompt is byte-identical to the non-mentorship path.
 *
 * When an adaptation matches, the cache file
 * `.gaia/cache/coaching-active.txt` is written with content `1` so the
 * statusline 🧭 segment lights up. Cleared by `wiki-session-start.sh` at
 * session boundary.
 *
 * v1.0.0 ships wired-but-inert: pattern detection below threshold for
 * every area at install time → profile.md has no active adaptations →
 * this function returns "" by design.
 */
import {existsSync, mkdirSync, writeFileSync} from 'node:fs';
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import {isMentorshipEnabled} from '../mentorship/config.js';
import {ADAPTATION_TEXT} from '../profile/adaptation-map.js';
import {AgentTypeSchema} from '../schemas/envelope.js';
import type {AgentType} from '../schemas/envelope.js';
import {structuredError} from '../stderr.js';
import {resolveStorageRoots} from '../storage/index.js';
import type {StorageRoots} from '../storage/index.js';
import {readActiveAdaptations} from './profile-reader.js';
import type {ActiveAdaptation} from './profile-reader.js';

export type InjectionContext = {
  agentType: AgentType;
  /** dispatch artifact's required_skills, or SPEC's UAT-cluster area_tags */
  areaTags?: string[];
  specId?: string;
};

type InjectionDeps = {
  /**
   * Override for tests so we don't write to a real `.gaia/cache/`.
   * In production callers always omit this; the helper resolves the
   * cache path from the repo root inferred via `git rev-parse`.
   */
  cachePath?: string;
  roots?: StorageRoots;
};

const COACHING_HEADER = '## Profile-driven coaching';

const filterRelevant = (
  adaptations: readonly ActiveAdaptation[],
  ctx: InjectionContext
): ActiveAdaptation | undefined => {
  if (ctx.areaTags !== undefined && ctx.areaTags.length > 0) {
    const requested = new Set(ctx.areaTags);

    return adaptations.find((adaptation) => requested.has(adaptation.area_tag));
  }

  // Fallback: with no area tags supplied, pick the first adaptation.
  // Per the brief: "Some adaptations are agent-type-scoped not area-scoped."
  // v1.0.0 ships only area-scoped adaptations, so the fallback is the
  // simplest safe behavior — return the first available adaptation so
  // the caller still sees coaching when it asked without scoping.
  // Future agent-type-scoped adaptations would refine this branch.
  return adaptations[0];
};

const renderCoachingBlock = (adaptation: ActiveAdaptation): string => {
  const template = ADAPTATION_TEXT[adaptation.adaptation_id];
  const body = template.replaceAll('{{area}}', adaptation.area_tag);

  return `${COACHING_HEADER}\n\n${body}\n`;
};

const resolveCachePath = (deps: InjectionDeps): string => {
  if (deps.cachePath !== undefined) return deps.cachePath;
  // The cache lives in-project at `<repoRoot>/.gaia/cache/coaching-active.txt`.
  // `roots.projectIdPath` is `<repoRoot>/.gaia/local/.project-id`, so the
  // repo root is two parent directories up from there.
  const roots = deps.roots ?? resolveStorageRoots();
  const repoRoot = path.dirname(
    path.dirname(path.dirname(roots.projectIdPath))
  );

  return path.join(repoRoot, '.gaia', 'cache', 'coaching-active.txt');
};

/**
 * Mark the current session as coaching-active. Idempotent — overwriting
 * with the same `1` byte is the intended steady state when injection
 * fires on every dispatch in a session.
 */
const markCoachingActive = (cachePath: string): void => {
  const parent = path.dirname(cachePath);

  if (!existsSync(parent)) {
    mkdirSync(parent, {mode: 0o755, recursive: true});
  }
  writeFileSync(cachePath, '1', {mode: 0o644});
};

/**
 * Returns the coaching block text to inject, or "" when no relevant
 * adaptation is active. Side-effect on non-empty: writes
 * `.gaia/cache/coaching-active.txt` so the statusline 🧭 lights up.
 */
export const maybeInjectCoaching = async (
  ctx: InjectionContext,
  deps: InjectionDeps = {}
): Promise<string> => {
  const roots = deps.roots ?? resolveStorageRoots();

  if (!isMentorshipEnabled(roots)) return '';

  const adaptations = readActiveAdaptations(roots.profilePath);

  if (adaptations.length === 0) return '';

  const relevant = filterRelevant(adaptations, ctx);

  if (relevant === undefined) return '';

  const block = renderCoachingBlock(relevant);
  const cachePath = resolveCachePath({...deps, roots});
  markCoachingActive(cachePath);

  return block;
};

type ParsedFlags = {
  agentType?: string;
  areaTags?: string;
  specId?: string;
};

const parseFlags = (argv: readonly string[]): ParsedFlags => {
  const flags: ParsedFlags = {};
  let index = 0;

  while (index < argv.length) {
    const token = argv[index] as string | undefined;
    const value = argv[index + 1] as string | undefined;

    if (token === '--agent-type') {
      flags.agentType = value;
      index += 2;
    } else if (token === '--area-tags') {
      flags.areaTags = value;
      index += 2;
    } else if (token === '--spec-id') {
      flags.specId = value;
      index += 2;
    } else {
      index += 1;
    }
  }

  return flags;
};

const splitAreaTags = (raw: string | undefined): string[] | undefined => {
  if (raw === undefined || raw.length === 0) return undefined;

  return raw
    .split(',')
    .map((tag) => tag.trim())
    .filter(Boolean);
};

/**
 * `gaia _internal-fetch-coaching` subcommand handler.
 *
 * Thin CLI wrapper over `maybeInjectCoaching`. Prints the coaching block
 * (or an empty string) to stdout. Always exits 0 — bash callers capture
 * with `COACHING=$(.gaia/cli/gaia _internal-fetch-coaching ...)` and prepend
 * unconditionally; an empty result is the byte-identical no-op path.
 *
 * Argv shape:
 *   _internal-fetch-coaching --agent-type <type>
 *                            [--area-tags <comma-sep>]
 *                            [--spec-id <id>]
 *
 * `--agent-type` is required; missing/invalid values print "" and exit
 * non-zero so a caller misuse surfaces in stderr without breaking the
 * dispatch path.
 */
export const run = async (argv: readonly string[]): Promise<number> => {
  const flags = parseFlags(argv);
  const parsed = AgentTypeSchema.safeParse(flags.agentType);

  if (!parsed.success) {
    structuredError({
      code: 'arg_parse_error',
      issue: '--agent-type must be one of the AgentType enum values',
      received: flags.agentType ?? null,
    });

    return EXIT_CODES.PAYLOAD_VALIDATION_FAILED;
  }

  const text = await maybeInjectCoaching({
    agentType: parsed.data,
    areaTags: splitAreaTags(flags.areaTags),
    specId: flags.specId,
  });
  process.stdout.write(text);

  return EXIT_CODES.OK;
};
