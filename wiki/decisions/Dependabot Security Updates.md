---
type: decision
status: superseded
priority: 2
date: 2026-09-29
created: 2026-09-29
updated: 2026-09-29
tags: [decision, dependencies, security, ci]
---

# Decision: Opt-in Dependabot Security Updates

Superseded by [[Dependabot as a Data Source]]: Dependabot is now a data source only and GAIA no longer offers security-update pull requests.

## Decision

`/setup-gaia` offers Dependabot security updates for npm as an opt-in (Phase 3.6 of `.claude/commands/setup-gaia.md`), recorded as `dependabot_security_updates` in the committed `.gaia/project.json` (see [[Project Config]]). It is never a file every clone inherits. `/update-deps` keeps sole ownership of version updates.

## Why

Dependabot alerts are advisory only. A vulnerable transitive dependency otherwise waits for the next `/update-deps` run. A security-update pull request closes that window.

## Shape

The rendered `npm` entry disables version updates with `open-pull-requests-limit: 0` (security-update pull requests are not subject to that limit), groups security fixes with `applies-to: security-updates` into one pull request, and labels them with `dependencies` and `security` where those labels exist in the repository. The exact YAML lives in `.gaia/cli/src/setup-ci/write-dependabot-config.ts`. The merge adds the entry beside any existing ecosystems, and leaves an existing npm entry alone. On that path `/setup-gaia` does not enable the repository settings itself, because an entry without an explicit commit-message prefix can inherit a `chore(deps):` title from the repository's commit history.

## The config alone opens nothing

Alerts (`vulnerability-alerts`) and security updates (`automated-security-fixes`) are separate repository settings. `gaia setup-ci enable-dependabot-security` turns both on and verifies them. It runs only after the config is on the default branch, because Dependabot reads config from there and enabling first would open one ungrouped pull request per open alert. A failure prints the manual `gh api -X PUT` steps.

## Why the title is fix(deps), not chore(deps)

`.gaia/scripts/chore-deps-skip.sh` makes `tests.yml` skip the suite, and lets the local merge gate stamp `GAIA-Audit` without an audit, for a `chore(deps):` title on a diff confined to dependency manifests, which a Dependabot security update always is. That is safe only because `/update-deps` runs the quality gate locally first. A Dependabot pull request has no such proof, so its prefix is `fix` and a test in the CLI pins that the rendered prefix never matches the bypass.

## Accepted tradeoffs

- `cooldown` is version-updates-only, so Dependabot does not delay these pull requests, but pnpm's `minimumReleaseAge` (see [[pnpm]]) still applies to the lockfile. A fix published inside the window fails the pull request's install until it ages out or gets a hand-checked exact-version exclusion. The advisory is public, so the window is the operator's call per fix, not something a cooldown can express.
- Nothing in CI audits a pull request or posts `GAIA-Audit`. On a repository that requires `GAIA-Audit`, a Dependabot pull request therefore merges only after a local merge run through the [[PR Merge Workflow]] in Claude Code, which posts the status. A merge from the GitHub UI is blocked by the required check.
- GitHub's supported-ecosystems table lists pnpm through v10 for security updates. A project pinned to a newer pnpm may see security-update jobs fail, visible in the Dependabot tab, and `/update-deps` stays the fallback.

## Rejected alternative

Keeping security fixes behind `/update-deps`, with Dependabot only surfacing them. That leaves the transitive window open, which is the gap this closes.

## Related

[[Project Config]], [[Incremental CI Skipping]], [[GAIA Init Workflow]].
