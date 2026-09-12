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
 * advances means adopters stop receiving upstream patches. The parity test
 * below (`every template pin matches the pin the maintainer workflows run`) is
 * the mechanism that keeps them moving: it asserts each template pin against
 * the pin the maintainer's own workflows run, which Dependabot bumps weekly.
 * Named rather than numbered, because an ordinal points at whichever test
 * happens to sit in that slot after the next insertion, and a maintainer
 * following it to diagnose a bump-drift red opens the wrong one. A bump lands in `.github/workflows/` first and turns this red until
 * the same pin is mirrored into the template. That is the same red-then-mirror
 * flow `dependabot.yml` already documents for `code-review-audit.yml`.
 *
 * The mirrored template reaches adopters on their next `/update-gaia`, which
 * does NOT re-render an installed workflow: `/update-gaia` refreshes
 * `code-review-audit.yml` alone, and the `gaia-ci-*` workflows this partial
 * feeds are re-rendered only by `/setup-gaia`, whose drift check offers that
 * path. So the pin reaches an adopter's running CI on their next `/setup-gaia`,
 * not before.
 *
 * Repair, when the parity test goes red: copy the `<sha> # <tag>` the failure
 * message names from the maintainer workflows into the template site it names,
 * then regenerate the render snapshots (`pnpm test --run -u` in `.gaia/cli`).
 *
 * Maintainer-only by construction: `.gaia/cli/src` is release-excluded, so this
 * test is absent on adopter clones. The parity test additionally skips when
 * `.github/workflows/` is absent, mirroring the sibling guards.
 *
 * `partials/node-setup.yml.tmpl` pins neither `pnpm/action-setup` nor
 * `actions/setup-node` directly: it calls `./.github/actions/gaia-setup-node`,
 * a local composite action with no ref to pin, so the corpus this file scans
 * no longer carries that partial's pins. Both pins still live inside the
 * composite itself, which `liveActionPins` already collects from
 * `.github/actions/`, and `code-review-audit.yml.tmpl` still pins both
 * directly, so the parity test still has a template-side pin to compare
 * against the maintainer workflows.
 */
import {describe, expect, test} from 'vitest';
import {existsSync, readFileSync} from 'node:fs';
import path from 'node:path';
import {resolveRepoRootFromImportMeta} from '../../util/repo-root-fixture.js';
import {collectTreeFiles} from '../../util/tree-walk.js';
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

  if (value === undefined) return undefined;

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

const TEMPLATE_EXTENSIONS: ReadonlySet<string> = new Set(['.tmpl']);

const YAML_EXTENSIONS: ReadonlySet<string> = new Set(['.yaml', '.yml']);

// The shared walk reports regular files only, so a symlinked workflow, action
// or template is not scanned and its pins never reach the assertions below.
// Worth stating at the call site because the miss is silent in the
// safe-looking direction: every assertion here compares against an empty
// array, so a corpus that quietly got smaller still reads as a pass.
const collectPins = (
  dir: string,
  extensions: ReadonlySet<string>,
  prefix: string
): readonly ActionPin[] =>
  collectTreeFiles(dir, extensions).flatMap((relative) =>
    extractPins(
      readFileSync(path.join(dir, relative), 'utf8'),
      `${prefix}${relative}`
    )
  );

const describePin = (pin: ActionPin): string =>
  `${pin.source}:${pin.line} ${pin.action}@${pin.ref}`;

// The pin as it must match across files: the SHA plus its resolved-tag
// comment, so a stale comment beside a fresh SHA is drift too.
const pinIdentity = (pin: ActionPin): string => `${pin.ref} # ${pin.tag}`;

const repoRoot = resolveRepoRootFromImportMeta(import.meta.url);
const sourceTemplatesDir = path.dirname(workflowTemplatePath('wiki'));
const liveWorkflowsDir = githubWorkflowsDirectory(repoRoot);
const liveActionsDir = path.join(repoRoot, '.github', 'actions');

// The source templates only. `/setup-gaia` installs from the bundled artifact
// under `.gaia/cli/templates/workflows/`, so that copy's pins are what an
// adopter actually runs, but it is held byte-identical to this source by
// `audit-template-dogfood.test.ts` (partials included). Scanning it here too
// would assert the same bytes twice and give one cause two red tests with two
// different repairs.
const templatePins = collectPins(
  sourceTemplatesDir,
  TEMPLATE_EXTENSIONS,
  'src/automation/templates/workflows/'
);

// GitHub honors both spellings, so scanning `.yml` alone would let a `.yaml`
// workflow be the sole live site pinning an action and leave the template pin
// compared against nothing.
//
// `.github/actions/` is scanned alongside `.github/workflows/` because a
// composite action pins third-party actions of its own, and most of this
// repository's setup steps run through one. A pin that lives only there would
// otherwise sit outside every comparison below: the agreement test would not
// see it drift from the workflows, and a template pinning the same action
// would be compared against a live set that does not contain it.
// Collected separately so the walk into `.github/actions/` is expressed
// once; the SHA-shape test below asserts over the whole live set, workflows
// included. A composite action pinned to a moving major tag and used by no
// workflow would otherwise pass every test here: it agrees with itself, and no
// template pins it, so neither comparison reaches it.
const liveActionPins =
  existsSync(liveActionsDir) ?
    collectPins(liveActionsDir, YAML_EXTENSIONS, '../actions/')
  : [];

const liveWorkflowPins = [
  ...(existsSync(liveWorkflowsDir) ?
    collectPins(liveWorkflowsDir, YAML_EXTENSIONS, '')
  : []),
  ...liveActionPins,
];

const livePins = new Map<string, Set<string>>();

for (const pin of liveWorkflowPins) {
  const seen = livePins.get(pin.action) ?? new Set<string>();

  seen.add(pinIdentity(pin));
  livePins.set(pin.action, seen);
}

describe('adopter CI action pins', () => {
  // `liveWorkflowPins` rather than `liveActionPins`, so this reaches the
  // workflows too. The other two tests below are both comparisons, and a pin
  // with no counterpart escapes each of them: the agreement test only compares
  // an action against other sites pinning the same action, and the parity test
  // only reaches actions a template pins. So a workflow that is the SOLE live
  // user of an action could pin it to a moving tag, or drop its resolved-tag
  // comment, and pass every assertion here. That is a live shape rather than a
  // hypothetical one, since a new workflow bringing its own action arrives that
  // way; the checkout pin is covered today only by the accident of fifteen
  // workflows sharing it.
  test('every third-party action is pinned to a full commit SHA with its resolved tag', () => {
    const unpinned = [...templatePins, ...liveWorkflowPins]
      .filter((pin) => !SHA_PATTERN.test(pin.ref) || pin.tag === '')
      .map(describePin);

    expect(unpinned).toEqual([]);
  });

  // Without this, the parity test below is satisfiable by a straggler. It
  // accepts any pin the live set holds, so one workflow left on an older SHA
  // would keep a template that also lags green, and the bump-lands-here-first
  // mechanism would never fire.
  test.skipIf(!existsSync(liveWorkflowsDir))(
    'the maintainer workflows agree with each other on every action pin',
    () => {
      const disagreed = [...livePins.entries()]
        .filter(([, identities]) => identities.size > 1)
        .map(
          ([action, identities]) => `${action}: ${[...identities].join(', ')}`
        );

      expect(disagreed).toEqual([]);
    }
  );

  test.skipIf(!existsSync(liveWorkflowsDir))(
    'every template pin matches the pin the maintainer workflows run',
    () => {
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
