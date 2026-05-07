/**
 * profile.md `## Active adaptations` section parser.
 *
 * Reads the file synchronously (small, infrequently-touched) and extracts
 * each active adaptation as `{ adaptation_id, area_tag }`. The format
 * written by `gaia telemetry compute-profile` is:
 *
 *     ## Active adaptations
 *
 *     - po_socratic_depth_increased — area: visual, strength: 0.62, samples: 33
 *     - engineer_commentary_verbosity_increased — area: react, strength: 0.55, samples: 18
 *
 *     ## Faded adaptations
 *
 * Parser strategy: locate the `## Active adaptations` heading, scan
 * bullet lines (`-`-prefixed) until the next `##` heading, and extract
 * the adaptation id (matched against the canonical map from
 * `profile/adaptation-map.ts`) plus its area tag.
 *
 * v1.0.0 ships wired-but-inert: real-usage data is below the 10-event
 * sample threshold, so `compute-profile` writes "(none)" under this
 * section and the parser returns an empty array. The byte-identical
 * no-op path holds.
 *
 * Out of scope: markdown AST parsing — the regex-based scan is enough
 * for the controlled output of `compute-profile`. If the format gets
 * richer post-launch, swap to remark-parse with no caller changes.
 */
import {existsSync, readFileSync} from 'node:fs';
import {ADAPTATION_TEXT} from '../profile/adaptation-map.js';
import type {AdaptationId} from '../profile/adaptation-map.js';

export type ActiveAdaptation = {
  adaptation_id: AdaptationId;
  area_tag: string;
};

const ACTIVE_HEADING_REGEX = /^##\s+Active adaptations\s*$/u;
const NEXT_HEADING_REGEX = /^##\s+/u;
// Bound the bullet body to a reasonable line length (compute-profile's
// per-bullet output is well under 200 chars; the cap keeps the regex
// linear-time and removes the sonarjs/slow-regex flag).
const BULLET_REGEX = /^-\s+([^\n]{1,500})$/u;
const AREA_TAG_REGEX = /\barea\s*[:=]\s*([\w-]+)/iu;

const KNOWN_ADAPTATION_IDS = Object.keys(ADAPTATION_TEXT) as AdaptationId[];

const isAdaptationId = (raw: string): raw is AdaptationId =>
  (KNOWN_ADAPTATION_IDS as readonly string[]).includes(raw);

const parseBulletLine = (raw: string): ActiveAdaptation | undefined => {
  const bulletMatch = BULLET_REGEX.exec(raw);

  if (bulletMatch === null) return undefined;
  // RegExpExecArray indexes 1..n (capture groups) are typed `string` under
  // TS's regexp typings (no `noUncheckedIndexedAccess` carve-out), so no
  // assertion is needed here — both BULLET_REGEX and AREA_TAG_REGEX
  // declare exactly one capture group that matches when the outer regex
  // does.
  const body = bulletMatch[1];
  // Adaptation id is the first whitespace-or-dash-delimited token that
  // matches a known adaptation id.
  const tokens = body.split(/[\s—-]+/u).filter(Boolean);
  const adaptationToken = tokens.find((token) => isAdaptationId(token));

  if (adaptationToken === undefined) return undefined;

  const areaMatch = AREA_TAG_REGEX.exec(body);

  if (areaMatch === null) return undefined;

  return {adaptation_id: adaptationToken, area_tag: areaMatch[1]};
};

/**
 * Parse the `## Active adaptations` section of `profile.md` content.
 *
 * Returns an empty array when the section is absent, the section body is
 * "(none)", or no bullet lines parse cleanly.
 */
export const parseActiveAdaptations = (
  profileContents: string
): ActiveAdaptation[] => {
  const lines = profileContents.split('\n');
  const startIndex = lines.findIndex((line) => ACTIVE_HEADING_REGEX.test(line));

  if (startIndex === -1) return [];

  const result: ActiveAdaptation[] = [];

  for (let index = startIndex + 1; index < lines.length; index += 1) {
    const line = lines[index] ?? '';

    if (NEXT_HEADING_REGEX.test(line)) break;

    const parsed = parseBulletLine(line);

    if (parsed !== undefined) {
      result.push(parsed);
    }
  }

  return result;
};

/**
 * Read `profile.md` from disk and parse its active-adaptations section.
 *
 * Returns an empty array when the file is absent (the v1.0.0 default
 * when mentorship has not yet caused `compute-profile` to write the
 * file). Synchronous IO — the file is small and the call sits on the
 * dispatch hot path; an extra event-loop hop is unnecessary.
 *
 * The read path is lock-free: the writer's atomic write-temp-and-rename
 * guarantees we either see the prior version in full or the new version
 * in full — never half-state.
 */
export const readActiveAdaptations = (
  profilePath: string
): ActiveAdaptation[] => {
  if (!existsSync(profilePath)) return [];
  const contents = readFileSync(profilePath, 'utf8');

  return parseActiveAdaptations(contents);
};
