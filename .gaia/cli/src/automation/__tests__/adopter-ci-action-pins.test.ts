/**
 * Maintainer drift-guard for the third-party action pins in the workflow
 * templates, the ones that render an adopter's `.github/workflows/`.
 *
 * A major tag (`actions/checkout@v5`) is a moving ref: it resolves to whatever
 * the tag points at the moment an adopter's CI runs, so a force-moved upstream
 * tag executes in the adopter's job with that job's token. Every template
 * therefore pins to a full-length commit SHA with the resolved tag in a
 * trailing comment, which is the convention `code-review-audit.yml.tmpl`
 * already states in its own header.
 *
 * Pinning alone would trade a mutable ref for a frozen one. `.tmpl` files sit
 * outside `.github/workflows/`, so Dependabot cannot see them
 * (`.github/dependabot.yml` says so in writing), and a frozen pin nobody
 * advances means adopters stop receiving upstream patches. The second test
 * below is the mechanism that keeps them moving: it asserts each template pin
 * against the pin the maintainer's own workflows run, which Dependabot bumps
 * weekly. A bump lands in `.github/workflows/` first and turns this red until
 * the same pin is mirrored into the template, and the mirrored pin reaches
 * adopters on the next `/update-gaia`. That is the same red-then-mirror flow
 * `dependabot.yml` already documents for `code-review-audit.yml`.
 *
 * Repair, when the parity test goes red: copy the `<sha> # <tag>` the failure
 * message names from the maintainer workflows into the template site it names,
 * then regenerate the render snapshots (`pnpm test --run -u` in `.gaia/cli`).
 *
 * Maintainer-only by construction: `.gaia/cli/src` is release-excluded, so this
 * test is absent on adopter clones. The parity test additionally skips when
 * `.github/workflows/` is absent, mirroring the sibling guards.
 */
import {describe, expect, test} from 'vitest';
import {existsSync, readdirSync, readFileSync} from 'node:fs';
import path from 'node:path';
import {resolveRepoRootFromImportMeta} from '../../util/repo-root-fixture.js';
import {githubWorkflowsDirectory, workflowTemplatePath} from '../paths.js';

type ActionPin = {
  readonly action: string;
  readonly line: number;
  readonly ref: string;
  readonly source: string;
  readonly tag: string;
};

// A `uses:` step, captured whole. Line-anchored, so a `statuses:` substring in
// prose is never mistaken for a step. The value is split by hand below rather
// than by a richer regex, which keeps this one linear.
const USES_PATTERN = /^\s*(?:-\s*)?uses:\s*(\S.*)$/u;

const SHA_PATTERN = /^[0-9a-f]{40}$/u;

// A `uses:` value as `<action>@<ref> # <tag>`. Returns nothing for a local
// composite action (`uses: ./.github/actions/foo`), which carries no ref to pin.
const parseUses = (
  line: string
): undefined | {action: string; ref: string; tag: string} => {
  const match = USES_PATTERN.exec(line);

  if (match === null) return undefined;

  const value = match[1];
  const hash = value.indexOf('#');
  const spec = (hash === -1 ? value : value.slice(0, hash)).trim();
  const tag = hash === -1 ? '' : value.slice(hash + 1).trim();
  const at = spec.indexOf('@');

  if (at === -1) return undefined;

  return {action: spec.slice(0, at), ref: spec.slice(at + 1), tag};
};

const extractPins = (text: string, source: string): readonly ActionPin[] =>
  text.split('\n').flatMap((line, index) => {
    const parsed = parseUses(line);

    if (parsed === undefined) return [];

    return [{...parsed, line: index + 1, source}];
  });

const collectPins = (
  dir: string,
  extension: string,
  prefix: string
): readonly ActionPin[] =>
  readdirSync(dir, {withFileTypes: true}).flatMap((entry) => {
    const full = path.join(dir, entry.name);

    if (entry.isDirectory()) {
      return collectPins(full, extension, `${prefix}${entry.name}/`);
    }

    if (!entry.name.endsWith(extension)) return [];

    return extractPins(readFileSync(full, 'utf8'), `${prefix}${entry.name}`);
  });

const describePin = (pin: ActionPin): string =>
  `${pin.source}:${pin.line} ${pin.action}@${pin.ref}`;

// The pin as it must match across files: the SHA plus its resolved-tag
// comment, so a stale comment beside a fresh SHA is drift too.
const pinIdentity = (pin: ActionPin): string => `${pin.ref} # ${pin.tag}`;

const repoRoot = resolveRepoRootFromImportMeta(import.meta.url);
const sourceTemplatesDir = path.dirname(workflowTemplatePath('wiki'));
const liveWorkflowsDir = githubWorkflowsDirectory(repoRoot);

// The source templates only. `/setup-gaia` installs from the bundled artifact
// under `.gaia/cli/templates/workflows/`, so that copy's pins are what an
// adopter actually runs, but it is held byte-identical to this source by
// `audit-template-dogfood.test.ts` (partials included). Scanning it here too
// would assert the same bytes twice and give one cause two red tests with two
// different repairs.
const templatePins = collectPins(
  sourceTemplatesDir,
  '.tmpl',
  'src/automation/templates/workflows/'
);

describe('adopter CI action pins', () => {
  test('every third-party action is pinned to a full commit SHA with its resolved tag', () => {
    const unpinned = templatePins
      .filter((pin) => !SHA_PATTERN.test(pin.ref) || pin.tag === '')
      .map(describePin);

    expect(unpinned).toEqual([]);
  });

  test.skipIf(!existsSync(liveWorkflowsDir))(
    'every template pin matches the pin the maintainer workflows run',
    () => {
      const livePins = new Map<string, Set<string>>();

      for (const pin of collectPins(liveWorkflowsDir, '.yml', '')) {
        const seen = livePins.get(pin.action) ?? new Set<string>();

        seen.add(pinIdentity(pin));
        livePins.set(pin.action, seen);
      }

      const drifted = templatePins.flatMap((pin) => {
        const live = livePins.get(pin.action);

        // An action the maintainer workflows do not run has no pin to compare
        // against; the SHA-shape test above is its only guard.
        if (live === undefined || live.has(pinIdentity(pin))) return [];

        // Insertion order, i.e. the order the workflows were read. This is
        // an error message, not an assertion surface.
        const expected = [...live].join(', ');

        return [`${describePin(pin)} (maintainer workflows run ${expected})`];
      });

      expect(drifted).toEqual([]);
    }
  );
});
