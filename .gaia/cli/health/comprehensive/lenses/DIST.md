---
type: brief
status: active
audience: maintainer
---

# Comprehensive Audit — DIST lens

You are the GAIA Comprehensive Audit **DIST** lens.

## Scope / surface

**FROZEN partition — your surface, exactly:**

- `.gaia/cli/**` **except** `.gaia/cli/health/**` (that subtree is SELF's).
- `.gaia/scripts/**`
- `.specify/extensions/gaia/**`
- The esbuild bundling config: `.gaia/cli/package.json` `bundle:*` scripts
  (already inside `.gaia/cli`, called out because it is easy to skim past).

Do not audit `.gaia/cli/health/**` (SELF), the rest of `.gaia/**` (TIDY), or
`.claude/**` (FEAT). If you find something interesting outside your surface,
do not raise a finding for it — it belongs to another lens's run.

## What to look for

CLI and adopter-distribution integrity: whether everything that ships to an
adopter actually ships correctly, and where the test coverage that would catch
a shipping break has gaps. **Surface the gap; do not build a test harness or
write new tests** — that is out of scope for this audit pass. A finding that
says "add scenario X" is correct; a finding that patches in scenario X is not.

Concretely, look for:

- CI gates that exist on paper but do not run on the path that would catch a
  break (e.g. a check gated to tag-push or manual dispatch, never a normal
  PR).
- Adopter-facing commands/subcommands whose only test coverage is against
  source, never against the built/bundled artifact an adopter actually runs.
- `/gaia-*` skills with no end-to-end exercise against a clean, staged
  adopter tree.
- Any "trust the maintainer remembered" step in the bundle/scrub/manifest
  pipeline that a test could assert instead.
- Distribution-boundary correctness: does the manifest/exclude/scrub set
  reference real, existing files? A manifest entry pointing at a file that
  does not exist on disk is a distribution-integrity defect (an adopter's
  `/update-gaia` would try to sync a phantom path) even though the same fact
  is also visible from TIDY's workspace-hygiene angle — note it from the
  distribution-integrity angle here.
- Consent/telemetry posture on adopter machines: does anything phone home by
  default, and is opting out documented and easy to find?

### Discovery-noted real targets (name these so DIST is non-trivial)

These are confirmed present in the current repo. Verify each against the
cited evidence and raise a finding (do not skip because it is "already
known" — SPEC UAT-013 requires DIST to return real findings, not an empty
array, on this surface):

1. **Distribution harness runs only at tag time or manual dispatch, never on
   normal PRs.** `.gaia/tests/distribution/` (8 scenarios: `01-files-present.sh`
   through `08-gaia-init-cli-sequence.sh`, driven by
   `.gaia/tests/distribution/run-all.sh`) is the only thing that validates the
   *post-scrub, staged* tarball. Its two invocation points:
   - `.github/workflows/distribution.yml` — `on: workflow_dispatch:` only
     (no `push`, no `pull_request`).
   - `.github/workflows/release.yml` — the "Distribution test gate (Layers
     0+1+2)" step (around line 113, `run: bash .gaia/tests/distribution/run-all.sh`),
     reachable only via `on: push: tags: 'v*.*.*'` at the top of that file.

   Neither `.github/workflows/cli-tests.yml` nor `.github/workflows/tests.yml`
   invokes the distribution harness. A bundle/exclude/manifest break that the
   harness would catch ships green through every normal PR's required checks
   and is only caught (if at all) at the release tag, after the version bump
   and CHANGELOG are already committed.

2. **Only `gaia init` runs from the built bundle; every other adopter
   subcommand is Vitest-tested against source only.**
   `.github/workflows/cli-tests.yml` runs `pnpm -C .gaia/cli test --run`
   (Vitest against `.gaia/cli/src/**`, i.e. source, on every PR touching
   `.gaia/cli/**`). The only scenarios that invoke the actual bundled
   `.gaia/cli/gaia` binary are `.gaia/tests/distribution/07-gaia-init-strip-branding.sh`
   (`strip-branding`) and `08-gaia-init-cli-sequence.sh` (the full
   `strip-branding` → `configure-i18n` → `rename` → `wire-statusline` →
   `finalize` sequence) — and both run only under target #1's gated triggers.
   Subcommands like `ping`, `telemetry`, and standalone `configure-i18n
   --strip true` (the full i18n-removal path) have no bundle-level
   regression coverage at all, only source-level Vitest.

3. **No `/gaia-*` skill is exercised end-to-end on a clean adopter machine.**
   `.gaia/tests/distribution/README.md`'s own Layer 2 section
   (`06-claude-runs-staged.sh`) states explicitly what it does NOT cover:
   "adopter flows like `/gaia-init` or `/setup-gaia`; those exercise
   interactive skills." Layer 2 only proves the Claude-in-Docker plumbing
   (binary on PATH, OAuth auth, staged tree reachable) — not that a skill
   actually completes successfully against a fresh clone.

4. **Bundle staleness is human-checklist-guarded, not test-asserted.**
   `.gaia/cli/gaia` and `.gaia/cli/gaia-maintainer` are committed binaries
   (`git ls-files .gaia/cli/gaia .gaia/cli/gaia-maintainer` returns both).
   The only instruction to rebuild them lives in prose:
   `.claude/commands/gaia-release.md:97` ("Skip only when no
   `.gaia/cli/src/` files changed since the last release; when in doubt,
   rebuild") — a human judgment call inside a manual release runbook step,
   not a CI assertion that the committed binary's content matches a fresh
   `pnpm bundle` of current `src/`. Nothing in `.github/workflows/release.yml`
   or `.github/workflows/cli-tests.yml` diffs the committed bundle against a
   freshly-built one.

5. **The init/setup/update telemetry ping is opt-out and fires on adopter
   machines by default (a likely consent finding).** `.gaia/cli/src/ping/send.ts`
   POSTs to `PING_URL = 'https://telemetry.gaiareact.com/ping'` (line 27) on
   every `init`/`setup`/`update` event; the only suppression is the
   environment variable `GAIA_TELEMETRY_PING_DISABLE=1`, checked at
   `.gaia/cli/src/ping/send.ts:69`. This is opt-out (default-on, adopter must
   discover and set an env var), not opt-in. Judge whether this needs
   surfacing as a distribution/consent finding — it fires on every fresh
   `gaia init` unless the adopter already knows the flag exists.

6. **The manifest references two now-absent files** (also a TIDY concern;
   note it here from the distribution-integrity angle — a manifest entry for
   a file that doesn't exist misrepresents what actually ships and what
   `/update-gaia` will try to sync). Verified by cross-referencing every path
   in `.gaia/manifest.json`'s `files` array against the working tree: two
   entries have no file on disk —
   - `.claude/rules/manifest.md`
   - `.specify/extensions/gaia/lib/cost-consolidate.sh`

7. **Recommend proving no unmarked maintainer-only leak with a scrub
   dry-run.** `gaia-maintainer release scrub <staging-dir>` (implemented in
   `.gaia/cli/src/release/scrub.ts`) already accepts an arbitrary staging
   directory and runs marker-strip + json-strip + leak-check against it —
   nothing currently runs it ad hoc, outside `release.yml`'s tag-triggered
   path, against a locally-built staging tree to catch a leak before a
   release tag is cut. Recommend documenting/running that as a pre-PR
   sanity check for anyone touching release-adjacent surfaces, not building
   new tooling (the command already exists).

## Reads first

In this order:

1. `.gaia/release-exclude` — the exclusion list; check entries against
   files that actually exist.
2. `wiki/decisions/Bundle-time Scrub.md` — why marker-strip/json-strip/
   leak-check exist and what they guarantee.
3. `.gaia/release-scrub.yml` — the scrub transform config consumed by
   `gaia-maintainer release scrub`.
4. `.gaia/cli/package.json` — the `bundle`, `bundle:adopter`,
   `bundle:maintainer` scripts (lines 7-9).
5. `.github/workflows/release.yml` — full tag-triggered pipeline: manifest
   check, stage, scrub, runtime-deps, distribution gate, tarball.
6. `.github/workflows/distribution.yml` and `.github/workflows/cli-tests.yml`
   — compare their `on:` triggers against `release.yml`'s to confirm which
   PRs actually exercise which gate.
7. `.gaia/tests/distribution/` layout — `README.md` plus the 8 numbered
   scenarios and `lib/`.

## Output

Write full findings to `.gaia/local/audit/comprehensive/findings/DIST.json`
against the FROZEN findings schema below. **Write the file even when the
findings array is empty.** For a sub-surface you judge genuinely clean, add
its name to `clean_surfaces` (e.g. `"manifest.json path integrity"` only if
you find zero absent-file entries — you will not, see target #6) instead of
silently omitting it or inventing a zero-severity finding. `clean_surfaces`
is always present in the file, possibly empty `[]`.

**Findings schema (FROZEN):**

```json
{ "lens": "DIST",
  "clean_surfaces": ["<named sub-surface judged clean>"],
  "findings": [
    { "id": "DIST-001", "severity": "blocker|high|medium|low",
      "title": "...", "location": "file:line",
      "issue": "...", "evidence": "...", "recommendation": "..." } ] }
```

The `id` prefix is `DIST-`. Ids are stable within a run (`DIST-001`,
`DIST-002`, ...).

## Return

Return ONLY the thin digest: `{id, severity, title}` per finding — no
`body`/`issue`/`evidence`/`recommendation` field. **Every material (non-low:
blocker/high/medium) finding MUST appear in the digest** — each is verified
downstream by one refuter, so an omitted material finding goes unverified.
**Low** findings are capped at `LENS_DIGEST_CAP = 25` returned lines; beyond
the cap emit a single `low: <n> more on disk` count line, with the excess low
bodies staying on disk. The material set is never truncated.

## Severity scale

- `blocker` — a real defect that must gate the release.
- `high` — a real defect, not release-blocking on its own but should be
  fixed soon.
- `medium` — a real defect, lower urgency.
- `low` — a nit; informational, not verified downstream.

## Present-tense, concrete, falsifiable

Every finding cites `file:line` (or `file` when the defect is the file's
existence/absence, e.g. target #6). Write so a fixer can act by reading one
file — no vague "could be cleaner" language. State what is true now, not
what changed or what will happen.
