---
description: 'GAIA-wrapped /speckit-specify: writes through core, then relocates the artifact to .gaia/local/specs/SPEC-NNN/SPEC.md and stamps GAIA frontmatter.'
---

# /speckit-specify (GAIA preset)

This is the body that replaces the core speckit.specify command body when the GAIA preset is installed. The core specify body is inlined below at preset install time via the `wrap` strategy.

## Step 0: GAIA pre-checks

The `before_specify` extension hook (registered by the GAIA extension) fires before this body runs. It enforces:

- Constitution placeholders are populated (`/speckit-constitution` first if not).
- spec-kit version pin matches `requires.speckit_version` from `.specify/extensions/gaia/extension.yml`.

If the hook blocks, the agent halts here and surfaces the block message. Do not proceed past Step 1 in that case.

## Step 1: core /speckit-specify

{CORE_TEMPLATE}

## Step 2: relocate to .gaia/local/specs/SPEC-NNN/SPEC.md

After core has written its artifact (typically at `specs/<NNN>-<slug>/spec.md`):

1. Resolve the just-written core artifact path. Prefer `.specify/feature.json` (`feature_dir`) or, lacking that, the most recently modified `specs/*/spec.md`.
2. Allocate the next GAIA SPEC id, passing the feature description as the subject so it becomes the `spec/NNN` reservation-tag annotation:

   ```bash
   bash .specify/extensions/gaia/lib/spec-allocator.sh next "$PWD" "$ARGUMENTS"
   ```

   Capture the printed `SPEC-NNN` token. The third argument (`$ARGUMENTS`, the feature description the user typed) is stored verbatim as the immutable one-line annotation on the reserved `spec/NNN` git tag. If `$ARGUMENTS` is empty (a fully-interactive spec run), derive the subject from the just-written artifact's first `# ` title heading and pass that instead; do not leave the argument unset.

3. Create the SPEC folder (`mkdir -p .gaia/local/specs/<SPEC-NNN>`). Copy the core artifact to `.gaia/local/specs/<SPEC-NNN>/SPEC.md`.
4. Stamp GAIA frontmatter at the top of the relocated file. If the core artifact has no frontmatter (spec-kit's bundled `spec-template.md` does not), prepend a frontmatter block with these required fields:

   ```yaml
   ---
   spec_id: <SPEC-NNN>
   type: feature
   status: in-progress
   immutable: true
   wiki_promote_default: yes
   chain_trigger: gaia-plan
   created: <today, ISO date>
   updated: <today, ISO date>
   ---
   ```

   The remaining required fields (`intent`, `success_criteria`, `uats`, `scope_boundaries`, `clarifications`, `research_summary`) are populated by the GAIA Socratic loop in `/gaia-spec`. When this preset runs under bare `/speckit-specify` (no Socratic loop), those fields stay as the salvaged template instructed and the `after_specify` lint will surface them as missing, which is the intended signal for the user to run `/gaia-spec` instead.

5. Leave the core artifact at its original path; do not delete it. Spec-kit's downstream commands (`/speckit-plan`, etc.) read from there. The relocated GAIA copy is the canonical SPEC-NNN artifact for the GAIA workflow.

## Step 3: return

Surface a single confirmation line naming both paths:

> SPEC-NNN written. Core: `<core-path>`; GAIA: `.gaia/local/specs/<SPEC-NNN>/SPEC.md`.

The `after_specify` extension hook fires next and lints the GAIA copy.

## Notes

- This wrap is intentionally surgical: it lets core do its work, then layers GAIA shape on top. If the core's output path resolution changes upstream, only Step 2's path resolution needs to follow.
- The wrap is the single source of truth for "every spec-shaped artifact in a GAIA project gets GAIA shape". `/gaia-spec` invokes `/speckit-specify` under the hood, so it inherits this same wrap automatically.
