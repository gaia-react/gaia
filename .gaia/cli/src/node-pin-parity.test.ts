/**
 * Maintainer drift-guard for the Node version, which four files state
 * independently and nothing derives from anything.
 *
 * `package.json`'s `engines.node` declares the floor. `.node-version` and
 * `.nvmrc` name the version local development and CI actually resolve. The
 * `FROM node:<tag>` lines in `Dockerfile` name the version an adopter's
 * deployed image runs. Raising the floor is a one-file edit, so the other
 * three keep whatever they said and nothing reports it.
 *
 * The failure is silent in the direction that matters. `pnpm-workspace.yaml`
 * sets no `engineStrict` and `.npmrc` carries no `engine-strict`, so
 * `pnpm install --frozen-lockfile` inside the image warns rather than fails,
 * and nothing in this repository builds `Dockerfile` in CI at all: the two
 * `docker build` invocations under `.gaia/tests/distribution/` build a heredoc
 * Dockerfile of their own. A green CI run is therefore not evidence that the
 * image an adopter deploys satisfies the floor `package.json` declares, and any
 * dependency or application path relying on behavior landed above the image's
 * Node version passes everywhere it is exercised and fails only in the
 * container.
 *
 * Not hypothetical: a floor raise from `>=22.19.0` to `>=22.22.0` left
 * `Dockerfile` on `node:22.19-alpine`, below the repo's own declared minimum,
 * and nothing reported it until a human read the file (#1626). Repairing that
 * instance is not what stops the next one; this guard is (#1629).
 *
 * # What each subject is held to
 *
 * `.node-version` and `.nvmrc` are exact versions, so they are compared exactly:
 * they must equal each other, and each must satisfy the floor.
 *
 * A Docker tag is held to its LOWEST resolution, because that is what the image
 * can actually pull. `node:22.23-alpine` floats within its patch line, so the
 * least it can resolve to is `22.23.0`, and a floor of `>=22.23.1` is therefore
 * not satisfied by it even though today's `22.23.x` would happen to satisfy it.
 * Asserting on the lowest resolution is what keeps the guard honest about a tag
 * that only accidentally passes.
 *
 * # Reading a FROM line the way Docker reads it
 *
 * The instruction is case-insensitive, may be indented, and may carry flags
 * (`FROM --platform=$BUILDPLATFORM node:22-alpine AS build`). A reader anchored
 * on a bare `FROM node:` at column zero matches none of those, and the way it
 * fails is the failure this whole guard exists to prevent: the stage silently
 * leaves the checked set, and a clean run and a blind run are indistinguishable.
 * So the reader parses the line into its image reference the way Docker does,
 * flags dropped and the `AS <stage>` suffix dropped, and the anti-vacuity
 * assertion below is what catches a reader that has stopped matching anything.
 *
 * # Anything unparseable reds rather than passes
 *
 * An `engines.node` range this reader does not recognize, a version file that
 * is not a bare version, and a node image this reader will not score (`node`,
 * `node:lts-alpine`, `node:latest`, and any digest pin, `node@sha256:...` and
 * `node:22-alpine@sha256:...` alike) each fail loudly. Only a plain tag is
 * scored: a digest pin resolves by its digest and ignores any tag beside it, so
 * the tag there names a version the reference does not run. A floating tag defeats the pin outright, and a guard that shrugged at
 * a spelling it could not read would go quiet exactly where the drift is worst.
 *
 * Refusing and not-matching are different outcomes and the difference is
 * load-bearing: a reference the FROM reader declines to recognize leaves the
 * checked set silently, which is the failure above, while one it recognizes and
 * cannot score reds. So the reader recognizes every `node` reference it can and
 * leaves the refusing to the version parser.
 *
 * Repair, when this goes red: bring the file the failure names up to the floor.
 * The floor itself is the deliberate statement; the other three follow it.
 *
 * # Why the readers are pure and separately driven
 *
 * Every assertion below that reads the repository passes on today's tree, so a
 * mutation of a reader (a widened range pattern, a lowest-resolution rule that
 * fills the omitted components with anything but zero, a FROM matcher that
 * stops seeing a spelling) survives against a compliant tree with nothing to
 * report it. The readers are therefore pure functions over strings, and the
 * second describe block drives them with the shapes the tree does not currently
 * contain. That block is what makes this guard's own logic checkable; the first
 * block is what points it at the real files.
 *
 * Fires on the pull request that causes the drift: `package.json`,
 * `.node-version`, `.nvmrc` and `Dockerfile` are all four in the `code` paths
 * filter of `cli-tests.yml`, whose `Vitest (.gaia/cli)` job is a
 * declared-required context. Keep all four entries: each subject is edited
 * alone, and without its entry the guard first fires on some later, unrelated
 * `.gaia/cli/**` change.
 *
 * Maintainer-only by construction: `.gaia/cli/src` is release-excluded, so an
 * adopter clone carries this test's subjects but not the test. Mirrors
 * `lint-pin-parity.test.ts`.
 */
import {describe, expect, test} from 'vitest';
import {readFileSync} from 'node:fs';
import path from 'node:path';
import {resolveRepoRootFromImportMeta} from './util/repo-root-fixture.js';

type Version = [number, number, number];

const REPO_ROOT = resolveRepoRootFromImportMeta(import.meta.url);

// The version files, each a bare version on one line. Both are listed because
// they drift independently: an editor updating one has no reason to notice the
// other exists.
const VERSION_FILES = ['.node-version', '.nvmrc'] as const;

// A `FROM` line's arguments. Case-insensitive and leading-whitespace tolerant
// because Docker accepts both, and multiline because the subject is a whole
// file. A `#`-commented line cannot match, since the comment character precedes
// the instruction.
//
// The capture opens on `\S` rather than on `.`, which is what keeps the match
// linear: `.` matches a space, so a `[ \t]+(.+)` seam lets a run of spaces be
// divided between the separator and the capture in as many ways as it is long,
// and the engine tries each one before failing a non-matching line.
const FROM_LINE_PATTERN = /^[ \t]*FROM[ \t]+(\S.*)$/gim;

// An image reference naming the official `node` image, with whatever qualifies
// it captured. The optional registry/namespace prefix must end at a slash, so
// `mynode:22` is not a match: only a whole path component spelled `node` is.
//
// The qualifier separator is `[:@]`, not `:`, so a digest pin
// (`node@sha256:...`) is RECOGNIZED here and refused by `lowestResolutionOf`
// rather than filtered out of the set by this pattern. The difference is the
// whole point: a reference this pattern rejects leaves the checked set with no
// diagnostic, and a stage that silently stops being checked is the failure the
// guard exists to prevent. This repo already digest-pins its GitHub Actions, so
// a digest-pinned build stage is the direction the tree moves, not a
// hypothetical. Allowing `:` inside the prefix admits a registry carrying a
// port (`my-registry.io:5000/node:22-alpine`), dropped for the same reason.
const NODE_IMAGE_PATTERN = /^(?:[^\s]*\/)?node(?:[:@](.+))?$/i;

// The one `engines.node` spelling this repo uses. Deliberately narrow: a caret
// or a compound range means something different about the ceiling as well as
// the floor, and reading one as a floor would understate what it permits. An
// unmatched spelling throws below rather than resolving to a default.
const ENGINES_FLOOR_PATTERN = /^>=\s*(\d+)\.(\d+)\.(\d+)$/;

// A bare `X.Y.Z`, which is the whole of what a version file may contain.
const EXACT_VERSION_PATTERN = /^(\d+)\.(\d+)\.(\d+)$/;

// A WHOLE tag: a version, optionally carrying a `-` or `_` suffix (`-alpine`,
// `-bookworm-slim`). Anchored at both ends deliberately. A pattern anchored
// only at the start matches a prefix of anything that merely begins with
// digits, and the optional groups then backtrack to whatever prefix does match,
// so `22.23beta` reads as `22.0.0` -- a version the tag never named, compared
// against the floor as if it had. Refusing the whole tag is the honest answer:
// a spelling this reader cannot account for is not one it should score.
const TAG_VERSION_PATTERN = /^(\d+)(?:\.(\d+))?(?:\.(\d+))?(?:[-_].*)?$/;

const readRepoFile = (relativePath: string): string =>
  readFileSync(path.join(REPO_ROOT, relativePath), 'utf8');

const formatVersion = ([major, minor, patch]: Version): string =>
  `${major}.${minor}.${patch}`;

/** Negative when `a` is lower than `b`, zero when equal, positive when higher. */
const compareVersions = (a: Version, b: Version): number =>
  a[0] - b[0] || a[1] - b[1] || a[2] - b[2];

/**
 * The floor an `engines.node` range declares.
 *
 * Throws on a spelling this reader does not recognize: the alternative is a
 * guard that passes because it could not read its own subject.
 */
const parseFloor = (declared: string): Version => {
  const match = ENGINES_FLOOR_PATTERN.exec(declared.trim());

  if (!match) {
    throw new Error(
      `engines.node is "${declared}", which this guard cannot read as a floor. Recognized spelling: ">=X.Y.Z".`
    );
  }

  return [Number(match[1]), Number(match[2]), Number(match[3])];
};

/** A version file's contents, which must be exactly `X.Y.Z`. */
const parseExactVersion = (label: string, contents: string): Version => {
  const match = EXACT_VERSION_PATTERN.exec(contents.trim());

  if (!match) {
    throw new Error(
      `${label} reads "${contents.trim()}", which is not a bare X.Y.Z version.`
    );
  }

  return [Number(match[1]), Number(match[2]), Number(match[3])];
};

/**
 * The lowest version a node image reference can resolve to. A tag names a
 * prefix, so the components it omits are zero: `node:22.23` can pull `22.23.0`.
 *
 * Throws on a reference carrying no numeric version at all, `node` and
 * `node:lts-alpine` alike. Both float across major versions, so neither can be
 * held to a floor, and holding one to a guess is worse than saying so.
 */
const lowestResolutionOf = (reference: string): Version => {
  const qualifier = NODE_IMAGE_PATTERN.exec(reference)?.[1];
  // Score a plain tag and nothing else. A qualifier carrying `@` is a digest
  // pin, and Docker resolves such a reference BY the digest and ignores the tag
  // beside it, so `node:22.23-alpine@sha256:<digest of a 22.19 image>` runs
  // 22.19 whatever the tag says. Reading the tag there scores a number that
  // does not govern what pulls, which is this guard's own silent-pass class.
  //
  // Stated as one rule rather than as a case per spelling: `node@sha256:...`
  // and `node:<tag>@sha256:...` are the same defect one spelling apart, and a
  // reader that enumerates spellings is a reader the next spelling defeats.
  const tag =
    qualifier === undefined || qualifier.includes('@') ? undefined : qualifier;
  const match = tag === undefined ? null : TAG_VERSION_PATTERN.exec(tag);

  if (!match) {
    throw new Error(
      `Dockerfile pins ${reference}, which names no version. A floating tag cannot be held to the engines.node floor.`
    );
  }

  return [Number(match[1]), Number(match[2] ?? 0), Number(match[3] ?? 0)];
};

/**
 * The image reference a `FROM` line names: its flags and its `AS <stage>`
 * suffix removed, the way Docker resolves it.
 */
const imageReferenceOf = (fromArguments: string): string | undefined =>
  fromArguments
    .trim()
    .split(/\s+/)
    .find((token) => !token.startsWith('--'));

/** Every node image reference the Dockerfile's `FROM` lines name, in file order. */
const nodeImageReferences = (dockerfile: string): string[] =>
  [...dockerfile.matchAll(FROM_LINE_PATTERN)]
    .map(([, fromArguments = '']) => imageReferenceOf(fromArguments))
    .filter(
      (reference): reference is string =>
        reference !== undefined && NODE_IMAGE_PATTERN.test(reference)
    );

const readEnginesFloor = (): Version => {
  const manifest = JSON.parse(readRepoFile('package.json')) as {
    engines?: {node?: string};
  };
  const declared = manifest.engines?.node;

  if (declared === undefined) {
    throw new Error('package.json declares no engines.node');
  }

  return parseFloor(declared);
};

const readVersionFile = (relativePath: string): Version =>
  parseExactVersion(relativePath, readRepoFile(relativePath));

describe('the repository states one Node version', () => {
  // Read per test rather than once in this block. A `describe` body runs at
  // collection time, so an unreadable `engines.node` thrown from here fails the
  // whole FILE, taking the reader block below with it and hiding whether the
  // readers still work at the moment that answer is most wanted.
  test.each(VERSION_FILES)('%s satisfies the engines.node floor', (file) => {
    const floor = readEnginesFloor();
    const version = readVersionFile(file);

    expect(
      compareVersions(version, floor),
      `${file} is ${formatVersion(version)}, below the engines.node floor ${formatVersion(floor)}`
    ).toBeGreaterThanOrEqual(0);
  });

  test('.node-version and .nvmrc name the same version', () => {
    expect(formatVersion(readVersionFile('.node-version'))).toBe(
      formatVersion(readVersionFile('.nvmrc'))
    );
  });

  // Anti-vacuity floor rather than a count of today's four stages: a Dockerfile
  // stage added or dropped is ordinary, a reader that suddenly matches nothing
  // is the failure this catches, and it would otherwise leave the assertion
  // below passing over an empty set.
  test('the Dockerfile builds on the node image in at least one stage', () => {
    expect(
      nodeImageReferences(readRepoFile('Dockerfile')).length
    ).toBeGreaterThan(0);
  });

  test('every Dockerfile node image resolves at or above the floor', () => {
    const floor = readEnginesFloor();
    const below = nodeImageReferences(readRepoFile('Dockerfile'))
      .map((reference) => ({lowest: lowestResolutionOf(reference), reference}))
      .filter(({lowest}) => compareVersions(lowest, floor) < 0)
      .map(
        ({lowest, reference}) =>
          `${reference} can resolve as low as ${formatVersion(lowest)}`
      );

    expect(
      below,
      `Dockerfile images below the engines.node floor ${formatVersion(floor)}`
    ).toEqual([]);
  });
});

describe('the readers behind that comparison', () => {
  test('parseFloor reads the spelling this repo uses', () => {
    expect(parseFloor('>=22.22.0')).toEqual([22, 22, 0]);
  });

  test.each(['^22.22.0', '~22.22.0', '>=22.22', '22.22.0', '>=22.22.0 <23'])(
    'parseFloor refuses %s rather than guessing a floor',
    (declared) => {
      expect(() => parseFloor(declared)).toThrow(/cannot read as a floor/);
    }
  );

  test('parseExactVersion reads a bare version', () => {
    expect(parseExactVersion('.nvmrc', '22.23.1\n')).toEqual([22, 23, 1]);
  });

  test.each(['v22.23.1', '22.23', 'lts/jod', ''])(
    'parseExactVersion refuses %s',
    (contents) => {
      expect(() => parseExactVersion('.nvmrc', contents)).toThrow(
        /not a bare X\.Y\.Z version/
      );
    }
  );

  // The lowest-resolution rule, stated as the cases that distinguish it from
  // reading a tag as an exact version. A rule filling the omitted components
  // with anything but zero passes against today's compliant tree and fails
  // here.
  test.each([
    ['node:22.23.1-alpine', [22, 23, 1]],
    ['node:22.23-alpine', [22, 23, 0]],
    ['node:22-alpine', [22, 0, 0]],
    ['node:22.23', [22, 23, 0]],
    ['library/node:22.23-alpine', [22, 23, 0]],
    ['node:22-bookworm-slim', [22, 0, 0]],
    // A longer number is its own major, never a prefix match on a shorter one.
    ['node:220.1', [220, 1, 0]],
  ] as const)('lowestResolutionOf %s is %j', (reference, expected) => {
    expect(lowestResolutionOf(reference)).toEqual(expected);
  });

  test.each([
    'node',
    'node:latest',
    'node:lts-alpine',
    'node:alpine',
    // Digit-led but not a version this reader can account for. Both would read
    // as a truncated version under a start-anchored pattern, which scores the
    // tag against the floor on a number it never named.
    'node:22x',
    'node:22.23beta',
    // A digest pin. It has to REACH here to be refused; a FROM reader that
    // declined to recognize it would drop the stage instead. Both spellings,
    // because the conventional one carries a tag the reference does not
    // resolve by, which is the harder of the two to notice.
    'node@sha256:0000000000000000000000000000000000000000000000000000000000000000',
    'node:22.23-alpine@sha256:0000000000000000000000000000000000000000000000000000000000000000',
    'library/node:22-alpine@sha256:abc',
  ])('lowestResolutionOf refuses the unscoreable reference %s', (reference) => {
    expect(() => lowestResolutionOf(reference)).toThrow(/names no version/);
  });

  // A minor-line tag does not satisfy a patch-level floor, which is the whole
  // point of holding a tag to its lowest resolution.
  test('a minor-line tag sits below a patch-level floor', () => {
    expect(
      compareVersions(lowestResolutionOf('node:22.23-alpine'), [22, 23, 1])
    ).toBeLessThan(0);
  });

  test('compareVersions orders by major, then minor, then patch', () => {
    expect(compareVersions([22, 23, 0], [22, 22, 9])).toBeGreaterThan(0);
    expect(compareVersions([22, 23, 0], [22, 23, 0])).toBe(0);
    expect(compareVersions([9, 0, 0], [10, 0, 0])).toBeLessThan(0);
  });

  test('imageReferenceOf drops flags and the AS suffix', () => {
    expect(
      imageReferenceOf('--platform=$BUILDPLATFORM node:22-alpine AS b')
    ).toBe('node:22-alpine');
    expect(imageReferenceOf('node:22-alpine')).toBe('node:22-alpine');
  });

  // Every spelling Docker accepts that a `^FROM node:` reader would miss. Each
  // one missed is a stage that leaves the checked set with no diagnostic, which
  // is the failure mode this whole guard exists to prevent.
  test.each([
    ['FROM node:22-alpine AS build', ['node:22-alpine']],
    ['  FROM node:22-alpine', ['node:22-alpine']],
    ['\tfrom node:22-alpine', ['node:22-alpine']],
    ['FROM --platform=$BUILDPLATFORM node:22-alpine', ['node:22-alpine']],
    ['FROM library/node:22-alpine', ['library/node:22-alpine']],
    ['FROM node', ['node']],
    // Recognized so it reaches the version parser and is refused there. The
    // regression this pins is a stage leaving the set with no diagnostic.
    ['FROM node@sha256:abc AS runtime', ['node@sha256:abc']],
    [
      'FROM my-registry.io:5000/node:22-alpine',
      ['my-registry.io:5000/node:22-alpine'],
    ],
  ] as const)('nodeImageReferences reads %s', (line, expected) => {
    expect(nodeImageReferences(line)).toEqual(expected);
  });

  test.each([
    '# FROM node:22-alpine',
    'RUN echo FROM node:22-alpine',
    'FROM mynode:22-alpine',
    'FROM notnode',
    'FROM alpine:3.20',
    'FROM my-registry.io/team/node-tools:1.0',
  ])('nodeImageReferences does not read %s as a node image', (line) => {
    expect(nodeImageReferences(line)).toEqual([]);
  });

  test('nodeImageReferences reads every stage of a multi-stage file', () => {
    const dockerfile = [
      'FROM node:22.23-alpine AS deps',
      'RUN pnpm install',
      '',
      'FROM --platform=$BUILDPLATFORM node:22.23-alpine AS build',
      'COPY . .',
      '',
      '  from node:22.23-alpine',
    ].join('\n');

    expect(nodeImageReferences(dockerfile)).toHaveLength(3);
  });

  // The mixed file is the shape that makes a dropped stage invisible: the
  // tagged stages keep the anti-vacuity assertion green while the digest stage
  // goes unchecked, so a count is the only thing that can catch it.
  test('a digest-pinned stage stays in the set beside a tagged one', () => {
    const dockerfile = [
      'FROM node:22.23-alpine AS deps',
      'FROM node@sha256:abc AS runtime',
    ].join('\n');

    expect(nodeImageReferences(dockerfile)).toHaveLength(2);
    expect(() =>
      nodeImageReferences(dockerfile).map(lowestResolutionOf)
    ).toThrow(/names no version/);
  });

  // The tag-plus-digest spelling is the conventional one, and it is the shape a
  // tag-reading scorer gets wrong most quietly: the tag looks compliant while
  // the digest beside it is what actually pulls.
  test('a tag-plus-digest stage is refused, not scored on its tag', () => {
    const dockerfile = 'FROM node:22.23-alpine@sha256:abc AS runtime';

    expect(nodeImageReferences(dockerfile)).toEqual([
      'node:22.23-alpine@sha256:abc',
    ]);
    expect(() =>
      nodeImageReferences(dockerfile).map(lowestResolutionOf)
    ).toThrow(/names no version/);
  });
});
