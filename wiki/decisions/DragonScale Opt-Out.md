---
type: decision
status: active
created: 2026-04-26
updated: 2026-10-01
tags: [decision, claude]
---

# Decision: DragonScale Opt-Out

GAIA does not ship or enable DragonScale. Its wiki runs on the standard claude-obsidian surface (Mode B + E). DragonScale is an optional extension layered on top of the same plugin, and GAIA declines all four mechanisms it ships. A project that wants any of them can opt in on its own; see [[#Opting in]].

## Context

DragonScale is an optional memory-layer add-on to claude-obsidian that overlays four mechanisms on the standard wiki:

1. **Fold operator**: extractive rollups of `wiki/log.md` into `wiki/folds/` checkpoint pages with deterministic IDs.
2. **Deterministic page addresses**: adds `address: c-NNNNNN` frontmatter to new non-meta pages via a file-locked counter in `.vault-meta/address-counter.txt`.
3. **Semantic tiling lint**: embedding-based duplicate-page detector. Requires `ollama` running locally with `nomic-embed-text` pulled.
4. **Boundary-first autoresearch**: frontier-scoring (out-degree − in-degree, recency-weighted) for `/autoresearch` topic suggestions. Requires `python3`.

It is activated per-vault by running `bash bin/setup-dragonscale.sh` from the upstream plugin cache. Each mechanism is independently disable-able via env flags. **By default, DragonScale is dormant**; none of the four mechanisms fire unless the setup script has run.

GAIA is a template. Every project built on it runs `/gaia-init` and keeps a small per-project codebase wiki (Mode B + E). Its users are app developers, not knowledge workers running 1,000-page personal vaults, so anything GAIA vendors or documents becomes a tax on every project.

## Decision

GAIA does not vendor `bin/setup-dragonscale.sh`, does not document it as part of the standard workflow, does not allow `address: c-NNNNNN` frontmatter, and does not require `ollama` or `python3` for any wiki operation. DragonScale's files exist in the upstream plugin cache, but nothing GAIA ships invokes them.

## Rationale (per mechanism)

| Mechanism                   | Value to a GAIA project                                                                                          | Cost                                                                                                     |
| --------------------------- | ---------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| Fold operator               | Near zero. `wiki/log.md` rarely exceeds 100 lines per project; the squash-autocommit hook already handles bloat. | Adds `wiki/folds/` clutter; another concept to learn.                                                    |
| Deterministic addresses     | Low. GAIA wikis use stable wikilink slugs (`[[Form Field]]`). Renames are rare and tracked by git.               | Frontmatter noise on every new page; `.vault-meta/` becomes another committed artifact.                  |
| Semantic tiling lint        | Low. Codebase wikis are small; duplicates surface in code review. Real value emerges at 200+ pages.              | **Hard dependency on local `ollama` + `nomic-embed-text`.** Friction for every developer; CI implications. |
| Boundary-first autoresearch | Near zero. Codebase wikis rarely run `/autoresearch`; they ingest known sources.                                 | `python3` dep; another script in `bin/`.                                                                 |

DragonScale is engineered for **large, evolving, long-horizon knowledge vaults** (the upstream guide explicitly calls these out: "research vaults", "large evolving wikis", "log-heavy vaults"). A GAIA wiki is **small, scoped, and codebase-bound**. The `ollama` dependency alone rules it out as a template default: every project would need a local LLM service running to satisfy a lint check that finds problems it does not have.

## Frontmatter implication

`address: c-NNNNNN` is **forbidden** in GAIA wiki pages. The field is feature-gated upstream (`DRAGONSCALE_ADDRESSES=0` in the `wiki-ingest` and `wiki-lint` skills); without the installer, the field never appears. Treat any page carrying it as drift and remove the field, unless the project has opted in below.

## Opting in

A project whose wiki grows past ~200 pages, that runs `/autoresearch` heavily, or that otherwise wants the DragonScale features can opt in without any change to GAIA:

1. Confirm the `claude-obsidian` plugin is installed.
2. Run `bash ~/.claude/plugins/cache/claude-obsidian-marketplace/claude-obsidian/<version>/bin/setup-dragonscale.sh` from the project root.
3. Install local prerequisites only for the mechanisms you want: `ollama` + `nomic-embed-text` for tiling, `python3` for boundary scoring.
4. Update the project's wiki schema doc (e.g. `wiki/index.md` or a top-level `CLAUDE.md`) to permit `address: c-NNNNNN`.

The script is idempotent and per-vault, so opting in is reversible by deleting `.vault-meta/` and `wiki/folds/`.

## Cross-links

[[Claude Integration Conventions]] · [[Claude Skills]] · [[Quality Gate]]
