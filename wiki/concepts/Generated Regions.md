---
type: concept
status: active
created: 2026-07-22
updated: 2026-08-03
tags: [release, update, claude, drift]
---

# Generated Regions

A generated region is a marker-delimited span inside a shipped file whose body a shipped command regenerates deterministically, rather than a human editing it by hand. The [[Code Audit Team]] remit region inside each member's agent definition is the region this mechanism first ships to declare: the roster is the source of truth for what a member owns, and the region is a generated restatement of it inside the member's own prose, kept from drifting by a writer command rather than by discipline.

Without region awareness, the [[Update Workflow]]'s merge walk compares an owned file whole-file: any divergence anywhere in the file, including inside a span a shipped command already keeps correct, reads as adopter drift and produces a full-file conflict patch. Region awareness masks the declared span on each side of the three-way comparison first, so a divergence confined to it never becomes a conflict the adopter has to resolve by hand.

## The declaration

A region's declaration lives in two places that are deliberately not the same list. The marker pair and the regeneration command (an interpreter, an operand, and any extra arguments) are hand-authored in a maintainer-side registry, because scraping an executable command out of a file would be fragile and a needless execution surface. The path set a declaration covers is never hand-maintained: it is scanned from the shipped file set at manifest-build time, by searching for the declared marker pair inside every file the release actually ships. A hand-maintained path list is the second list that drifts from reality, which is the defect this mechanism exists to end.

The release manifest carries the result as an additive, optional `regions` array: each entry names a stable declaration id, its marker pair, the paths it was found in, and the regeneration command. A manifest predating this key parses and validates unchanged.

A shipped file carrying a region's marker pair that the declared regeneration command does not itself rewrite is a build-time failure, not a warning: declaring a region nothing regenerates is worse than not declaring it, since nothing would ever repair the drift the declaration promises to catch.

## The marker contract

A marker is a literal string matched by whole-line equality: a line matches only when the entire line equals the marker, so a marker mentioned inside a sentence, a fenced example, or a table cell that carries other text never matches. A region-bearing file carries exactly one start marker and exactly one end marker, start strictly before end; any other count, or an end marker preceding its start, is malformed.

A declared marker pair is stable across releases. A region that needs different markers is a new declaration with a new id, never an edited one, because the id is what a re-invocation's follow-up commands and skip lists key against.

## Normalized comparison

`gaia update merge-region` computes the three-way verdict over the masked sides. Two rules apply, deliberately different from each other:

- **A side with no marker pair is compared unmasked, on its own.** The other sides are still masked. A file that has not yet picked up the region (an adopter who has not run an update since the region was first declared, for instance) is not penalized for it.
- **A malformed side bails the whole comparison.** If any side's markers are missing one of the pair, duplicated, or reversed, no side is masked at all: every side compares as its raw, unmodified content, which is the same answer the walk reaches without region awareness. A partially normalized comparison would be worse than no normalization, since it would hide a real divergence behind a mask built from a malformed read.

The verdict itself, `no-upstream-change` / `no-adopter-drift` / `already-latest` / `conflict`, follows the same resolution order as the merge walk's other field-aware oracles, computed over the normalized (or, on a bail, raw) three sides.

## Regeneration

`gaia update regen-regions` is the authoritative half: once the oracle confirms a declared region's divergence is confined to its markers, this command re-runs the declaration's own shipped regeneration command against the adopter's post-merge tree, one region at a time. Every file under the region's declared paths is backed up first, unless the merge walk already backed that path up. The backup follows a symlink through to what it resolves to rather than copying the link itself, since a copy's only job is holding the bytes the spawn's write is about to destroy: a link to a regular file is copied as that file, and a declared path that resolves to a FIFO, a socket, a device node, or a directory has no such content to hold, so it is reported rather than copied and the run continues. Inside those directories, where the pre-run snapshot exists, any path the regeneration command leaves different from the declared set counts as an undeclared write: a deletion is reverted from its pre-image, and a creation, having none, is removed. Outside the region's declared directories entirely there is no snapshot to compare against, so a write there is reported rather than undone. A symlink follows the same rule by its target string rather than its content: one the command deletes, retargets, or replaces with a regular file is restored to its original target, and one it creates is removed; restoring a link writes no content and follows nothing, so whatever it points at is never touched. Four limits keep that guarantee honest. The snapshot never traverses a link, inside the region's directories or above them, so a path reachable only through a symlinked directory is not in scope at all: what lives there is outside the adopter's tree whatever its path reads like, and the runner reverts nothing there rather than resolving a lexical key through the link and writing outside the repository. That is the cost of reading and writing the same way, and it extends to a region directory that is itself a link or sits behind one: nothing inside it is reverted, and git sees nothing there either, since git tracks a symlink as a link and never descends into it. The directory itself is still reported, which is what stops a later pass from reading a scope it never examined as an empty one and deleting whatever has since arrived there. Second, a path is treated as something the command created only when the snapshot actually looked inside every directory above it. The snapshot records every node it does not look inside and none that it does: a link, a regular file, a FIFO or socket or device node, anything unreadable, down to a region directory whose own parent has lost its search bit. Anything that turns up beneath one of those is reported rather than deleted. What that buys is the case where content the adopter already had *arrives* at such a path between the two passes, which a command that replaces a link or a file with a moved directory does: absent from the before picture and present in the after, it would otherwise read as a fresh creation and be deleted, and a move leaves no second copy. Third, a pre-image the command replaced with a directory is reported rather than restored, since putting the file back would mean deleting a directory tree the adopter may care about, a wider reach than this guarantee claims. Fourth, a directory the command creates in scope is left behind, empty and unreported: what the command put inside it is recorded and removed, which is where the content is, but the directory itself is the one node the snapshot never records, and unlinking one on the strength of its emptiness at a single instant reaches further than this guarantee claims.

A region named by the merge walk's skip or conflict lists, or whose declaration itself is malformed, is refused or skipped rather than regenerated. A manifest whose `regions` key is present but not an array is refused by name at this same step; a manifest that is not an object at all never reaches this step, since the loader that reads it finds no `regions` key to be wrong-typed and falls back to zero declarations. A regeneration command that exits non-zero, one that never launches, and one that runs but is killed by this runner's own time or output ceiling are reported as three distinct outcomes, since each has a different remedy. Neither a refusal nor a regeneration failure ever fails the update. The regeneration command always runs as a fixed argv, interpreter plus operand plus arguments, never through a shell-interpreted string.

## The one-release lag

The merge walk's own logic lives in the adopter's already-installed `/update-gaia` skill, not in the newly downloaded release. A release that changes the merge walk, including the release that first ships region awareness, writes its updated skill file to the adopter's tree as part of that run, but the run already in progress still executes under the skill version that was loaded when it started. The new logic first actually runs on the adopter's next `/update-gaia` invocation, one release after the declaration ships. A release that introduces a new declared region pairs it with an action-required CHANGELOG entry naming this.

## The off switch

Setting `GAIA_UPDATE_NO_REGIONS=1` in the environment for one run makes the merge walk load zero declarations: every declared path takes the unmodified whole-file comparison, no oracle call and no regeneration run, and the run's summary states region awareness was off. This is the adopter-facing remedy for a bad declaration or an oracle defect in the field: it needs no edit to the release-owned manifest and no flag on any command.

## Trust model

The update flow already extracts and executes the release tarball's bundled CLI to run the rest of the merge walk; region awareness adds no new execution surface, only two more subcommands on that same bundled binary. The tarball is transport-authenticated only, so the well-formedness checks the regeneration runner applies to a declaration's operand (a shipped path, no parent-directory segment, no symlink escape) are a guard against a stale or hand-edited declaration, not a control against an adversary who already controls the manifest; that trust boundary is unchanged by this feature.

## Pairs with

- [[Update Workflow]]: the merge walk this mechanism plugs into, and the decision table a region-aware path takes instead of the whole-file rows.
- [[Code Audit Team]]: the roster mechanism whose remit region is the first shipped generated region.
