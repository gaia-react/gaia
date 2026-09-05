---
paths:
  - '.github/workflows/**'
  - '.gaia/cli/src/automation/templates/workflows/**'
  - '.gaia/cli/templates/workflows/**'
---

# GitHub Workflow Distribution (maintainer-only)

**Maintainer-repo only.** This rule never ships (`.claude/rules/maintainers/` is release-excluded). It governs how a fix to a GitHub Actions workflow in this repo relates to the workflow templates bundled to adopters, so a fix doesn't land in one place and silently drift from the other.

## The one workflow that must be mirrored

`code-review-audit.yml` exists as **three byte-identical copies**. A change to one that isn't mirrored to the others breaks the release.

| Copy | Role |
|---|---|
| `.github/workflows/code-review-audit.yml` | Live workflow (this repo). Release-excluded — the live file does not ship; adopters render the template instead. |
| `.gaia/cli/src/automation/templates/workflows/code-review-audit.yml.tmpl` | **Source template** — the one you edit. Ships / installs on-demand via `/setup-gaia`. |
| `.gaia/cli/templates/workflows/code-review-audit.yml.tmpl` | **Build artifact** — a copy of the source. Do **not** hand-edit; regenerate it. |

**When you change `code-review-audit.yml`:**

1. Make the identical change to the **source** template `.gaia/cli/src/automation/templates/workflows/code-review-audit.yml.tmpl` (edit source + live together, in the same commit).
2. Regenerate the build artifact: `pnpm -C .gaia/cli bundle:adopter` (its `cp -r src/automation/templates/workflows/. templates/workflows/` step rewrites `.gaia/cli/templates/workflows/`). Never hand-edit the artifact — the bundle overwrites it.
3. Verify byte-identity: `pnpm -C .gaia/cli test --run` runs `audit-template-dogfood.test.ts`, which asserts live == source. `cli-tests.yml` re-runs it on any edit under `.github/workflows/`, so a one-sided change fails CI.

**Invariant — nothing maintainer-only in this workflow.** `code-review-audit.yml` is fully portable and identical to what an adopter renders. Never add a maintainer-only path, comment, or conditional to it. The release leak-checks (`maintainer-paths`, `excluded-workflow-ref` in `.gaia/release-scrub.yml`) fail the build if a shipped workflow surface references a maintainer-only path (this class already regressed once — a comment cross-referencing `forensics-triage.yml` leaked onto adopters). If a change genuinely needs to differ for the maintainer repo, it does not belong in this workflow.

## Every other workflow — no template to mirror

- **Ships verbatim** (manifest `shared`, no template): `tests.yml`, `chromatic.yml`. Keep their comments free of maintainer-only paths and keep any path filters as allowlists, never `paths-ignore:`/inverted `!` fail-quiet shapes (leak-checks `maintainer-paths`, `workflow-denylist`).
- **Maintainer-only, release-excluded, no template** — edit freely, no *file* to mirror. `.gaia/release-exclude` is the owner of the full set.
- **One value every workflow does mirror: its action pins.** No workflow here has a template counterpart beyond `code-review-audit.yml`, but `adopter-ci-action-pins.test.ts` holds the pins in `.gaia/cli/src/automation/templates/workflows/**/*.tmpl` equal to the pins these workflows run, and requires the workflows to agree with each other. It reads the directory whole, so bumping an action SHA in **any** workflow in `.github/workflows/`, not only the ones named above, reddens it until the same `<sha> # <tag>` is mirrored into the source templates. That alone greens the pin guard; regenerating the artifact (step 2's `bundle:adopter`) is a separate obligation: `audit-template-dogfood.test.ts` holds it via `pnpm -C .gaia/cli test --run`, and `verify-cli-bundle-fresh.sh` holds it as its own workflow step (`cli-tests.yml` and `release.yml` each run it directly with `bash`). Dependabot's weekly grouped bump is the ordinary case; the pin guard's failure message names both the SHA and the site to copy it into.
- **Adopter-only templates, no `.github/workflows` counterpart here**: every `gaia-ci*.yml.tmpl` (the four per-tool templates plus the `gaia-ci.yml` scheduler that calls them, rendered per adopter from `.gaia/automation.json`). The maintainer runs none of them, so there is nothing to diff against — a *different* drift surface (you'd be changing the render source / automation skills, not a workflow file), tracked separately as tech-debt, not by this rule.

## Reference

- Distribution boundary rationale: `wiki/concepts/Release Workflow.md` (Distribution Boundary) and `.gaia/release-exclude`.
- The audit workflow's agent lens: `.claude/agents/code-audit-frontend.md`.
