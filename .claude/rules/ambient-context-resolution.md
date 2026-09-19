---
paths:
  - '.gaia/scripts/**/*.sh'
  - '.claude/hooks/**/*.sh'
  - '.github/workflows/**/*.yml'
  - '.gaia/**/*.ts'
  - '**/*.bats'
---
<!-- gaia-harden: promoted from recurring finding_class holistic/ambient-context-resolution; pruned by /gaia-audit on obsolescence/redundancy/supersession/duplication only, never for non-recurrence -->

# Resolve the Subject From the Input, Not the Ambient State

Every mechanism acts on a subject: a repository root, a working tree, a base commit, a head commit, a manifest. When the code takes that subject from whatever the process happens to be sitting in (the working directory, `HEAD`, the default branch, the runner's checkout), the logic stays correct and runs against the wrong thing. Nothing fails. The check passes on a tree nobody asked about, or the write lands in a sibling checkout.

## Anti-pattern

- A hook that gates a command runs `git rev-parse --show-toplevel` or `git diff` in its own working directory, while the command it gates targets another tree through `git -C <path>` or a `cd` inside the command string.
- A script derives the main checkout's root, or an audit base, with its own inline `git` chain instead of calling the shared resolver, so it agrees with the resolver today and diverges on the next worktree or fallback case.
- A workflow step reads `git rev-parse HEAD` or the default branch when the event payload already names the commit or base ref it is acting for.
- A bats suite exercises a script without pinning the tree it acts on, so it passes from the repository root and fails, or passes vacuously, from a worktree or in CI.

## Correct pattern

Before writing the first `git` call, name the subject and where it comes from. Take it from the argument, the hook payload, or the event payload that identifies it, and pass it down explicitly (`git -C "$target"`, an explicit `--base`, a `cwd` parameter). Fall back to the ambient state only when the input genuinely names nothing, and say so where it happens.

For the subjects GAIA already centralizes, call the owner instead of deriving it:

- The main checkout's root: `gaia_resolve_main_root` in `.gaia/scripts/main-root-lib.sh`.
- A pull request's diff base, with its provenance: `.claude/hooks/lib/audit-base-provenance.sh`.
- A Code Audit Team member's incremental review base: `.github/audit/resolve-audit-base.sh --member <name>`.

<!-- gaia:maintainer-only:start -->
GAIA maintainers: the CLI's TypeScript counterpart is `resolveMainWorktreeRoot` in `.gaia/cli/src/util/main-root.ts`; call it rather than deriving the main root inside CLI source. `.gaia/scripts/check-resolver-singleton.sh`, `.gaia/scripts/check-main-root-derivation.sh`, and `.gaia/scripts/check-base-provenance-adoption.sh` catch a second definition and the derivation spellings their own headers name, and those headers are the authority on what they reach. Any other spelling, and any subject those checks do not name, falls to this rule.
<!-- gaia:maintainer-only:end -->
