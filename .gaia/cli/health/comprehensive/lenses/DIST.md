---
type: lens-brief
lens: DIST
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
- Pre-tag scrub verification: is there a documented, easy-to-run way to run
  the leak-check (marker-strip + json-strip) against a locally-built staging
  tree before a release tag is cut, or does the only run of it live behind
  the tag-triggered release path?

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
its name to `clean_surfaces` (e.g. `"manifest.json path integrity"` if you
find zero absent-file entries) instead of silently omitting it or inventing
a zero-severity finding. `clean_surfaces` is always present in the file,
possibly empty `[]`.

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
existence/absence, e.g. a manifest entry pointing at a nonexistent path).
Write so a fixer can act by reading one file — no vague "could be cleaner"
language. State what is true now, not what changed or what will happen.
