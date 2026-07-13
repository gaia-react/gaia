---
paths:
  - '.gaia/**'
---

# `.gaia/` is GAIA's own machinery

<!-- gaia:maintainer-only:start -->
**If this repo is GAIA itself** — the template source, where `.gaia/cli/src/` exists — the boundary below doesn't constrain you; `.gaia/` is the product, so build in it freely. The manifest prohibition still applies to everyone. (Adopters never see this note: bundle-time scrub strips marker-delimited blocks. See [[Bundle-time Scrub]].)
<!-- gaia:maintainer-only:end -->

`.gaia/` is GAIA's harness: the CLI, scripts, statusline, release config, templates, tests, and the release-generated `manifest.json`. It ships with GAIA and updates through `/update-gaia` — framework infrastructure, not part of the app built on top of it.

When you spec, plan, or build a feature, don't infer the app's domain, architecture, or conventions from `.gaia/` contents, and don't add app files, build output, or custom working state into it. Anything the app needs that isn't a GAIA feature lives outside `.gaia/`, in a project-owned folder.

Exception: `.gaia/local/` holds your specs, plans, handoffs, and other GAIA working state; those artifacts are about your app and are authoritative for the work at hand.

## Never register app files in the manifest

`.gaia/manifest.json` is release-generated and lists only files GAIA ships. Feature work never adds to it; a path absent from the manifest is adopter-owned and invisible to `/update-gaia`, and its absence is not drift. A polluted manifest misleads the tools that read it — the `/gaia-fitness` drift check flags an adopter's own files as drift, and forensics capture ingests wrong data. The only legitimate writers are the release CLI, `/update-gaia`, `/remove-i18n`, and the `/gaia-fitness` `manifest` Fixer (the Bash writers use the `GAIA_MANIFEST_WRITE=` guard marker). See `wiki/concepts/Update Workflow.md`.

<!-- gaia:maintainer-only:start -->
GAIA maintainers: `/distribution-audit` is a fifth legitimate writer. It drives the release CLI's manifest regeneration after every newly-shipping file has an explicit ship-or-withhold answer, so the write is the CLI's, not the command's. It never hand-edits the manifest or the distribution boundary.
<!-- gaia:maintainer-only:end -->
