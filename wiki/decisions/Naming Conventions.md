---
type: decision
status: active
priority: 2
date: 2026-10-03
created: 2026-10-03
updated: 2026-10-03
tags: [decision, git, conventions]
---

# Decision: Naming Conventions

Commit subjects and PR titles follow Conventional Commits 1.0.0. The permitted types live in `.gaia/conventional-commits.json`, and `commitlint.config.mjs` reads them. The `commit-msg` hook (`.husky/commit-msg`) enforces the convention on every commit.
