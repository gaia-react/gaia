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

What that bans is the **enable**, not the **boundary**. `sandbox.filesystem.denyRead` is committed to `.claude/settings.json` deliberately, and carries none of the harm above: it grants no capability, cannot degrade a machine, and does nothing at all until something else turns the sandbox on. A boundary is also the half that must not be per-machine, since a deny every clone resolves for itself is a deny some clones will not have. So the two halves split on which one is a preference: whether to sandbox is the machine's call, what a sandbox must never read is the project's. The line between them is the `enabled` key, not the presence of a `sandbox` block.

<!-- gaia:maintainer-only:start -->
GAIA maintainers: `.gaia/tests/sandbox/manifest-and-enable.bats` enforces that line. It reads the `enabled` key rather than banning a `sandbox` block outright, which is what lets the committed boundary stand. The JSON spelling of an enable spans two lines, so a line-oriented grep cannot see it and the check walks the flattened sandbox object with a brace counter instead.
<!-- gaia:maintainer-only:end -->

## What the sandbox does and does NOT protect

Say it plainly: enabling the sandbox alone does not protect .env. That is the honesty this page exists to carry.

`.env` protection comes from a separate mechanism: GAIA declares `sandbox.filesystem.denyRead` entries in `.claude/settings.json`, so the deny reaches subprocesses spawned by sandboxed Bash, not just the Read/Edit tools directly. Those entries cover `.env` and the `.env.local` / `.env.production` variant family, and the key, certificate, and credential classes beside them (`**/*.key`, `**/*.pem`, `**/*credential*`, `**/secrets/**`); `.env.example` is re-opened by an `allowRead` entry, since a narrower allow wins inside a wider deny. Each dotenv class is spelled twice, once bare and once `**`-prefixed, because a sandbox filesystem path carrying no prefix resolves against the project root: the bare spelling alone would reach the root dotenv and nothing deeper, while both hooks decide on the basename and cover every depth, and the two tiers would then disagree about a dotenv inside a monorepo package. The key, certificate, credential, and secrets-directory classes beside them carry the `**`-prefixed spelling only, which already matches at the root as well as at depth, so a bare twin would buy them nothing. The `allowRead` exemption is depth-qualified alongside the deny, or a nested `.env.example` is denied where the root one is readable. `Edit(.env)` remains a permission rule and merges into the write side of the same boundary. What the merge does not cover is MCP shell execution, or a command excluded from the sandbox (for example one that shells out to `docker`). The same denied read also blocks the app's own `.env` reads under Claude-run tooling such as Vite or the test runner, which is a useful side effect, not a substitute for defense in depth elsewhere.

Declaring the boundary directly rather than through a `Read()` deny rule is deliberate, and the reason is a property of Claude Code rather than a preference. Any `Read()` rule in `permissions.deny` arms a bypass-immune circuit breaker that forces a manual approval prompt on every search or copy command whose target it cannot statically prove safe, so the rule that bought the sandbox coverage also made every recursive search in the tree cost a prompt. `sandbox.filesystem.denyRead` is not a permission rule and arms nothing, and it stays inert until a machine enables the sandbox, which is exactly the owner-recommends / machine-resolves split above. The tool tier is covered separately by `block-env-read.sh` and `block-secrets-read.sh`; see [[Claude Hooks]].

Sandbox capability can also change under a machine after it's been enabled: if a dependency the sandbox relies on later goes missing, a previously-enabled machine degrades to running unsandboxed by default rather than failing loudly. Treat the sandbox as one layer among several, not the whole boundary.

## Enabling it

Run `/setup-gaia`. It prompts once for the sandbox decision and, if you opt in, seeds a minimal starter config for your machine. See the [official sandboxing docs](https://code.claude.com/docs/en/sandboxing.md) for what that config actually contains and how to extend it.
