---
type: concept
title: GAIA CLI
status: active
created: 2026-07-14
updated: 2026-07-14
tags: [concept, cli]
---

# GAIA CLI

GAIA ships a single bundled CLI binary that hooks and slash commands invoke, plus a fire-and-forget adoption ping that reports coarse setup usage back to the GAIA team.

## CLI workspace

`.gaia/cli/` houses the CLI. Adopters receive a self-contained bundled binary at `.gaia/cli/gaia` (~1.1MB, `#!/usr/bin/env node` shebang), invoked by hooks and slash-command emits. The subcommand router uses a static handler map (no switch; the project's `no-switch` rule). Adopters receive only the `gaia` binary; source, tests, and fixtures are excluded from the release tarball.

<!-- gaia:maintainer-only:start -->
Maintainer source lives at `.gaia/cli/src/`. `pnpm bundle` runs `bundle:adopter` then `bundle:maintainer` (esbuild, ESM); the maintainer build emits a separate `.gaia/cli/gaia-maintainer` binary that adds the release namespace and is excluded from the adopter tarball.
<!-- gaia:maintainer-only:end -->

Run `gaia --help` for the current, authoritative list of top-level subcommands.

## Adoption ping

The adoption ping exists to steer GAIA's roadmap: knowing which setup options and platforms adopters actually use tells the team where feature work will pay off. `gaia ping` (`src/ping/`) sends a fire-and-forget POST to `https://telemetry.gaiareact.com/ping` when `/gaia-init`, `/setup-gaia`, and `/update-gaia` complete. The body carries the event name (`init`, `setup`, or `update`), a per-install `projectId` (the deterministic id at `.gaia/local/.project-id`), the GAIA version, the coarse OS platform (`macos`/`windows`/`linux`, else `other`), and a handful of low-cardinality categorical fields specific to the event (e.g. `mode`/`i18n`/`ci` for `init`; `type`/`repo`/`ci`/`audit` for `setup`; `from`/`to` for `update`). `GAIA_TELEMETRY_PING_DISABLE=1` suppresses it; there is no other opt-out. The stable `projectId` makes the pixel pseudonymous-per-install rather than fully anonymous, correlating one install's `init` -> `setup` -> `update` events; it never carries user paths or free text. A network failure, timeout, or unreadable manifest never affects the caller's exit code.

## Pairs with

- [[Cost Data Contract]]: the token ledger's full record schema.
- [[Token Cost Readout]]: the pricing surfaces built on top of the token ledger.
- [[Claude Hooks]]: the hook surface that invokes the CLI binary.
