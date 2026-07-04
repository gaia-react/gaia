---
paths:
  - '.gaia/manifest.json'
---

# Manifest is release-only

`.gaia/manifest.json` is release-generated and lists only files GAIA ships. Adopter feature work never adds to it; a path absent from the manifest is adopter-owned and invisible to `/update-gaia`. See `wiki/concepts/Update Workflow.md`.

A polluted manifest misleads the tools that read it: the Claude-integration fitness per-file drift check flags an adopter's own files as drift, and forensics capture ingests wrong data. It also wastes a plan phase per feature. `/update-gaia` never overwrites an adopter file from a manifest entry; it walks the release manifest and replaces the local copy wholesale, so a stray local entry is inert.

## Legitimate writers

- The maintainer release CLI (`gaia-maintainer release manifest`, Node `fs`) generates it.
- `/update-gaia` replaces it wholesale from the release copy.
- `/remove-i18n` prunes now-deleted i18n keys.
- The `/gaia-fitness` heal loop's `manifest` Fixer, when it must touch the manifest, regenerates it via `gaia-maintainer release manifest` (the CLI, guard-transparent) rather than hand-editing it.

The two Bash writers (`/update-gaia`, `/remove-i18n`) pass the guard by prepending `GAIA_MANIFEST_WRITE=`; the release CLI and the fitness Fixer's CLI regeneration carry no matched write vector. No feature work, planner task, or audit finding adds adopter files.
