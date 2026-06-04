/**
 * Pattern → adaptation linker, plus per-adaptation static text.
 *
 * Locked exports:
 *   - `PATTERN_TO_ADAPTATION`: pattern_id -> adaptation_id map
 *   - `ADAPTATION_TEXT`      : adaptation_id -> coaching block text
 *
 * The adaptation-inject module imports these by name from this file;
 * renaming either is a contract break.
 *
 * `{{area}}` substitutions are performed at injection time by the consumer,
 * not here.
 */

export const PATTERN_TO_ADAPTATION = {
  articulation_gap: 'po_socratic_depth_increased',
  intent_clarity_gap: 'po_example_specs_offered',
  knowledge_gap: 'engineer_commentary_verbosity_increased',
} as const;

export type AdaptationId = (typeof PATTERN_TO_ADAPTATION)[PatternId];

export type PatternId = keyof typeof PATTERN_TO_ADAPTATION;

export const ADAPTATION_TEXT: Record<AdaptationId, string> = {
  engineer_commentary_verbosity_increased:
    'The user has needed more codebase orientation when working in {{area}}. Front-load orientation context: what file owns this, what calls it, what depends on it. Reduce surprise.',
  po_example_specs_offered:
    'The user has historically amended specs after closing in {{area}}. Surface example SPECs from prior similar work during Q&A; lengthen the question phase before drafting.',
  po_socratic_depth_increased:
    "The user has historically had trouble articulating success criteria for {{area}} work. Coach more on observable outcomes: what changes, what stays, what would prove this done? Push past 'looks right' or 'feels good' to concrete checks.",
};
