---
type: decision
status: active
priority: 2
date: 2026-10-03
created: 2026-10-03
updated: 2026-10-04
tags: [decision, git, conventions]
---

# Decision: Naming Conventions

Commit subjects, PR titles, and branch names follow one convention, enforced by tooling at three points so a person or Claude never has to remember it. This page is where the convention is read; each file it points at owns the detail.

## Commits and PR titles

Conventional Commits 1.0.0: `type(scope)!: summary`, a lowercase imperative summary with no trailing period, and a header of at most 100 characters (aim for 72).

- **Types.** The permitted types live in `.gaia/conventional-commits.json`. `commitlint.config.mjs` reads that file, and so does the CI check.
- **Scope.** Optional, lowercase kebab, open vocabulary.
- **Breaking change.** `!` after the type or scope, plus a `BREAKING CHANGE:` footer.
- **Issue links.** `Closes #N` belongs in the PR body only. A squash merge concatenates commit bodies into the merge message, and GitHub closes issues from that message.
- **PR title.** The title becomes the squash subject on `main` with ` (#N)` appended, which is why the CI check lints that exact string. Dependabot's titles are exempt from the title lint.

## Type versus branch prefix

The type says what changed: it drives the semver bump and the CHANGELOG section. The branch prefix says which workflow produced the branch. A `/gaia-debt` fix therefore commits as `fix:` or `refactor:` on a `debt/` branch.

Plan branches are the one exception, because a plan is written in full before its branch exists and its change type is known: they carry the type as the prefix and the plan identity in the unit (`<type>/plan-<nnn>[-<slug>]`, `<type>/spec-<nnn>[-<slug>]`). The CI check requires that type to equal the PR title's type.

`legacyTypes` in `.gaia/conventional-commits.json` names types the GAIA CLI still reads in history and commitlint rejects for new commits.

## Branches

`<prefix>/<unit>[-<slug>]`, lowercase kebab, at most 64 bytes. The workflow prefixes and the hand-named `<type>/[<issue>-]<slug>` shape are owned by the header of `.gaia/scripts/branch-name-lib.sh`, which also lists the legacy spellings it still reads: existing branches keep working, nothing mints them, and none is renamed. `/gaia-spec` creates no branch.

## Worktree branches

The harness names a worktree branch `worktree-<name>` with each `/` in the name written as `+`. GAIA renames it to the canonical name right after creating the worktree, so the local branch, the remote branch, and the PR head match, and deletes the renamed branch after removing the worktree post-merge. The commands and the reason are in `.claude/skills/gaia/references/isolation.md` under `## Worktree creation`.

## Enforcement

- `.githooks/commit-msg`: local, every commit; refuses a message that does not conform and names this page.
- `.github/workflows/pr-conventions.yml` (`PR Conventions`): lints the PR title and validates the head branch, with a canary that proves the commitlint config is live so an inert config cannot pass the check. The job is advisory.
- `.gaia/scripts/branch-name-lib.sh validate <branch>`: the branch rules, run by the workflow and callable by hand.

## Repository merge settings

The convention assumes squash merges titled from the PR title.
<!-- gaia:maintainer-only:start -->
`gaia-react/gaia` is configured squash-only, with the squash title taken from the PR title and the squash body from the commit messages.
<!-- gaia:maintainer-only:end -->

See [[Git Workflow]], [[PR Merge Workflow]], [[Pre-commit Hooks]], and [[Workflow Naming Convention]] for the workflow and job naming the `PR Conventions` workflow follows.
