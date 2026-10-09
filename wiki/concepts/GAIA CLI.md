---
type: concept
title: GAIA CLI
status: active
created: 2026-07-14
updated: 2026-10-09
tags: [concept, cli]
---

# GAIA CLI

GAIA ships a single bundled CLI binary that hooks and slash commands invoke, plus a fire-and-forget adoption ping that reports coarse setup usage back to the GAIA team. The ping is the only unattended call GAIA makes to a GAIA-operated service. The only other unattended network call is a git fetch that reaches nothing but the repository's own configured `origin` (see below). Cost pricing opens no network connection.

## CLI workspace

`.gaia/cli/` houses the CLI. Adopters receive a self-contained bundled binary at `.gaia/cli/gaia` (~1.1MB, `#!/usr/bin/env node` shebang), invoked by hooks and slash-command emits. The subcommand router uses a static handler map (no switch; the project's `no-switch` rule). Adopters receive only the `gaia` binary; source, tests, and fixtures are excluded from the release tarball.

<!-- gaia:maintainer-only:start -->
Maintainer source lives at `.gaia/cli/src/`. `pnpm bundle` runs `bundle:adopter` then `bundle:maintainer` (esbuild, ESM); the maintainer build emits a separate `.gaia/cli/gaia-maintainer` binary that adds the release namespace and is excluded from the adopter tarball. A commit that stages CLI source rebuilds and stages both bundles through the pre-commit hook, and `.gitattributes` marks the bundles as generated.
<!-- gaia:maintainer-only:end -->

Run `gaia --help` for the current, authoritative list of top-level subcommands.

## Adoption ping

The adoption ping exists to steer GAIA's roadmap: knowing which setup options and platforms adopters actually use tells the team where feature work will pay off. `gaia ping` (`src/ping/`) sends a fire-and-forget POST to `https://telemetry.gaiareact.com/ping` when `/gaia-init`, `/setup-gaia`, and `/update-gaia` complete. The body carries the event name (`init`, `setup`, or `update`), a per-install `projectId` (the deterministic id at `.gaia/local/.project-id`), the GAIA version, the coarse OS platform (`macos`/`windows`/`linux`, else `other`), and a handful of low-cardinality categorical fields specific to the event (e.g. `mode`/`i18n`/`ci` for `init`; `type`/`repo`/`ci`/`audit` for `setup`; `from`/`to` for `update`). `GAIA_TELEMETRY_PING_DISABLE=1` suppresses it; there is no other opt-out. The stable `projectId` makes the pixel pseudonymous-per-install rather than fully anonymous, correlating one install's `init` -> `setup` -> `update` events; it never carries user paths or free text. A network failure, timeout, or unreadable manifest never affects the caller's exit code.

## The unattended git fetch

The session-start janitor ([[Local Working State]]) makes one bounded `git fetch --prune` of the repository's own configured `origin`. It contacts no GAIA service and sends nothing about the machine or its contents; it is a plain git fetch of the remote the adopter already pushes to. It is gated on a local `wiki/sync-*` (or legacy `wiki-sync/*`) branch being present, so a session with no outstanding wiki landing makes no call at all, and it is bounded at 5 seconds by default and rate-limited between sessions. `GAIA_WIKI_FETCH_TIMEOUT_SECONDS=0` disables it outright.

## The wiki chain's cost line

The `/gaia-wiki` chain ends its run with `bash .gaia/scripts/usage.sh record command:gaia-wiki --workflow gaia-wiki`, passing `--pr` when the chain opened a pull request, and writes the resulting `Cost:` line through to stdout. The call is best-effort: a missing script or a non-zero exit relays its one stderr line and never changes the chain's exit code. See [[Usage Ledger]].

## Pairs with

- [[Usage Ledger]]: the cost store `usage.sh record` closes runs into.
- [[Token Cost Readout]]: the pricing surfaces built on top of the ledger.
- [[Claude Hooks]]: the hook surface that invokes the CLI binary.
