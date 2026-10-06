---
type: dependency
status: superseded
package: spec-kit
role: spec-authoring-engine
created: 2026-05-06
updated: 2026-10-06
tags: [dependency, spec-kit, claude]
---

# spec-kit

> Superseded. GAIA no longer installs spec-kit; `/gaia-spec` runs on GAIA's own scripts and templates, see [[GAIA Spec]].

[GitHub spec-kit](https://github.com/github/spec-kit) is a spec-driven-development toolkit that GAIA once layered under `/gaia-spec`. GAIA does not depend on it, for these reasons:

- Every real step of `/gaia-spec` (allocation, drafting, ledger, locking, self-review, lint) is GAIA's own bash and prose, so core supplies no capability GAIA consumes; it only added an overridden prompt body, a replaced template, an unwanted feature branch, a potential stray `specs/` tree, a CLAUDE.md block, and rendered skills.
- The hook bus does not run its documented checks: the constitution check passes on an unfilled stock constitution, the post-specify lint fires on the step-3 skeleton rather than the saved SPEC, and the post-clarify hook never fires on the `/gaia-spec` path.
- The implement hooks fire only from core's own implement command, which nothing in GAIA runs, so uat-write and wiki-promote were never triggered.
- Rendered skills go stale on update, because `/update-gaia` never re-runs the extension or preset registration.
- Past v0.10.0 upstream churns (the install flag GAIA used was removed and 1.0.0 disclaims stability), so tracking it is a recurring migration with nothing gained.

The original design record is [[spec-kit Extension Strategy]].

## Related

- [[GAIA Spec]]: the workflow that runs without spec-kit.
- [[spec-kit Extension Strategy]]: the superseded design record.
