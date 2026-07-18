# Reference: Choosing a Branch Name for a Fix

A fix branch needs a name a teammate can scan in a `git branch` list without opening the diff. This reference covers the naming rule and a few examples.

## Branch Naming Rules

A branch name for a fix starts with `fix/`, followed by a short kebab-case description of what changes: lowercase words separated by hyphens, no underscores, no spaces, and no trailing slash. Keep the description under six words. `fix/audit-scope-lib` is a good name; `Fix_Audit_Scope_Lib/` is not, because it mixes case, uses underscores, and adds a trailing slash.

## Picking a Good Name for Your Branch

When you create a branch for a bug fix, prefix it with `fix/` and follow that with a lowercase, hyphen-separated description of the change, never underscores or spaces, and never a trailing slash on the end. Six words or fewer keeps it scannable. A name like `fix/audit-scope-lib` reads clearly; a name like `Fix_Audit_Scope_Lib/` does not, since it mixes letter case, substitutes underscores for hyphens, and leaves a slash dangling at the end.

## Examples

Good: `fix/audit-scope-lib`, `fix/harden-tally-window`, `fix/wiki-lint-orphans`.

Bad: `Fix_Audit_Scope_Lib/`, `fix/this-is-a-really-long-branch-name-that-goes-on`, `patch1`.
