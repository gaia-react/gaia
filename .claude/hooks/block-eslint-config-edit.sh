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
# The guard is a filename match, and what a match buys is a QUESTION rather than
# a verdict: every edit to the file prompts the operator, whatever the edit does.
# Judging what an edit changes instead of which file it touches does not separate
# the legitimate case from the silencing one, because the two are the same shape.
# Adding a bare `...lint.<group>` preset spread is the migration GAIA's own
# CHANGELOG tells adopters to make, and it is also how a rule gets turned off: a
# later config object overrides an earlier one, and the groups in
# `@gaia-react/lint` overlap heavily rather than partitioning the rule space.
# Adding `...lint.reactRouter` after `...lint.base` turns `no-empty-pattern` off;
# adding `...lint.storybook` after `...lint.react` turns
# `react-hooks/rules-of-hooks` off.
#
# Which of those an adopter wants is a fact about their intent, and no hook reads
# intent. Asking is what follows from that: the separating property is held by
# the operator, so the call goes to the party that holds it rather than being
# guessed here or refused outright.
#
# Comparing the resolved configs before and after the edit does not rescue a
# verdict. It reproduces the same conflict one layer down, because the sanctioned
# reactRouter migration is itself a severity drop: it takes `no-empty-pattern`
# from error to off on a route file, so a rule that denies any drop denies the
# migration. The answer also depends on which files are sampled, since the groups
# are glob-scoped; reaching it means executing the very config being judged; and
# its slow path is worse than its answer, because a PreToolUse hook past its
# deadline is cancelled with no decision at all and the write then proceeds
# uninspected. A guard whose slow path allows what it matched is worse than a
# guard that asks.
#
# What the guard owes in exchange for asking on the filename alone is a reason
# that says so. It admits the prompt is on the filename alone, names the edit
# that is legitimate, and points at the source file for the common case. A reason
# implying every edit here is a lint error being silenced is the defect this one
# exists not to repeat: it is wrong about the sanctioned migration, and it leaves
# whoever reads it with no way to tell the two cases apart either.
#
# The decision is JSON on stdout and the hook exits 0 with it; `ask` puts the
# call to the operator, and the reason string is what they read.
#
# Beyond an ordinary path-gate miss, one further case exits 0 silently and it is
# not an exemption: a payload with no readable file_path says nothing about
# whether the call even targets a config, so the path gate cannot fire on it.
# Every payload that does name a config asks.
set -euo pipefail

payload=$(cat)

file_path=$(jq -r '.tool_input.file_path // ""' <<<"$payload" 2>/dev/null) || file_path=""

# Fed by herestring rather than through a pipe, deliberately. `file_path` comes
# from the payload, so its length and line count are not bounded by anything a
# real path obeys. Piped into `grep -q`, a match on an early line lets grep exit
# and close the pipe while the writer still has more than a pipe buffer to
# write; the writer dies on SIGPIPE, `pipefail` adopts its status, and `|| exit 0`
# turns a match into an unprompted allow. A guard whose failure mode is "allows
# what it matched" has to not have that mode at all, so the pipeline goes rather
# than being bounded.
grep -Eq '(^|/)eslint\.config\.(js|cjs|mjs|ts|mts|cts)$' <<<"$file_path" || exit 0

jq -n --arg r "CONFIRM: this hook asks on the filename alone, whatever the edit does, because no automatic test tells a lint error being silenced here apart from a legitimate config change. Most edits here are the first kind: fix the ESLint error in the source file where it occurs, not in this file. Some are not, and adding a '...lint.<group>' preset spread is one, including the '...lint.reactRouter' migration GAIA's CHANGELOG tells adopters to make. Approve only if you meant this edit; otherwise deny it, and do not disable this hook to get past it." '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "ask",
    permissionDecisionReason: $r
  }
}'
exit 0
