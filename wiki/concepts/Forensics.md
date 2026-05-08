---
type: concept
status: active
created: 2026-05-08
updated: 2026-05-08
tags: [concept, gaia, workflow, support]
---

# Forensics

`/gaia forensics [description]` is a read-only GAIA skill that turns a workflow misfire into a redacted, classified, filing-ready bug report in one invocation. Any GAIA user can invoke it immediately after a failure — no prior knowledge of the internals is needed. The skill body lives at `.claude/skills/gaia/references/forensics.md` (dispatched by the `/gaia` router skill).

## What it captures

Every report begins with a universal envelope regardless of which workflow failed:

- `gaia_version` — from `.gaia/manifest.json` (or `.gaia/VERSION` as fallback)
- `node`, `pnpm`, `claude_code` — local tool versions
- `branch` — current git branch
- `dirty` — whether the working tree has uncommitted changes

After classifying the failure, the skill supplements this envelope with class-specific state files from the following closed taxonomy:

| class | triggered by |
|---|---|
| `init` | `/gaia-init` scaffolding failures |
| `update` | `/update-gaia` merge conflicts |
| `wiki-sync` | `/gaia wiki sync` misfires |
| `quality-gate` | `pnpm typecheck` or lint failures inside a GAIA flow — see [[Quality Gate]] |
| `hook` | `.claude/hooks/*.sh` misfires |
| `scaffold` | `new-component`, `new-route`, `new-hook`, or `new-service` skill failures |
| `dev-server` | `pnpm dev` / Vite / SSR boot failures |
| `other` | unknown or multi-class failures; always treated as a probable bug |

State-file capture is conservative: the skill records filenames and one-line summaries, never full file bodies. File bodies from `app/`, `wiki/`, and `studio/` are never captured regardless of class.

The classifier also determines whether the failure is a **user-config issue** (wrong Node version, missing required env var, dirty working tree blocking a workflow) or a **probable bug** (any other pattern, including the `other` class). This diagnosis gates what happens next: user-config failures receive inline remediation steps and no GitHub issue offer; probable-bug failures trigger the issue filing offer. Both branches always save the local report first.

## What it redacts

Before writing or filing anything, the skill runs a single redaction pass over the assembled report body. Absolute paths that fall under the project root are rewritten to their repo-relative forms; absolute paths outside the root collapse to the filename only so machine identity does not leak. Token-shaped values matching common credential patterns (GitHub, Anthropic, OpenAI, GitLab, Slack, AWS, and a generic high-entropy fallback) are replaced with `<redacted>`. All captured environment-variable values are unconditionally scrubbed regardless of whether they match a token pattern — variable names are kept, values are not. The local report file and the GitHub issue body both consume the same post-redaction body and are never re-redacted separately.

## Where reports go

The skill writes to `.gaia/local/forensics/<timestamp>-<class>.md` using an ISO-8601 compact UTC timestamp (`YYYYMMDDTHHMMSSZ`). This path is gitignored by default, so reports stay local to the machine that generated them and never appear in git history.

The local file carries a small YAML frontmatter block (`class`, `gaia_version`, `created`, and optionally `gh_issue_url`). The report body that follows has four fixed sections — `## Symptom`, `## Classification`, `## Capture`, and `## Reproduction context` — in that order. The body schema is load-bearing: downstream tooling parses it without LLM fallback, so section names and order never drift.

If the failure classifies as a probable bug and `gh` is installed, the skill offers to file a GitHub issue against the upstream GAIA repository. The user confirms before any network call is made; on confirmation the issue body is the post-frontmatter portion of the local report — byte-identical to the local file body. If `gh` is not installed, the skill saves the report locally and exits cleanly with a one-line note. In either case the local file is always saved first, so the report survives regardless of network availability or `gh` authentication state.

## What it doesn't do

- **Never mutates GAIA state.** The skill is strictly read-only. It does not run `pnpm install`, `git fetch`, `git stash`, or any script that modifies the working tree.
- **Never auto-fixes.** It diagnoses and reports; remediation is the user's call.
- **Never re-runs the failing workflow.** The skill captures the state at invocation time; it does not attempt to reproduce or replay the failure.
- **Never captures file bodies from `app/`, `wiki/`, or `studio/`.** Filenames from these directories may appear in state summaries; full contents are excluded.
- **Never captures Claude Code session JSONL contents.** Session files are excluded in full — not even their paths appear in the report.
- **Never pre-checks `gh` auth or label existence.** On `gh` failure, the native error is surfaced verbatim and the local report remains in place.

## Why this exists

When a GAIA workflow misfires, the distance between "something went wrong" and "the maintainer has enough information to reproduce it" is often large. The forensics skill closes that gap in one command — capturing the relevant environment snapshot, classifying the failure against a known taxonomy, and redacting sensitive data before anything leaves the machine.

See [[Claude Skills]], [[Quality Gate]].
