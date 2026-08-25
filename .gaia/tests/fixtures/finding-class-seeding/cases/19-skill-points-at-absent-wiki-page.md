# 19-skill-points-at-absent-wiki-page

**Path**: `.claude/skills/gaia-wiki/SKILL.md`
**Line**: 88

## Title

The route-group step sends the reader to a wiki page the repository does not contain.

## Failure mode

This step says to consult `wiki/concepts/Route Groups.md` before classifying a moved
route, and no file by that name exists anywhere in `wiki/`. A reader following the step
opens nothing, and cannot tell whether the page was never written, sits under a
different title, or was folded into another page, so the step cannot be completed as
written and offers no way to recover the guidance it defers to.

## Verified by

Ran `git ls-files wiki/` and searched the tree for the cited filename and for its title
as a heading; neither returns a match, so the step's target is absent from the tree
rather than merely renamed within it.

## Suggested fix

Either author the page the step defers to, or state the classification rule inline here
and drop the pointer, so the step stands on its own.
