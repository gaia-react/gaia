---
type: concept
status: active
created: 2026-07-07
updated: 2026-07-07
tags: [concept, claude, sandbox, security]
---

# OS Sandbox

Claude Code ships an OS-level Bash sandbox that isolates filesystem and network access for the commands it runs, using Seatbelt on macOS and bubblewrap plus socat on Linux and WSL2; it is unavailable on native Windows and WSL1. See the [official sandboxing docs](https://code.claude.com/docs/en/sandboxing.md) for the config keys, per-platform setup, and the full capability/tradeoff detail; this page does not duplicate it.

## GAIA's stance: owner recommends, each machine resolves

Enabling the sandbox is a two-tier preference, not a single flip. Tier one is a committed recommendation: the project owner records intent (`sandbox_recommended`) once, checked into shared config, never a raw Claude Code enable. Tier two is per-machine resolution: `/setup-gaia` reads that recommendation, detects what the current machine can actually support, and resolves through one informed prompt, writing the real enable only to the gitignored per-machine settings.

A checked-in raw enable would be worse than no recommendation at all. Sandbox capability is machine-specific, an owner's Linux box with the right dependencies installed says nothing about a teammate's WSL1 setup or a fresh clone with none of them present. Baking in a hard "on" degrades silently to warn-and-unsandboxed the moment a machine can't back it, and forces avoidable friction on every clone that has to work around a setting it didn't choose. Recommend the intent, resolve it locally, every time.

## What the sandbox does and does NOT protect

Say it plainly: enabling the sandbox alone does not protect .env. That is the honesty this page exists to carry.

`.env` protection comes from a separate mechanism: GAIA's `Read(.env)` and `Edit(.env)` deny rules merge into the sandbox boundary, so the deny reaches subprocesses spawned by sandboxed Bash, not just the Read/Edit tools directly. That merge covers exactly one thing: the literal `.env` file. It does not extend to the `.env.local` / `.env.production` variant family (that coverage is hook-delivered and does not merge into the sandbox boundary), it does not cover MCP shell execution, and it does not cover a command excluded from the sandbox (for example one that shells out to `docker`). The same merged deny also blocks the app's own `.env` reads under Claude-run tooling such as Vite or the test runner, which is a useful side effect, not a substitute for defense in depth elsewhere.

Sandbox capability can also change under a machine after it's been enabled: if a dependency the sandbox relies on later goes missing, a previously-enabled machine degrades to running unsandboxed by default rather than failing loudly. Treat the sandbox as one layer among several, not the whole boundary.

## Enabling it

Run `/setup-gaia`. It prompts once for the sandbox decision and, if you opt in, seeds a minimal starter config for your machine. See the [official sandboxing docs](https://code.claude.com/docs/en/sandboxing.md) for what that config actually contains and how to extend it.
