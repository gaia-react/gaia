/**
 * profile.md writer.
 *
 * - Renders the profile.md contents from pattern results + adaptation state.
 * - Atomic write contract: write-temp-and-rename, mode 0o600.
 * - DO-NOT-EDIT header is the first line, exact wording.
 */
import {atomicWriteFile} from '../util/atomic-write.js';
import {ADAPTATION_TEXT, PATTERN_TO_ADAPTATION} from './adaptation-map.js';
import type {AdaptationId, PatternId} from './adaptation-map.js';
import {PROFILE_DO_NOT_EDIT_HEADER} from './header.js';
import type {PatternResult} from './patterns/types.js';
import {STRENGTH_THRESHOLD} from './strength.js';

export type AdaptationRecord = {
  adaptation_id: AdaptationId;
  area_tag: string;
  effective_strength: number;
  fade_factor: number;
  pattern_id: PatternId;
  raw_strength: number;
  sample_count: number;
  status: AdaptationStatus;
};

export type AdaptationStatus = 'active' | 'faded';

export type ProfileRenderArgs = {
  adaptations: readonly AdaptationRecord[];
  generatedAt: Date;
  mentorshipEnabled: boolean;
  patterns: readonly PatternResult[];
  windowDays: number;
};

const PATTERN_DISPLAY_ORDER: readonly PatternId[] = [
  'articulation_gap',
  'knowledge_gap',
  'intent_clarity_gap',
];

const formatNumber = (value: number, digits: number): string =>
  Number.isNaN(value) ? '0' : value.toFixed(digits);

const renderHeaderBlock = (args: ProfileRenderArgs): string =>
  [
    PROFILE_DO_NOT_EDIT_HEADER,
    '',
    '# Mentorship profile',
    '',
    `Generated: ${args.generatedAt.toISOString()}`,
    `Window: last ${args.windowDays} days`,
    `Mentorship enabled: ${args.mentorshipEnabled ? 'true' : 'false'}`,
  ].join('\n');

const renderActivePatternLine = (pattern: PatternResult): string =>
  `- ${pattern.pattern_id} (${pattern.area_tag}): strength ${formatNumber(
    pattern.strength ?? 0,
    2
  )}, N=${pattern.sample_count}`;

const renderActivePatternsSection = (
  patterns: readonly PatternResult[]
): string => {
  const fired = patterns.filter(
    (pattern) =>
      pattern.strength !== null && pattern.strength >= STRENGTH_THRESHOLD
  );

  if (fired.length === 0) {
    return [
      '## Active patterns',
      '',
      '(none - all patterns below sample threshold or strength below threshold)',
    ].join('\n');
  }

  return [
    '## Active patterns',
    '',
    ...fired.map((p) => renderActivePatternLine(p)),
  ].join('\n');
};

const renderAdaptationLine = (record: AdaptationRecord): string => {
  const text = ADAPTATION_TEXT[record.adaptation_id];

  return [
    `- ${record.adaptation_id} (${record.area_tag}, linked to ${record.pattern_id}):`,
    `    strength=${formatNumber(record.effective_strength, 2)}`,
    `    fade_factor=${formatNumber(record.fade_factor, 2)}`,
    `    text: ${text}`,
  ].join('\n');
};

const renderAdaptationSection = (
  heading: string,
  records: readonly AdaptationRecord[]
): string => {
  if (records.length === 0) return [heading, '', '(none)'].join('\n');

  return [
    heading,
    '',
    ...records.map((record) => renderAdaptationLine(record)),
  ].join('\n');
};

const renderActiveAdaptationsSection = (
  adaptations: readonly AdaptationRecord[]
): string =>
  renderAdaptationSection(
    '## Active adaptations',
    adaptations.filter((record) => record.status === 'active')
  );

const renderFadedAdaptationsSection = (
  adaptations: readonly AdaptationRecord[]
): string =>
  renderAdaptationSection(
    '## Faded adaptations',
    adaptations.filter((record) => record.status === 'faded')
  );

const renderPatternDetailLine = (pattern: PatternResult): string => {
  if (pattern.strength === null) {
    return `- ${pattern.area_tag}: below sample threshold (N=${pattern.sample_count}, min 10) - no fire`;
  }
  const verb =
    pattern.strength >= STRENGTH_THRESHOLD ? 'fired' : 'below threshold';

  return `- ${pattern.area_tag}: strength ${formatNumber(
    pattern.strength,
    2
  )} (N=${pattern.sample_count}) - ${verb}`;
};

const renderPatternDetailGroup = (
  groupPatternId: PatternId,
  patterns: readonly PatternResult[]
): string => {
  const groupResults = patterns.filter(
    (pattern) => pattern.pattern_id === groupPatternId
  );

  if (groupResults.length === 0) {
    return [
      `### ${groupPatternId}`,
      '',
      '(below sample threshold across all areas)',
    ].join('\n');
  }

  return [
    `### ${groupPatternId}`,
    '',
    ...groupResults.map((pattern) => renderPatternDetailLine(pattern)),
  ].join('\n');
};

const renderPatternDetailSection = (
  patterns: readonly PatternResult[]
): string => {
  const groups = PATTERN_DISPLAY_ORDER.map((groupPatternId) =>
    renderPatternDetailGroup(groupPatternId, patterns)
  );

  return ['## Pattern detail', '', ...groups].join('\n\n');
};

export const renderProfile = (args: ProfileRenderArgs): string => {
  const sections = [
    renderHeaderBlock(args),
    renderActivePatternsSection(args.patterns),
    renderActiveAdaptationsSection(args.adaptations),
    renderFadedAdaptationsSection(args.adaptations),
    renderPatternDetailSection(args.patterns),
  ];

  return `${sections.join('\n\n')}\n`;
};

/**
 * Atomic write via the shared temp-fsync-rename helper. Mode 0o600 because
 * profile.md lives under the off-project mentorship subtree (chmod 600 on
 * every file there).
 */
export const atomicWriteProfile = async (
  profilePath: string,
  contents: string
): Promise<void> => atomicWriteFile(profilePath, contents, {mode: 0o600});

export {PATTERN_TO_ADAPTATION};
