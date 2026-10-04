---
paths:
  - 'app/**'
  - 'test/**'
  - '.playwright/**'
  - '.storybook/**'
  - 'vite.config.*'
  - 'playwright.config.*'
  - 'package.json'
  - 'dev-ports*.ts'
---

# Ports

Every checkout owns its own dev, Storybook, and Playwright ports. The main checkout is slot 0 (5173 and 6006); each linked worktree holds a slot of its own.

- Read this tree's ports from `bash .gaia/scripts/ports.sh` (`--field dev|storybook|site-url|slot` prints one value). Never hardcode 5173 or 6006.
- Start servers with `pnpm dev`, `pnpm storybook`, and `pnpm pw`, so the strict port and the launch record apply. Only `pnpm storybook` is strict about Storybook's port; a direct `storybook dev` bypasses the launcher and can drift to another port.
- A taken port is refused, never drifted from. Never stop a process on a port another live tree owns without asking the user first. That covers a server owned by another tree, one a human started, and one you cannot identify.
- A linked worktree with no port file (`frontend/.gaia-ports`) refuses `pnpm dev`, `pnpm storybook`, and `pnpm pw`. Fix it with `bash .claude/hooks/provision-worktree.sh <worktree-path>`; never borrow the main checkout's ports.
- Servers this session launched are stopped automatically at a later session start once this session has ended. Nothing is stopped on `/clear` or compaction.
