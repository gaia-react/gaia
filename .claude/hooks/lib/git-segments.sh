#!/usr/bin/env bash
# Segment helpers the two git deny guards share: block-no-verify.sh and
# block-main-destructive-git.sh. Sourced, never executed; defines two functions
# and does no work at source time. Bash 3.2 compatible.
#
# It owns the two derivations a widening must reach in both guards at once, so
# a gap closed in one cannot stay open in the other. The per-segment loop, the
# `tr '|&;()' '\n'` split, the walk-reset marker, the cd tracking and every deny
# stay in each guard.

[ -n "${GAIA_GIT_SEGMENTS_SH:-}" ] && return 0
GAIA_GIT_SEGMENTS_SH=1

# gaia_collapsed_substitutions <text>: print the command once more with every
# `$( … )` span replaced by a single placeholder word, and print nothing when
# the text carries none or the collapse changes nothing. Cutting at every `(`
# and `)` is what lets the walk read a command INSIDE a substitution, and is
# also what splits a substitution standing in git's OWN arguments away from the
# command word: `git -C "$(pwd)" commit --no-verify` leaves no segment carrying
# both `git` and `commit`, and `git commit -m "$(cat f)" -n` orphans the `-n`.
# This line is read IN ADDITION to the command's own, so the body still reaches
# the walk as its own segment and only the outer invocation is rejoined. The
# placeholder is a bare `_` so a subcommand, a flag or a refspec written inside
# the span cannot arm the rejoined segment with something it never spelled.
#
# Innermost first, so a nested span collapses over successive passes; the bound
# is a backstop. A span crossing a newline is left alone, since sed reads a
# line at a time: that leaves the segment cut where it already was, which is
# the direction that hides nothing the walk reads today. Backtick spans are not
# collapsed; they pass through unchanged.
gaia_collapsed_substitutions() {
  local text="$1" previous_text pass=0
  # shellcheck disable=SC2016 # a literal opener matched in the text, not an expansion
  case "$text" in *'$('*) ;; *) return 0 ;; esac
  while [ "$pass" -lt 8 ]; do
    previous_text="$text"
    text=$(printf '%s' "$text" | sed -E 's/\$\([^()]*\)/_/g')
    [ "$text" = "$previous_text" ] && break
    pass=$((pass + 1))
  done
  [ "$text" = "$1" ] || printf '%s\n' "$text"
  return 0
}

# gaia_segment_command_word <segment>: print the segment with its leading
# whitespace, env-var assignment prefix, shell reserved word, and redirection
# stripped, so the command word is the first token. What the shell accepts in
# that run, each of which hid the whole invocation from a narrower reading:
# `NAME+=value` is a command prefix exactly as `NAME=value` is (`bash -c 'zz+=1
# env'` prints `zz=1`); an assignment's value may be quoted and carry
# whitespace (`GIT_AUTHOR_DATE="2024-01-01 12:00" git commit`), so a value read
# as an unquoted run stops at the opening quote; a reserved word or grouping
# token stands in command position with no `| & ; ( )` ahead of the command
# word for the walk to cut at, with `time` taking an optional `-p` or `--` of
# its own; and a redirection may lead a simple command (`bash -c '>/tmp/x echo
# hi'` writes the file), so one standing ahead of the invocation occupies the
# slot the command word is read from. bash 3.2 does not populate BASH_REMATCH
# reliably, so strip with sed rather than a capture loop.
#
# Honest limit: a command WRAPPER (`env`, `command`, `exec`, `nohup`,
# `timeout`, `xargs`) also stands where the command word is read and is NOT
# stripped, so it still hides the invocation. Each carries its own option
# grammar, and a blind strip would misread `env -i git …` and `timeout 5 git
# …`, so closing them needs a per-wrapper option table rather than this list.
#
# Second honest limit, of a different kind: a redirection whose target is
# another descriptor (`2>&1`, `>&2`) never reaches this strip at all, because
# the walk cuts segments at `&` and the invocation lands in a segment
# beginning with the descriptor number. Closing it means not cutting at an `&`
# that belongs to a redirection, which a separator split cannot tell from `&&`
# without reading the command the way the shell does.
gaia_segment_command_word() {
  printf '%s' "$1" | sed -E 's/^[[:space:]]*(([A-Za-z_][A-Za-z0-9_]*\+?=([^[:space:]"'"'"']+|"[^"]*"|'"'"'[^'"'"']*'"'"')*|[0-9]*[<>][^[:space:]]*|[{!]|coproc|elif|else|while|until|then|time([[:space:]]+(-p|--))?|do|if)[[:space:]]+)*//'
}
