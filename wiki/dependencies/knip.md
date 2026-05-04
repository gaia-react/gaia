---
type: dependency
status: active
package: knip
version: ^6.11.0
role: dead-code-detection
created: 2026-05-04
updated: 2026-05-04
tags: [dependency, quality]
---

# knip

Reports unused files, exports, types, and dependencies across the codebase. Devtime-only.

## Conventions

- Config: `knip.config.ts` (repo root)
- Run: `pnpm knip`
- Not part of the [[Quality Gate]] — in-progress work routinely flags exports that haven't been wired up yet, which drowns the signal.

## Template-aware config

GAIA's `gaia/` directory is a library template. Files in `app/components/`, `app/hooks/`, `app/utils/`, `app/services/`, and `app/types/` are intentionally exported for downstream projects to consume. The config marks these directories as `entry` globs so their exports aren't flagged as dead. Bundled deps used via Tailwind / Storybook / MSW / runtime resolution are listed in `ignoreDependencies`.

## When to run

- After a refactor that removes or restructures modules
- After deleting a feature, route, page, or component
- After removing or replacing a dependency
- Before opening a release-candidate PR

## Acting on output

Output falls into three buckets:

1. **Real dead code** — unused file/export/type with no callers. Delete.
2. **Library API exposed for downstream use** — intentionally exported even though this repo doesn't consume it. Add to `entry` globs in `knip.config.ts`.
3. **Implicit dependency** — package used via config plugin, CSS, or runtime resolution that knip can't trace. Add to `ignoreDependencies` in `knip.config.ts`.

See [[Quality Gate]].
