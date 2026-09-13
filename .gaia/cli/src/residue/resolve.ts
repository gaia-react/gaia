/**
 * Cited-line resolution: classifies a residual's fate at the pull request's
 * head object against the file's current `HEAD` content.
 *
 * Resolved from the pull request's head object, never from the provenance
 * line: the provenance line carries a usable head reference on only about a
 * third of rows, and its absence must not affect the display.
 */
import type {CorpusProvider} from './corpus.js';

export type ResolutionKind =
  'gone' | 'moved' | 'still' | 'unresolvable' | 'unresolved';

export type ResolveCandidate = {
  headSha: string;
  line: number;
  path: string;
  prNumber: number;
};

export type ResolvedCandidate = {
  resolution: ResolutionKind;
  resolved_line_text: string;
};

const isBlank = (line: string | undefined): boolean =>
  line === undefined || line.trim() === '';

export const resolveCitedLine = (
  provider: CorpusProvider,
  candidate: ResolveCandidate
): ResolvedCandidate => {
  const headText = provider.blobAt(
    candidate.headSha,
    candidate.path,
    candidate.prNumber
  );

  if (headText === null) {
    return {resolution: 'unresolvable', resolved_line_text: ''};
  }

  const rawCitedLine = headText.split('\n')[candidate.line - 1];

  if (isBlank(rawCitedLine)) {
    return {resolution: 'unresolvable', resolved_line_text: ''};
  }

  const citedLine = rawCitedLine as string;

  const currentText = provider.blobAtHead(candidate.path);

  if (currentText === null) {
    return {resolution: 'gone', resolved_line_text: citedLine};
  }

  const currentLines = currentText.split('\n');

  if (currentLines[candidate.line - 1] === citedLine) {
    return {resolution: 'still', resolved_line_text: citedLine};
  }

  if (currentLines.includes(citedLine)) {
    return {resolution: 'moved', resolved_line_text: citedLine};
  }

  return {resolution: 'gone', resolved_line_text: citedLine};
};

/** The resolver `--count-only` wires in: no I/O, always `unresolved` (RD-004). */
export const unresolvedResolver = (): ResolvedCandidate => ({
  resolution: 'unresolved',
  resolved_line_text: '',
});
