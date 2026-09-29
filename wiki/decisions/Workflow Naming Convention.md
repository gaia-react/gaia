---
type: decision
status: active
priority: 2
date: 2026-09-30
created: 2026-09-30
updated: 2026-09-30
tags: [decision, ci, github-actions]
---

# Decision: Workflow Naming Convention

Every in-tree workflow's file name, workflow `name:`, and job names follow one convention, so a check-run list, an Actions-tab filter, and a `retrigger_workflows` entry all read the same way.

## The rules

1. A workflow file is kebab-case and named for what it checks or does (`*-tests.yml`, `*-drift.yml`, `*-audit.yml`, `*-scan.yml`).
2. The workflow `name:` is the Title Case of the file stem, acronyms upper, before rule 6's prefix. Example: `cli-advisory-scan.yml` writes `name: 'GAIA: CLI Advisory Scan'`.
3. A job key is the kebab-case of the job's subject, not the literal kebab of its `name:` (a `name:` carries scope and an advisory tag the key does not).
4. A job `name:` says what executed, sentence case, shape `Tool (scope)`. It is the check-run context, so renaming it renames the context.
5. A non-blocking pull-request job's `name:` ends in ` (advisory)`; a blocking job carries no tag. A job that never reports on a pull request (tag push, `issues`, `schedule`) is outside this rule: nothing can wait on it, so it takes no tag.
6. A maintainer-only workflow (release-excluded, never installed on an adopter clone) prefixes its `name:` with `GAIA: `.

## Why `GAIA: `

The maintainer-only workflows exist because this repository is the GAIA project itself (its release, its CLI test suite, its bats shards, its forensics triage, its shell lint, its advisory dependency scan); an adopter clone never has them. `Tests` and `Chromatic` carry no prefix because they exist for any React app this template produces, and they are the only in-tree workflows that ship.

## Quoting

`GAIA: X` contains `": "`, so an unquoted plain scalar is a YAML error in a workflow `name:` and parses as a one-key mapping inside a list. Every prefixed value is single-quoted (`name: 'GAIA: CLI Tests'`), and a `retrigger_workflows` entry naming a prefixed workflow is quoted the same way.

## Exceptions

- `code-review-audit.yml` keeps `Code Review Audit`, no prefix, because adopters receive a rendered twin of the same file from `.gaia/cli/templates/workflows/code-review-audit.yml.tmpl`.
- `code-review-audit.yml` and `audit-ci-tests.yml` keep file names that do not fit rule 1: renaming either file's reference blast radius outweighs the naming gain.
- The adopter `GAIA CI - *` workflow family (installed by `/setup-gaia`) is a separate, adopter-facing namespace. Rule 6 does not govern it.

## How rule 5 is decided

Blocking means the job's `name:` is a context in the `main` branch ruleset, mirrored by `REQUIRED_CONTEXTS` in `.gaia/scripts/verify-required-checks.sh`. A job that only feeds a required aggregator (a shards matrix job whose aggregator reports the required context) is not tagged, and neither is the job that produces the required `GAIA-Audit` status. A job outside rule 5's domain (tag push, `issues`, `schedule`) takes no tag either, for a different reason: nothing can wait on it.

## Enforcement

`.gaia/cli/src/release/workflow-prefix.test.ts` asserts that the set of workflows whose `name:` starts `GAIA: ` equals the release-exclude derive in `.gaia/cli/src/release/scrub.ts`, minus `code-review-audit.yml`. Rules 3 through 5 are convention with no automated check: the `code-audit-github-workflows` auditor's holistic dangling-reference lens catches a pointer left stale by a rename, not a case, shape, or advisory-tag mismatch.

A renamed workflow `name:` lands with its `.gaia/audit-ci.yml` `retrigger_workflows` entry in the same commit. A required job's `name:` is a live branch-ruleset cutover: ask-first, maintainer-run.
