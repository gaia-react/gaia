#!/usr/bin/env bash
# PreToolUse Edit|Write|MultiEdit hook: guard eslint.config.{js,cjs,mjs,ts,mts,cts}
# at any path. Single-app projects have it at the repo root; monorepos nest it
# under each app (apps/web/eslint.config.mjs), so the path gate matches on the
# filename and works in both layouts.
#
# The six extensions are ESLint's own `FLAT_CONFIG_FILENAMES`, not a guess at
# the ones people use. A config the resolver loads and this gate does not match
# is unguarded and silently so, which is the worst of the two directions: the
# adopter gets no message telling them the rule they wanted is now off.
#
# The guard is a filename match: every edit to the file is denied, whatever the
# edit does. That is broader than the rule it serves, which is "fix the lint
# error in the source file where it occurs, never silence it here", and the
# breadth is deliberate rather than a shortcut. Judging what an edit changes
# instead of which file it touches does not separate the two cases, because the
# legitimate shape and the silencing shape are the same shape. Adding a bare
# `...lint.<group>` preset spread is the migration GAIA's own CHANGELOG tells
# adopters to make, and it is also how a rule gets turned off: a later config
# object overrides an earlier one and the groups in `@gaia-react/lint` overlap
# heavily rather than partitioning the rule space. Adding `...lint.reactRouter`
# after `...lint.base` turns `no-empty-pattern` off; adding `...lint.storybook`
# after `...lint.react` turns `react-hooks/rules-of-hooks` off. Which of those an
# adopter wants is a fact about their intent, and no hook reads intent.
#
# What the guard owes in exchange for being blunt is a message that says so. It
# states that the denial is on the filename alone, names the edit that is
# legitimate, and says how to make it. A message implying every edit here is a
# lint error being silenced is the defect this one exists not to repeat: it is
# wrong about the sanctioned migration and it leaves an agent with no next step
# but to give up or work around the hook.
#
# Whether any evidence a synchronous hook can reach would separate the two, and
# so let the sanctioned migration through without also letting silencing
# through, is an open design question tracked as tech-debt #1220. A text-level
# allowlist over what an edit changes is the candidate already measured and
# closed; that issue carries the measurement and its specification.
#
# Exit 2 = block the tool call, stderr is shown to Claude as the reason.
#
# Beyond an ordinary path-gate miss, one further case exits 0 and it is not an
# exemption: a payload with no readable file_path says nothing about whether the
# call even targets a config, so the path gate cannot fire on it. Every payload
# that does name a config is denied.
set -euo pipefail

payload=$(cat)

file_path=$(jq -r '.tool_input.file_path // ""' <<<"$payload" 2>/dev/null) || file_path=""

# Fed by herestring rather than through a pipe, deliberately. `file_path` comes
# from the payload, so its length and line count are not bounded by anything a
# real path obeys. Piped into `grep -q`, a match on an early line lets grep exit
# and close the pipe while the writer still has more than a pipe buffer to
# write; the writer dies on SIGPIPE, `pipefail` adopts its status, and `|| exit 0`
# turns a match into an allow. A guard whose failure mode is "allows what it
# matched" has to not have that mode at all, so the pipeline goes rather than
# being bounded.
grep -Eq '(^|/)eslint\.config\.(js|cjs|mjs|ts|mts|cts)$' <<<"$file_path" || exit 0

echo "BLOCKED: this guard denies every edit to eslint.config.* on the filename alone, because no automatic test tells a lint error being silenced here apart from a legitimate config change. Most edits here are the first kind: fix the ESLint error in the source file where it occurs, not in this file. Some are not, and adding a '...lint.<group>' preset spread is one, including the '...lint.reactRouter' migration GAIA's CHANGELOG tells adopters to make. Make that edit by hand, or ask your operator to temporarily disable this hook in .claude/settings.json; do not disable it yourself and do not work around it." >&2
exit 2
