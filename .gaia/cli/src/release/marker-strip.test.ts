/**
 * Lockstep guard for the maintainer-only marker strip (#1742).
 *
 * `stripMarkerBlocks` is the parser the release scrub actually runs, and the
 * bats suites carry hand-written awk models of it so they can strip a script
 * and then RUN the stripped copy without taking a dependency on the maintainer
 * CLI. Nothing held those models to the parser: a change to the TypeScript
 * state machine left every model behind with nothing red, and the suites would
 * go on certifying a stripped copy the release scrub does not produce.
 *
 * # Which direction the dependency runs, and why
 *
 * This guard follows `exclude-parser-parity.test.ts`: TypeScript reaches for
 * the shell text, rather than a bats suite reaching for the CLI. The models
 * stay dependency-free standalone bash, which is what they are for, and the
 * binding lives here where the parser lives.
 *
 * # What it asserts
 *
 * 1. `stripMarkerBlocks` and `AWK_PROGRAM` produce identical bytes over a
 *    fixture corpus covering every branch of the state machine, with one
 *    named exemption `UNTERMINATED_START` documents.
 * 2. Every suite carrying the model holds `BATS_AWK_BLOCK` verbatim, so a
 *    model that drifts from the program this file just proved faithful goes
 *    red here.
 * 3. Every such suite declares a delimiter pair that a marker-strip transform
 *    in `.gaia/release-scrub.yml` actually uses, so a suite cannot strip and
 *    pass against a spelling the release retired. The pair is per suite
 *    because the surfaces differ: a suite stripping shell reads the
 *    `#`-comment transform, one stripping markdown the HTML-comment transform.
 * 4. The marker-strip transform governing shell files declares the pair the
 *    corpus's own literals spell, so the corpus is provably pointed at the
 *    transform it claims to test. Assertion 3 cannot say this: it asks only
 *    that SOME transform declare a suite's pair, and two of them declare the
 *    `#` pair.
 *
 * The corpus runs against one delimiter pair rather than every declared pair,
 * and that is not a gap: both sides take their markers as parameters, so the
 * state machine cannot branch on the spelling. Assertion 1 proves the machine,
 * assertion 3 proves each suite's spellings, and assertion 4 proves the pair
 * the corpus itself runs against, each once.
 *
 * # What it does not catch
 *
 * Discovery reads the git index, so a model in a suite that is written but not
 * yet staged is not enrolled. That fails in the safe direction: CI audits the
 * committed tree, so the suite is enrolled by the time it can gate anything,
 * and the miss is bounded to the authoring session that added it.
 *
 * A model written in some other shape entirely, a `sed` range or an awk with
 * its own variable names, carries no `BATS_AWK_INVOCATION` and so is not
 * discovered. That residue is not decidable by text: recognizing an arbitrary
 * hand-rolled strip needs a reader. What the guard does guarantee is that a
 * site converted to this invocation stays converted, and converting a site is
 * what enrolls it.
 *
 * Maintainer-only by construction: `.gaia/cli/src` is release-excluded, so an
 * adopter clone carries neither `marker-strip.ts` nor this test.
 */
import {describe, expect, test} from 'vitest';
import {execFileSync} from 'node:child_process';
import {readFileSync} from 'node:fs';
import path from 'node:path';
import {gitZArgs, splitZStream} from '../util/git-z.js';
import {resolveRepoRootFromImportMeta} from '../util/repo-root-fixture.js';
import {stripMarkerBlocks} from './marker-strip.js';
import {loadConfig} from './scrub.js';

const REPO_ROOT = resolveRepoRootFromImportMeta(import.meta.url);

/**
 * The reference model, byte-identical to the awk each suite carries. Held here
 * rather than extracted from a suite: extracting it would prove two copies of a
 * model match each other, which is the state this guard exists to end.
 */
const AWK_PROGRAM = `
    {
      has_s = index($0, s) > 0
      has_e = index($0, e) > 0
      if (!skip && has_s) { if (!has_e) skip = 1; next }
      if (skip) { if (has_e) skip = 0; next }
      print
    }
  `;

/**
 * The invocation's head, which is what identifies a suite as carrying a model.
 * Discovery keys on this rather than on the whole block below, and the split is
 * load-bearing: keyed on the whole block, a suite whose awk body drifted would
 * simply stop being discovered, its two assertions would vanish, and the guard
 * would go green over a smaller set while still naming itself for every model.
 * Keyed on the head, that suite stays in the set and reds.
 */
const BATS_AWK_INVOCATION =
  'awk -v s="$MAINTAINER_START" -v e="$MAINTAINER_END"';

/**
 * The whole invocation as it is written in each suite, built from
 * `AWK_PROGRAM` so the text this file proves faithful and the text it pins into
 * the suites cannot become two different things.
 */
const BATS_AWK_BLOCK = `${BATS_AWK_INVOCATION} '${AWK_PROGRAM}'`;

const MARKER_STRIP_TRANSFORMS = loadConfig(
  path.join(REPO_ROOT, '.gaia/release-scrub.yml')
).transforms.filter((transform) => transform.type === 'marker-strip');

/**
 * Every marker-strip transform's delimiter pair, keyed by start marker.
 * `.gaia/release-scrub.yml` declares more than one: the shell-and-YAML
 * transform and the `.prettierignore` one share the `#`-comment spellings,
 * while the markdown transform uses HTML-comment spellings. A suite is held to
 * membership in this set rather than to one chosen transform, because which
 * transform governs a suite is decided by the files that suite strips, which
 * no parse of the suite recovers.
 *
 * Membership is a weaker statement than naming the governing transform, and
 * this map's shape is why: it is keyed by start marker, and two transforms
 * declare the `#` start, so `get` returns whichever of them the YAML lists
 * last. A value read out of here is therefore not safe to pin a transform
 * against. The last test in this file names the shell transform directly and
 * pins both halves of its pair against literals instead.
 */
const DECLARED_DELIMITERS = new Map(
  MARKER_STRIP_TRANSFORMS.map((transform) => [transform.start, transform.end])
);

/** The glob naming the transform that governs shell files. */
const SH_TRANSFORM_GLOB = '**/*.sh';

/**
 * The pair governing shell files, the corpus below runs against it. Both halves
 * are literals rather than lookups into `DECLARED_DELIMITERS`: that map is keyed
 * by start marker and two transforms declare this start, so a value read out of
 * it is whichever of them the YAML lists last, which would make an assertion
 * pinning the shell transform against it compare a value with itself. Literals
 * are what let the last test in this file assert both halves against the config
 * and have either half fail.
 */
const START_MARKER = '# gaia:maintainer-only:start';
const END_MARKER = '# gaia:maintainer-only:end';

/**
 * The suites carrying the model, discovered rather than listed: a hand-kept
 * list is the arming condition, and a model added to a suite the list does not
 * name is precisely the drift this guard exists to catch.
 */
const MODEL_SUITES = splitZStream(
  execFileSync('git', gitZArgs('ls-files', ['*.bats']), {
    cwd: REPO_ROOT,
    encoding: 'utf8',
  })
)
  .map((suite) => ({
    suite,
    text: readFileSync(path.join(REPO_ROOT, suite), 'utf8'),
  }))
  .filter(({text}) => text.includes(BATS_AWK_INVOCATION));

const runReferenceModel = (fixture: string): string =>
  execFileSync(
    'awk',
    ['-v', `s=${START_MARKER}`, '-v', `e=${END_MARKER}`, AWK_PROGRAM],
    {encoding: 'utf8', input: fixture}
  );

/**
 * The one source shape on which the two sides disagree, held out of the corpus
 * and asserted on its own below rather than normalized away. `stripMarkerBlocks`
 * splits on `\n`, so a newline-terminated source yields a trailing empty
 * element; inside a block that never closes the element is dropped with
 * everything else, and the output loses its final newline, where awk terminates
 * its last record regardless. That is the state machine, not awk's output
 * contract, so it is written down.
 *
 * Unreachable through the release path: `scrub.ts` fails the build on any
 * unbalanced marker, so a source with an unterminated start never reaches the
 * point where the two outputs would be compared.
 */
const UNTERMINATED_START = `a\n${START_MARKER}\nb\n`;

/**
 * Every branch of the state machine, plus the two shapes that made a real
 * model diverge: a start and end on one line, and an end with no open block
 * (which the shipped parser deliberately KEEPS, `marker-strip.ts:55-57`).
 */
const FIXTURES: {name: string; source: string}[] = [
  {
    name: 'plain pair',
    source: `a\n${START_MARKER}\nsecret\n${END_MARKER}\nb\n`,
  },
  {
    name: 'indented pair',
    source: `a\n  ${START_MARKER}\n  secret\n  ${END_MARKER}\nb\n`,
  },
  {
    name: 'start and end on one line',
    source: `a\n${START_MARKER} ${END_MARKER}\nb\n`,
  },
  {name: 'end without start', source: `a\n${END_MARKER}\nb\n`},
  {
    name: 'end without start, then a real block',
    source: `a\n${END_MARKER}\nb\n${START_MARKER}\nsecret\n${END_MARKER}\nc\n`,
  },
  {
    name: 'nested start',
    source: `a\n${START_MARKER}\nb\n${START_MARKER}\nc\n${END_MARKER}\nd\n`,
  },
  {
    name: 'marker inside a quoted string',
    source: `a\necho "${START_MARKER}"\nb\n${END_MARKER}\nc\n`,
  },
  {
    name: 'marker with trailing text',
    source: `a\n${START_MARKER} rationale\nsecret\n${END_MARKER} .\nb\n`,
  },
  {
    name: 'two blocks',
    source: `a\n${START_MARKER}\nx\n${END_MARKER}\nb\n${START_MARKER}\ny\n${END_MARKER}\nc\n`,
  },
  {name: 'no markers at all', source: 'a\nb\nc\n'},
];

/**
 * A suite's own declaration of each delimiter, matched on its own line rather
 * than as an adjacent pair: the two are read independently, so a suite may
 * order or separate them however it likes.
 */
const START_DECLARATION = /^ *MAINTAINER_START='(?<value>[^']*)'$/mu;
const END_DECLARATION = /^ *MAINTAINER_END='(?<value>[^']*)'$/mu;

/** The fixtures that legitimately close no block, by name. */
const NON_STRIPPING_FIXTURES = new Set([
  'end without start',
  'no markers at all',
]);

describe('marker-strip lockstep (#1742)', () => {
  test('AWK_PROGRAM is the real model text, not a vacuous constant', () => {
    expect(AWK_PROGRAM).toContain(
      'if (!skip && has_s) { if (!has_e) skip = 1; next }'
    );
    expect(BATS_AWK_BLOCK).toContain(
      'awk -v s="$MAINTAINER_START" -v e="$MAINTAINER_END"'
    );
  });

  // Non-vacuity, per fixture rather than sampled: a source with no start
  // marker closes no block. Every other fixture has to report a stripped
  // block, or the two sides below agree on output nobody transformed.
  test.each(FIXTURES)(
    'strips exactly as its shape says: $name',
    ({name, source}) => {
      expect(
        stripMarkerBlocks(source, START_MARKER, END_MARKER).blocks > 0
      ).toBe(!NON_STRIPPING_FIXTURES.has(name));
    }
  );

  test.each(FIXTURES)(
    'stripMarkerBlocks is byte-identical to the reference model: $name',
    ({source}) => {
      expect(stripMarkerBlocks(source, START_MARKER, END_MARKER).output).toBe(
        runReferenceModel(source)
      );
    }
  );

  test('an unterminated start is the one shape the two disagree on', () => {
    expect(
      stripMarkerBlocks(UNTERMINATED_START, START_MARKER, END_MARKER).output
    ).toBe('a');
    expect(runReferenceModel(UNTERMINATED_START)).toBe('a\n');
  });

  test('the suite discovery found the models it exists to check', () => {
    expect(MODEL_SUITES.length).toBeGreaterThan(0);
  });

  test.each(MODEL_SUITES)(
    '$suite carries the reference model verbatim',
    ({text}) => {
      expect(text).toContain(BATS_AWK_BLOCK);
    }
  );

  test.each(MODEL_SUITES)(
    '$suite declares delimiters the shipped scrub uses',
    ({text}) => {
      const start = START_DECLARATION.exec(text)?.groups?.value;
      const end = END_DECLARATION.exec(text)?.groups?.value;

      // Both sides are guarded: `get` on an absent key and an unmatched END
      // declaration both yield undefined, so asserting only their equality
      // would certify a suite that declares neither.
      expect(start).toBeDefined();
      expect(end).toBeDefined();
      expect(DECLARED_DELIMITERS.get(start ?? '')).toBe(end);
    }
  );

  // The membership check above asserts that each suite's pair is declared by
  // some marker-strip transform; it does not say which one governs the corpus.
  // This names that transform and pins both halves of its pair against the
  // literals above, so respelling either half of it reds here. `toBeDefined`
  // carries the case the pins cannot describe: no transform governs shell files
  // at all, which is the config moving rather than the pair being respelled.
  test('the transform governing shell files declares the pair the corpus uses', () => {
    const shellTransform = MARKER_STRIP_TRANSFORMS.find((transform) =>
      transform.paths.includes(SH_TRANSFORM_GLOB)
    );

    expect(shellTransform).toBeDefined();
    expect(shellTransform?.start).toBe(START_MARKER);
    expect(shellTransform?.end).toBe(END_MARKER);
  });
});
