# 09-registry-completeness-glob-gap

**Path**: `.gaia/scripts/check-registry-completeness.sh`
**Line**: 18

## Title

The registry-completeness scan's own directory listing skips a file extension the
registry itself accepts.

## Failure mode

The script builds its "files that should be registered" set with
`find .claude/agents -maxdepth 1 -name "*.md"`. The agent registry format also accepts
`.mdx` companion files for two members, but the `find` command's `-name` pattern has no
branch for that extension, so those files never enter the set the script checks for
registration. The script then reports the registry complete without having looked at
them at all.

## Verified by

Added a temporary `.mdx` file with no registry entry under `.claude/agents/` and reran
the script; it reported the registry complete, having never listed the new file.

## Suggested fix

Extend the `find` pattern to cover `.mdx` alongside `.md` (or use `-regex` to accept
both in one clause), so every input the registry format allows is in the set the
script actually checks.
