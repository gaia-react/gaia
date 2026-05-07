/* eslint-disable unicorn/prevent-abbreviations -- `mentorshipDir` mirrors the
   frozen `StorageRoots.mentorshipDir` field name (see
   `.gaia/cli/src/storage/paths.ts`). Internal-only helper params follow the
   same convention to keep call-site reads aligned. */
/**
 * `gaia mentorship status`.
 *
 * Prints structured JSON describing the mentorship runtime state:
 *   - enabled / analytics_enabled (from mentorship.json)
 *   - install_id (from install-id.txt; null when absent)
 *   - mentorship_dir (absolute path)
 *   - last_event_at (last line of most recent NDJSON; null when no events)
 *   - active_pattern_count / active_adaptation_count (parsed from profile.md)
 *
 * Sensible defaults when fields are missing. Works whether enabled or not.
 * Never prompts. Never throws on missing files — they all fall back to
 * documented defaults.
 */
import {existsSync, readdirSync, readFileSync} from 'node:fs';
import path from 'node:path';
import {EXIT_CODES} from '../exit.js';
import {structuredError} from '../stderr.js';
import {resolveStorageRoots} from '../storage/index.js';
import type {StorageRoots} from '../storage/index.js';
import {readMentorshipConfig} from './config.js';

type RunOptions = {
  roots?: StorageRoots;
};

const NDJSON_GLOB = /^events-\d{4}-\d{2}-\d{2}\.jsonl$/u;

const readInstallId = (installIdPath: string): null | string => {
  if (!existsSync(installIdPath)) return null;

  try {
    const raw = readFileSync(installIdPath, 'utf8').trim();

    return raw.length > 0 ? raw : null;
  } catch {
    return null;
  }
};

const findMostRecentEventsFile = (mentorshipDir: string): null | string => {
  if (!existsSync(mentorshipDir)) return null;
  let entries: string[];

  try {
    entries = readdirSync(mentorshipDir);
  } catch {
    return null;
  }
  const matching = entries
    .filter((entry) => NDJSON_GLOB.test(entry))
    .toSorted((a, b) => a.localeCompare(b));
  const last = matching.at(-1);

  return last === undefined ? null : path.join(mentorshipDir, last);
};

const readLastEventTimestamp = (mentorshipDir: string): null | string => {
  const filePath = findMostRecentEventsFile(mentorshipDir);

  if (filePath === null) return null;

  try {
    const raw = readFileSync(filePath, 'utf8');
    const lines = raw.split('\n').filter((line) => line.length > 0);
    const last = lines.at(-1);

    if (last === undefined) return null;
    const parsed = JSON.parse(last) as {timestamp?: unknown};

    return typeof parsed.timestamp === 'string' ? parsed.timestamp : null;
  } catch {
    return null;
  }
};

const HEADING_PREFIX = '## ';
const BULLET_PATTERN = /^[-*]\s+\S/u;

const countBulletsUnderHeading = (
  markdown: string,
  headingText: string
): number => {
  const lines = markdown.split('\n');
  const target = headingText.toLowerCase();
  let inSection = false;
  let count = 0;

  for (const line of lines) {
    if (line.startsWith(HEADING_PREFIX)) {
      const text = line.slice(HEADING_PREFIX.length).trim().toLowerCase();
      inSection = text === target;
    } else if (inSection && BULLET_PATTERN.test(line)) {
      count += 1;
    }
  }

  return count;
};

type ProfileCounts = {
  activeAdaptationCount: number;
  activePatternCount: number;
};

const readProfileCounts = (profilePath: string): ProfileCounts => {
  if (!existsSync(profilePath)) {
    return {activeAdaptationCount: 0, activePatternCount: 0};
  }

  try {
    const raw = readFileSync(profilePath, 'utf8');

    return {
      activeAdaptationCount: countBulletsUnderHeading(
        raw,
        'Active adaptations'
      ),
      activePatternCount: countBulletsUnderHeading(raw, 'Active patterns'),
    };
  } catch {
    return {activeAdaptationCount: 0, activePatternCount: 0};
  }
};

type StatusPayload = {
  active_adaptation_count: number;
  active_pattern_count: number;
  analytics_enabled: boolean;
  enabled: boolean;
  install_id: null | string;
  last_event_at: null | string;
  mentorship_dir: string;
};

const buildStatus = (roots: StorageRoots): StatusPayload => {
  const config = readMentorshipConfig(roots);
  const installId = readInstallId(roots.installIdPath);
  const lastEventAt = readLastEventTimestamp(roots.mentorshipDir);
  const {activeAdaptationCount, activePatternCount} = readProfileCounts(
    roots.profilePath
  );

  return {
    active_adaptation_count: activeAdaptationCount,
    active_pattern_count: activePatternCount,
    analytics_enabled: config.analytics.enabled,
    enabled: config.enabled === true,
    install_id: installId,
    last_event_at: lastEventAt,
    mentorship_dir: roots.mentorshipDir,
  };
};

export const run = (
  _argv: readonly string[],
  options: RunOptions = {}
): number => {
  const roots = options.roots ?? resolveStorageRoots();

  let payload: StatusPayload;

  try {
    payload = buildStatus(roots);
  } catch (error) {
    structuredError({
      code: 'config_invalid',
      message: error instanceof Error ? error.message : String(error),
    });

    return EXIT_CODES.CONFIG_INVALID;
  }
  process.stdout.write(`${JSON.stringify(payload)}\n`);

  return EXIT_CODES.OK;
};
