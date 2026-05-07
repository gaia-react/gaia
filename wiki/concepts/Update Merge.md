---
type: concept
status: active
created: 2026-05-07
updated: 2026-05-07
tags: [concept, claude, cli, workflow]
---

# Update Merge

The `gaia update merge` command performs a three-way file comparison when pulling in updates from the GAIA template. It reconciles local project changes with upstream template changes, using a manifest-driven approach to identify which files can be auto-merged vs which need manual review.

## Workflow

When a project cloned from GAIA needs to incorporate template updates (bug fixes, new features, or refactored infrastructure):

1. **Manifest-driven inventory.** The command reads `.gaia/manifest.json` to learn which files are tracked for updates, which are project-owned (exclude from merge), and which are deprecated (should be removed).

2. **Three-way comparison.** For each tracked file:
   - Compares local version vs the template's baseline (the version the project cloned from)
   - Compares template baseline vs template HEAD (what changed upstream)
   - Applies the upstream changes if they don't conflict with local edits

3. **Conflict resolution.** Files with conflicting local + upstream changes are flagged for manual review. Non-conflicting changes merge automatically.

4. **Manifest classes.** The implementation uses strongly-typed manifest classes (`ManifestFile`, `ManifestEntry`, etc.) to ensure consistency and testability across the merge logic.

## Integration

Invoked via `/gaia update merge` (the skill), which walks the user through reviewing and confirming the merge. Can also be run manually as `gaia update merge` from the project root.

See [[Release Workflow]] for how upstream updates are published to the template.
