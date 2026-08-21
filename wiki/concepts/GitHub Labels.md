---
type: concept
status: active
created: 2026-08-20
updated: 2026-08-20
tags: [concept, github, labels, workflow]
---

# GitHub Labels

`.gaia/labels.json` is the single machine-readable source of truth for every GitHub label GAIA creates, syncs, and documents. Each entry carries its color, its description, the axis it classifies on, whether it belongs to an adopter repository or only to the GAIA maintainer repository, and which feature has to be enabled before the label is owed at all. `.gaia/labels.schema.json` is the editor-facing copy of the shape, and the `gaia labels` commands validate the registry themselves before acting on it.

The middle of this page is generated from that registry. A hand edit between the two `gaia:labels:generated` markers is reverted by the next regeneration, so a label's color or description changes in `.gaia/labels.json` and reaches the page from there. Everything above the start marker and below the end marker is hand-maintained, and the generator never touches a byte of it.

The appendix at the bottom is yours. A project that adds labels of its own documents them there, outside the generated span, where no regeneration can reach them.

## Commands

- `.gaia/cli/gaia labels sync` reconciles this repository's labels against the registry.
- `.gaia/cli/gaia labels docs` regenerates the span below from the registry.
- `.gaia/cli/gaia labels check` fails when a label literal in the tree is absent from the registry.

Sync is conservative by design. It renames rather than deleting and recreating, because a delete strips the label from every issue and pull request carrying it. It reports an unknown live label instead of touching it. Color is operator wins and description is GAIA wins, so a deliberate recolor survives an update while a stale description does not. Nothing is deleted without `--prune-deprecated` or `--enforce-blocked`, and `--enforce-blocked` counts a label's carriers on both surfaces, issues and pull requests, before reading it as uncarried; a label it cannot count on either surface is never deleted. A token without label-write scope produces a list of manual `gh` commands and a zero exit rather than a failed setup. That list means two different things, so the degraded output and the `--json` `degradedAt` field name which refusal happened: after a refused write it is the mutations still owed, while after a refused read the plan was computed against an assumed-empty repository and the list is the whole registry.

<!-- gaia:labels:generated-start -->

## GAIA labels

### Type

| Label | Color | Description | Created by |
| --- | --- | --- | --- |
| `tech-debt` | `ededed` | Out-of-scope review finding, tracked for a later drain | tech-debt |
| `bug` | `d73a4a` | Something GAIA ships is not working | always |
| `enhancement` | `a2eeef` | New feature or request | always |
| `security` | `a1121b` | Dependency CVE or security defect, opened by GAIA CI | gaia-ci |

### Urgency

| Label | Color | Description | Created by |
| --- | --- | --- | --- |
| `severity:critical` | `b60205` | Breaks a documented promise or loses work; drain first | tech-debt, gaia-ci |
| `severity:important` | `fbca04` | Degrades a documented behavior; drain before suggestions | tech-debt, gaia-ci |
| `severity:suggestion` | `c5def5` | Improvement with no broken behavior behind it | tech-debt |

### Effort

| Label | Color | Description | Created by |
| --- | --- | --- | --- |
| `difficulty:easy` | `bfe3df` | Fix is determined by the issue text and the cited code | tech-debt |
| `difficulty:medium` | `4c9c8f` | Fix has a design decision the surrounding code settles | tech-debt |
| `difficulty:hard` | `1b6b5f` | Fix has a design decision the surrounding code does not settle | tech-debt |

### Reach of fix

| Label | Color | Description | Created by |
| --- | --- | --- | --- |
| `handler:prompt` | `d4c5f9` | Fix is one logical unit in one file, no contract change | tech-debt |
| `handler:plan` | `8957e5` | Fix is larger or structural; drains via /gaia-plan | tech-debt |
| `handler:spec` | `4c2889` | Design-first; drains via a /gaia-spec handoff | tech-debt |

### Lifecycle

| Label | Color | Description | Created by |
| --- | --- | --- | --- |
| `in-progress` | `ffd33d` | Someone is actively working this issue right now; do not pick it up | always |
| `debt:spec-pending` | `a6e3b8` | Handed to /gaia-spec; parked until the SPEC lands | tech-debt |

### Modifier

| Label | Color | Description | Created by |
| --- | --- | --- | --- |
| `fold:required` | `fbb6ce` | Repair should ride a change that already pays its fixed cost | tech-debt |

### Disposition

| Label | Color | Description | Created by |
| --- | --- | --- | --- |
| `wontfix` | `e5e5e5` | Deliberately declined; never re-file this finding | always |

### Origin and trigger

| Label | Color | Description | Created by |
| --- | --- | --- | --- |
| `gaia-ci` | `d4d4d4` | Opened by a GAIA CI maintenance job | gaia-ci |
| `run-audit` | `a78bfa` | Forces the Code Audit Team to run on this pull request | always |

### Attention gate

| Label | Color | Description | Created by |
| --- | --- | --- | --- |
| `needs-human` | `d93f0b` | A machine stopped here; maintainer review required | always |

### Third-party

| Label | Color | Description | Created by |
| --- | --- | --- | --- |
| `dependencies` | `e1e4e8` | Dependabot: updates a dependency file | documented only |
| `github_actions` | `c9c9c9` | Dependabot: updates GitHub Actions code | documented only |

## Palette rule

Warm families (red, orange, amber) are reserved for attention: urgency, defect type, the gates that require a human, and the active-work claim, whose yellow marks an issue as in flight. Every other classificatory axis takes a cool or neutral family instead, high-frequency structural labels stay near grey so they recede, no two entries share a hex value, and every hex value is lowercase.

<!-- gaia:maintainer-only:start -->

## Maintainer-only labels

These labels serve the GAIA maintainer repository. Sync never creates them on an adopter repository, and the bundle-time scrub removes this section from the page an adopter receives.

### Lifecycle

| Label | Color | Description | Created by |
| --- | --- | --- | --- |
| `debt:pre-provenance` | `d7f0dd` | Filed before origin tracking; deprecated, kept for history | documented only |

### Disposition

| Label | Color | Description | Created by |
| --- | --- | --- | --- |
| `non-issue` | `cccccc` | Not a bug: user config, missing prerequisite, or duplicate | forensics |

### Origin and trigger

| Label | Color | Description | Created by |
| --- | --- | --- | --- |
| `gaia-forensics` | `5319e7` | End-user bug report routed via /gaia-forensics | forensics |
| `gaia-triaged` | `7d4cdb` | Forensics triage has processed this issue; re-firing is a no-op | forensics |

### Attention gate

| Label | Color | Description | Created by |
| --- | --- | --- | --- |
| `auto-fixable` | `f2a93b` | Quality Gate passed on the autofix branch; draft PR ready | forensics |

### Audience

| Label | Color | Description | Created by |
| --- | --- | --- | --- |
| `surface:adopter` | `d9a86c` | Defect an adopter can observe in something GAIA ships | tech-debt |
| `surface:maintainer` | `8a5a2b` | Defect observable only in the GAIA maintainer repository | tech-debt |

<!-- gaia:maintainer-only:end -->
## Deliberately absent

| Label | Reason |
| --- | --- |
| `good first issue` | Solicits drive-by contributions from people with no context for the work. GitHub recreates it on every new repository, so it needs an explicit block rather than a one-time delete. |
| `help wanted` | Same solicitation problem as good first issue. Both are GitHub defaults, recreated on every new repository, so a one-time delete does not hold. |

<!-- gaia:labels:generated-end -->

## Project labels

This section is where a project documents the labels it adds for itself. `gaia labels docs` never rewrites it, and `gaia labels check` never demands that a label named here be present in the registry.

A project label that falls into one of the GAIA axes above can take that family's color, so the palette stays readable across both sets. `gaia labels sync` reports a label it does not recognize and suggests the family color when the name carries a known namespace prefix, but it never recolors one without `--adopt-palette`.

| Label | Color | Description |
| --- | --- | --- |
| | | |
