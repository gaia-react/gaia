#!/usr/bin/env bash

# Block bare `pnpm test` / `npm test` (and `run test` variants) without `--run`,
# they start vitest in watch mode and never exit in CI / agent contexts.
# Exit 2 = block the tool call, stderr is shown to Claude as the reason.
#
# Command-position anchoring: the block only fires when `pnpm`/`npm` is the
# command word of a real pipeline segment (start of the command, after a
# `| & ; ( )` separator, or after a leading env-var prefix like `FOO=bar`).
# Command TEXT that merely mentions the phrase, a commit message
# (`git commit -m "run pnpm test later"`) or a `--body` string
# (`gh pr create --body "...pnpm test --run..."`), is not an invocation and
# never fires. Without this anchor the matcher grepped the whole command and
# tripped on those quoted substrings. The technique mirrors block-no-verify.sh
# / block-main-destructive-git.sh: split on pipeline separators, strip leading
# env-var assignments, act only on the resulting command word.
#
# The `--run` opt-out is scoped to the SAME segment as the invocation, so the
# `--run` that belongs to that `pnpm`/`npm test` call is what counts, never a
# stray `--run` elsewhere on the command line (a backtick or quote right after
# `--run` in some other program's argument no longer defeats detection).
#
# Carve-out: `test:ci` / `test:lint-staged` carry a `test:` token, not a bare
# `test`; the `test([[:space:]]|$)` boundary excludes them.
#
# No `set -e`: this is a UX guard against watch-mode hangs, not a security gate.
# On unparseable input the command resolves empty, the loop matches nothing, and
# the call is allowed, here the safe direction is to let the tool run rather than
# to over-block.

command=$(jq -r '.tool_input.command // ""' < /dev/stdin)

while IFS= read -r seg; do
  # Command word = the first token after leading whitespace + env-var
  # assignments (`WORD=value `). bash 3.2 does not populate BASH_REMATCH
  # reliably, so strip with sed rather than a capture group (mirrors
  # block-no-verify.sh).
  seg_cmd=$(printf '%s' "$seg" | sed -E 's/^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*//')

  # Act only when the command word is `pnpm`/`npm` and the script position is a
  # bare `test` (optionally reached via `run`).
  [[ "$seg_cmd" =~ ^(pnpm|npm)[[:space:]]+(run[[:space:]]+)?test([[:space:]]|$) ]] || continue

  # `--run`, scoped to this segment, turns the watch-mode run into a one-shot.
  if ! [[ "$seg_cmd" =~ (^|[[:space:]])--run([[:space:]]|$) ]]; then
    echo "BLOCKED: bare \`pnpm test\` / \`npm test\` starts vitest watch mode. Use \`pnpm test --run\` for one-shot runs." >&2
    exit 2
  fi
done < <(printf '%s\n' "$command" | tr '|&;()' '\n')

exit 0
