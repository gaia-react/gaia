/**
 * The frozen provenance marker `/gaia-harden` writes into a promoted rule.
 *
 * Single source of truth for the marker text. The `covered-classes.ts`
 * `MARKER_RE` (prefix-bound / tail-agnostic), `/gaia-audit` (full-text), the doc
 * copies (`harden.md` template + frozen-marker section, `audit.md`, and
 * `wiki/concepts/Policy-Memory Loop.md`), and the `marker.test.ts` guard all
 * bind to these two exports. A drifted copy silently breaks one binder or the
 * other, so the guard test asserts every copy reproduces `markerComment(...)`
 * byte for byte.
 */

/** The prefix the covered-classes binder matches; also the stable head of the doc copies. */
export const MARKER_PREFIX = 'gaia-harden: promoted from recurring finding_class';

/** The full, frozen provenance-marker comment for a given finding_class (or the '<class>' literal). */
export const markerComment = (findingClass: string): string =>
  `<!-- ${MARKER_PREFIX} ${findingClass}; pruned by /gaia-audit on obsolescence/redundancy/supersession/duplication only, never for non-recurrence -->`;
