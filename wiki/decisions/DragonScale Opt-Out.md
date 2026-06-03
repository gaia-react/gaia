---
type: decision
status: active
created: 2026-04-26
updated: 2026-04-26
tags: [decision, claude]
---

# Decision: DragonScale Opt-Out

**Recommendation: DO NOT ADOPT.** GAIA stays on the standard claude-obsidian wiki surface (Mode B + E). DragonScale is a v1.6.0 optional extension layered on top of the same plugin; we deliberately decline all four mechanisms it ships.

## Context

The claude-obsidian v1.6.0 release introduces **DragonScale**, an optional memory-layer add-on that overlays four mechanisms on the standard wiki:

1. **Fold operator** — extractive rollups of `wiki/log.md` into `wiki/folds/` checkpoint pages with deterministic IDs.
2. **Deterministic page addresses** — adds `address: c-NNNNNN` frontmatter to new non-meta pages via a file-locked counter in `.vault-meta/address-counter.txt`.
3. **Semantic tiling lint** — embedding-based duplicate-page detector. Requires `ollama` running locally with `nomic-embed-text` pulled.
4. **Boundary-first autoresearch** — frontier-scoring (out-degree − in-degree, recency-weighted) for `/autoresearch` topic suggestions. Requires `python3`.

It is activated per-vault by running `bash bin/setup-dragonscale.sh` from the upstream plugin cache. Each mechanism is independently disable-able via env flags. **By default, DragonScale is dormant** — none of the four mechanisms fire unless the setup script has run.

GAIA is a **template repo**. Every adopter forks it, runs `gaia-init`, and operates a small per-project codebase wiki (Mode B + E). Adopters are app developers, not knowledge workers running 1,000-page personal vaults. Anything we vendor or document becomes a tax on every fork.

## Decision

GAIA does not adopt DragonScale. We do not vendor `bin/setup-dragonscale.sh`, do not document it as part of the standard workflow, do not allow `address: c-NNNNNN` frontmatter, and do not require `ollama` or `python3` for any wiki operation. The plugin remains installed at v1.9.2 — DragonScale's files exist in the upstream cache but are never invoked.

## Rationale (per mechanism)

| Mechanism                   | Value to GAIA                                                                                                    | Cost                                                                                                     |
| --------------------------- | ---------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| Fold operator               | Near zero. `wiki/log.md` rarely exceeds 100 lines per project; the squash-autocommit hook already handles bloat. | Adds `wiki/folds/` clutter; another concept to teach adopters.                                           |
| Deterministic addresses     | Low. We already use stable wikilink slugs (`[[Form Field]]`). Renames are rare and tracked by git.               | Frontmatter noise on every new page; `.vault-meta/` becomes another committed artifact.                  |
| Semantic tiling lint        | Low. Vaults are small (~50 pages); duplicates surface in code review. Real value emerges at 200+ pages.          | **Hard dependency on local `ollama` + `nomic-embed-text`.** Friction for every adopter; CI implications. |
| Boundary-first autoresearch | Near zero. GAIA users don't run `/autoresearch` on codebase wikis; they ingest known sources.                    | `python3` dep; another script in `bin/`.                                                                 |

DragonScale is engineered for **large, evolving, long-horizon knowledge vaults** (the upstream guide explicitly calls these out: "research vaults", "large evolving wikis", "log-heavy vaults"). GAIA's wikis are **small, scoped, codebase-bound, per-fork**. The `ollama` dependency alone is a non-starter for a template repo — we'd be telling every adopter to install and run a local LLM service to satisfy a lint check that finds problems they don't have.

## Frontmatter implication

`address: c-NNNNNN` is **forbidden** in GAIA wiki pages. The field is feature-gated upstream (`DRAGONSCALE_ADDRESSES=0` in `wiki-ingest` and `wiki-lint` skills); since we never run the installer, the field never appears. Any page sporting it should be treated as drift and the field removed.

## Reversal path (opt-in for adopters who want it)

Any GAIA adopter who scales their wiki past ~200 pages, starts running `/autoresearch` heavily, or otherwise wants the DragonScale features can opt in **per fork** without GAIA's involvement:

1. Confirm `claude-obsidian` plugin is installed (it is, post-v1.9.2 baseline).
2. Run `bash ~/.claude/plugins/cache/claude-obsidian-marketplace/claude-obsidian/<version>/bin/setup-dragonscale.sh` from the project root.
3. Install local prerequisites only for the mechanisms they want — `ollama` + `nomic-embed-text` for tiling, `python3` for boundary scoring.
4. Update their fork's wiki schema doc (e.g. `wiki/index.md` or a top-level `CLAUDE.md`) to permit `address: c-NNNNNN`.

The script is idempotent and per-vault, so opt-in is reversible by deleting `.vault-meta/` and `wiki/folds/`. Nothing in the GAIA template needs to change for an adopter to take this path.

## Cross-links

[[Claude Integration Conventions]] · [[Claude Skills]] · [[Quality Gate]]
