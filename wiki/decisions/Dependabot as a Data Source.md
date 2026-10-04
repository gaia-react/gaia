---
type: decision
status: active
priority: 2
date: 2026-10-04
created: 2026-10-04
updated: 2026-10-04
tags: [decision, dependencies, security, ci]
---

# Decision: Dependabot as a Data Source

## Decision

Dependabot alerts are the data source for security work, and `/update-deps` resolves the advisories they report. GAIA renders no Dependabot config and enables no repository setting that makes Dependabot open pull requests: alerts stay on, automated security fixes stay off. `/update-deps` resolves each advisory through the local quality gate, and accepting an advisory instead of fixing it is a visible alert dismissal on the repository, not a private suppression. `/setup-gaia` sets the posture with `gaia setup-ci configure-dependabot-alerts` and records nothing in [[Project Config]].

## Why

An advisory needs one of three resolutions, and each needs a decision a security-update pull request cannot make:

- An in-range refresh, when the vulnerable version is locked but the parent's range already admits the patch.
- A chain-head bump with its migration, when the parent's range caps the dependency below the fix.
- A security-floor override in `pnpm-workspace.yaml`, when no parent release admits the patch.

Dependabot cannot apply the second without the migration work and the quality gate behind it, and there is no evidence it edits `pnpm-workspace.yaml` overrides, which is where the third lives. The gate is what makes a `chore(deps):` dependency change safe to merge without a full audit (see [[PR Merge Workflow]]), so a fix that skipped it is not the same change.

Two upstream Dependabot issues reversed the earlier decision to run its security updates beside `/update-deps` (see [[Dependabot Security Updates]]):

- dependabot-core #16375: an explicit `minimumReleaseAge` fails every update on pnpm 12.3 and later. GAIA sets the window (see [[pnpm]]), so its pull requests would fail their own install.
- dependabot-core #16434: transitive security updates fail on lockfiles that resolve several majors of one package.

## Shape

- `/update-deps` fetches open Dependabot alerts, validates them, ranks them, and falls back to `pnpm audit` when alerts are unreadable. Its Security section and phases are in `.claude/skills/update-deps/SKILL.md` and `.claude/skills/update-deps/references/security.md`.
- A resolution lands only when a landed check against the lockfile confirms no installed version is still in the vulnerable range.
- Acceptance is a dismissal of the alert through `gaia update-deps dismiss-alert`, after the operator confirms. When alerts are not readable, acceptance is an entry in `.gaia/local/dep-audit-baseline.json` (see [[pnpm-audit]]).
- `configure-dependabot-alerts` turns alerts on, turns automated security fixes off, and reports the change it made rather than asking first.

## The transitive window

An advisory waits for the next `/update-deps` run. The statusline security count nudges every session while any advisory is open, and a snooze never hides it, so the window is visible rather than silent. A chain-head bump an advisory needs is offered in the Security section even when its group is snoozed.

## Accepted tradeoffs

- Automated security fixes are a repository-wide setting. Turning it off also stops security pull requests for any other ecosystem a repository's own `dependabot.yml` covers, and `/setup-gaia` says so when it changes the setting.
- A repository whose organization enforces automated security fixes cannot satisfy the posture. The configurer reports the refused step and prints the manual commands.
- Nothing resolves an advisory until someone runs `/update-deps`. Dependabot finds it and GAIA fixes it through the gate, on the operator's schedule.

## Rejected alternative

Dependabot security-update pull requests beside `/update-deps`, the earlier decision. This page adopts what that one rejected: keeping security fixes behind `/update-deps`, with Dependabot only surfacing them.

## Related

[[Dependabot Security Updates]], [[pnpm-audit]], [[Project Config]], [[PR Merge Workflow]], [[pnpm]].
