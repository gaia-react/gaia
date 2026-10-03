---
type: decision
status: active
priority: 2
date: 2026-09-30
created: 2026-09-30
updated: 2026-10-03
tags: [decision, ci, github-actions]
---

# Decision: Workflow Naming Convention

Every in-tree workflow's file name, workflow `name:`, and job names follow one convention, so a check-run list and an Actions-tab filter both read the same way.

## The rules

1. A workflow file is kebab-case and named for what it checks or does (`*-tests.yml`, `*-drift.yml`, `*-audit.yml`, `*-scan.yml`).
2. The workflow `name:` is the Title Case of the file stem, acronyms upper. Example: `pr-conventions.yml` writes `name: PR Conventions`.
3. A job key is the kebab-case of the job's subject, not the literal kebab of its `name:` (a `name:` carries scope and an advisory tag the key does not).
4. A job `name:` says what executed, sentence case, shape `Tool (scope)`. It is the check-run context, so renaming it renames the context.
5. A non-blocking pull-request job's `name:` ends in ` (advisory)`; a blocking job carries no tag. A job that never reports on a pull request (tag push, `issues`, `schedule`) is outside this rule: nothing can wait on it, so it takes no tag.

## How rule 5 is decided

Blocking means the job's `name:` is a required status check in the `main` branch ruleset. A job that only feeds a required aggregator (a matrix job whose aggregator reports the required context) is not tagged. A job outside rule 5's domain (tag push, `issues`, `schedule`) takes no tag either, for a different reason: nothing can wait on it.

Making a job required renames its context (the ` (advisory)` tag comes off), so the ruleset and the job `name:` change together.

<!-- gaia:maintainer-only:start -->
## Maintainer-only workflows

6. A maintainer-only workflow (release-excluded, never installed on an adopter clone) prefixes its `name:` with `GAIA: `, after rule 2's Title Case. Example: `cli-advisory-scan.yml` writes `name: 'GAIA: CLI Advisory Scan'`.

### Why `GAIA: `

The maintainer-only workflows exist because this repository is the GAIA project itself (its release, its CLI test suite, its bats shards, its forensics triage, its shell lint, its advisory dependency scan); an adopter clone never has them. The workflows that ship carry no prefix because they exist for any project this template produces.

### Quoting

`GAIA: X` contains `": "`, so an unquoted plain scalar is a YAML error in a workflow `name:` and parses as a one-key mapping inside a list. Every prefixed value is single-quoted (`name: 'GAIA: CLI Tests'`).

### Exceptions

- `audit-ci-tests.yml` keeps a file name that does not fit rule 1: renaming it has a reference blast radius that outweighs the naming gain.

### Required contexts in this repository

The `main` ruleset's required contexts are mirrored by `REQUIRED_CONTEXTS` in `.gaia/scripts/verify-required-checks.sh`. A required job's `name:` is a live branch-ruleset cutover: ask-first, maintainer-run.

### Enforcement

`.gaia/cli/src/release/workflow-prefix.test.ts` asserts that the set of workflows whose `name:` starts `GAIA: ` equals the release-exclude derive in `.gaia/cli/src/release/scrub.ts`. Rules 3 through 5 are convention with no automated check: the `code-audit-github-workflows` auditor's holistic dangling-reference lens catches a pointer left stale by a rename, not a case, shape, or advisory-tag mismatch.
<!-- gaia:maintainer-only:end -->
