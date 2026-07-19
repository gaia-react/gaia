import {describe, expect, test} from 'vitest';
import {execFileSync} from 'node:child_process';
import {renderExcludeRegex} from './manifest.js';

/**
 * Regression test for #839 (the #679 remainder): the CLI's exclude-regex
 * compiler must stay byte-identical to the shell `awk | sed | awk` pipeline
 * every release surface used to carry inline.
 *
 * Independent reference oracle. A byte-for-byte copy of the retired
 * awk | sed | awk compile, hardcoded here (never extracted from a migrated
 * file) so this guard proves the CLI emitter equals the reference, not that
 * two inline pipelines match. Must stay byte-identical to the shell text.
 */
const REFERENCE_PIPELINE_STAGE1 =
  "awk '/^[[:space:]]*#/ {next} NF==0 {next} {print}' | ";
const REFERENCE_PIPELINE_STAGE2 = String.raw`sed 's|[][\\.*^$()+?{}|]|\\&|g' | `;
const REFERENCE_PIPELINE_STAGE3 = 'awk \'{print "^"$0"(/|$)"}\'';
const REFERENCE_PIPELINE =
  REFERENCE_PIPELINE_STAGE1 +
  REFERENCE_PIPELINE_STAGE2 +
  REFERENCE_PIPELINE_STAGE3;

const runReferencePipeline = (fixture: string): string =>
  execFileSync('bash', ['-c', REFERENCE_PIPELINE], {
    encoding: 'utf8',
    input: fixture,
  });

describe('exclude-parser parity (#839)', () => {
  test('REFERENCE_PIPELINE is the exact shell text (sanity, not a vacuous constant)', () => {
    expect(REFERENCE_PIPELINE).toContain(
      String.raw`sed 's|[][\\.*^$()+?{}|]|\\&|g'`
    );
  });

  test('renderExcludeRegex is byte-identical to the reference pipeline for the full escape class, multi-segment paths, comments, and blanks', () => {
    // Covers every metacharacter `escapeRegExp` handles (UAT-002): . + $ (
    // ) { } [ ] ^ | ? * \. Also covers a multi-segment `/` dir-prefix entry
    // (`.gaia/scripts`), a `+`-bearing literal mirroring GAIA's own
    // `app/routes/_public+/`, a comment line, and a blank line.
    const fixture =
      '# fixture comment, stripped by stage 1\n' +
      '\n' +
      '.gaia/scripts\n' +
      'CHANGELOG.md\n' +
      'wiki/hot.md\n' +
      'app/routes/_public+\n' +
      'file.name\n' +
      'weird$file\n' +
      'func(x).log\n' +
      'dir/{brace}.txt\n' +
      'array[0].txt\n' +
      'caret^file\n' +
      'pipe|file\n' +
      'question?file\n' +
      'star*file\n' +
      'back\\slash\n';

    const cliOutput = renderExcludeRegex(fixture);
    const referenceOutput = runReferencePipeline(fixture);

    expect(cliOutput).toBe(referenceOutput);

    // Sanity: the fixture actually produced compiled patterns, not a
    // vacuous empty-string pass.
    expect(
      cliOutput.split('\n').filter((line) => line.length > 0)
    ).toHaveLength(14);
  });

  test('empty case: a comments/blanks-only source yields zero bytes from both sides', () => {
    const fixture = '# only a comment\n\n   \n\t\n';

    expect(renderExcludeRegex(fixture)).toBe('');
    expect(runReferencePipeline(fixture)).toBe('');
  });
});
