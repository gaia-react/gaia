---
type: concept
title: Shell Testing and CI
status: active
created: 2026-10-27
updated: 2026-10-29
tags: [concept, testing, shell, ci]
---

# Shell Testing and CI

GAIA gives a project three things for the shell it writes: an audit member at the merge gate, a bats stack for tests, and a CI job that lints changed shell and runs the bats suite. This page ties them together.

## What GAIA gives an adopter for shell

- **The shell audit member.** `code-audit-shell` (`.claude/agents/code-audit-shell.md`) is a member of the [[Code Audit Team]]. It reviews the shell you author, the hooks you add or edit, and your own edits to a shell file GAIA ships. It skips a change to a file the manifest lists as owned when that change comes from applying a GAIA release, so a GAIA update never dispatches it for GAIA's own shell. It also reviews `.claude/settings.json`, the file that registers the hooks, with a settings lens that lists every hook or permission rule a change removes, weakens or re-scopes; its GAIA-release skip never drops that file, since GAIA ships it for the project to edit.
- **The bats stack.** `pnpm test:shell` runs suites under `tests/shell/` with the pinned npm `bats` package.
- **The CI job.** The `Shellcheck and bats` job in `.github/workflows/tests.yml` lints the shell a pull request changes and runs the bats suite when shell changed. It is on by default.

## Running bats

```bash
pnpm test:shell
```

With no arguments the runner runs `tests/shell/`; with arguments it passes them to bats, so a single file runs while you iterate. It refuses to run, with one line naming the bash version it found, when the first `bash` on `PATH` is older than 4. `.claude/skills/tdd/references/tests-shell.md` owns the steps for putting bash 5 first on `PATH`, plus the suite layout and fixture conventions.

## Assertions that can fail

A bare `[[ ]]` or arithmetic test inside a bats test passes silently on some bash versions even when false, so write assertions that fail loudly. `.claude/rules/bats-assertions.md` owns the pattern.

## Shellcheck and bats in CI

The shipped `.github/workflows/tests.yml` carries a `Shellcheck and bats` job (check name `Tests / Shellcheck and bats`) beside the `Vitest and Playwright` job. It runs on every pull request, with no paths filter, so it always reports, green when the pull request changes no shell, and `/setup-gaia` registers it as a required check beside `Vitest and Playwright` (the `required-ci-checks` [[Setup Features|setup feature]]).

What it does on a pull request:

- **Selects first, before any checkout.** Its first step reads the pull request's changed files and the few small files the rules below need through the GitHub API. With nothing to lint and no bats run due, the job ends there, green, in seconds.
- **Lints the changed shell.** Every `.sh` and `.bats` file the pull request adds or modifies is linted with a pinned, digest-verified shellcheck at warning severity; `.bats` files are linted as bash. A deleted file is never linted. The whole pull request's selection is linted on every push, not only the newest push's files, so a head commit never passes while an earlier push's failing file is still in the pull request. A `.shellcheckrc` in the repository applies, so your own policy (disabled codes, severity) is honored.
- **Lints everything when the policy changes.** A change to a `.shellcheckrc` or to the job's pinned shellcheck version lints every shell file in the repository.
- **Skips GAIA's own shell only on a GAIA update.** A file the manifest lists as owned is skipped only when the pull request changes `.gaia/VERSION`, which is what applying a GAIA update does. On any other pull request, your edit to a shell file GAIA ships is your code and is linted. This is the same rule the shell audit member uses.
- **Runs bats when shell changed.** When `tests/shell/` holds a `.bats` suite and the pull request changed selected shell or anything under `tests/shell/`, the job installs only the pinned `bats` from the root `package.json` and runs `pnpm test:shell` over the whole `tests/shell/` directory. It never maps a changed script to one suite, because a suite can source any script.

A manual run of the workflow lints every shell file and runs the bats suite when one exists.

### Turning shellcheck off

Set `"shellcheck": false` in `.gaia/project.json` ([[Project Config]]). The job reads it from the pull request's head, so the pull request that sets it is already unlinted. Absent or `true` means on. The bats run has no toggle: a project with no `tests/shell/*.bats` never runs it.

### Cost

A pull request that changes no shell costs one short API step. A typical shell pull request adds a checkout of only the files it lints plus the shellcheck download; a bats run adds a full checkout and the `bats` install. `tests.yml` is a shared file: if you customize it, `/update-gaia` three-way merges GAIA's changes into your copy.

<!-- gaia:maintainer-only:start -->
GAIA maintainers: in this repository the job runs beside the maintainer shell gate, `.github/workflows/shell-lint.yml` (`.gaia/tests/shell-lint.sh`: curated excludes, custom guards, a bash 3.2 parse), which it does not replace. The selector is `.gaia/scripts/shell-checks-select.sh` and the lint runner `.gaia/scripts/shell-checks-lint.sh`; `.gaia/scripts/tests/shell-checks.bats` holds both to the audit's release rule.
<!-- gaia:maintainer-only:end -->

## Keeping suites fast

- Build fixtures in `$BATS_TEST_TMPDIR`, which bats cleans up after each test.
- Keep one suite per script, so a change runs one small file.
- Avoid network calls; stub the command instead.
- Run a single file while iterating, and the whole directory before you push.
- When the suite grows slow, shard by file across CI jobs so each job runs a slice of the suite files.

## Roster interaction

The member sits in the roster after the maintainer-only block and before `unowned:`; `.gaia/audit-ci.yml` owns its globs. Claimants match first-match-wins in roster order, so a shell claimant of your own listed earlier keeps ownership of the paths it claims: `/update-gaia` appends the new member after your members.

Shell and bats files the frontend member used to review anywhere in the tree now belong to the shell member. When the new member makes an `unowned:` entry overbroad, `/update-gaia` removes that entry and reports it in the run summary. The roster mechanics are in [[Code Audit Team]].

## Pairs with

- [[Code Audit Team]]
- [[Customizing GAIA]]
- [[Registering a Code Audit Team Member]]
- [[Update Workflow]]
