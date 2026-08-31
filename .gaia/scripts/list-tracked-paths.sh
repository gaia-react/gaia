#!/usr/bin/env bash
# shellcheck shell=bash
#
# list-tracked-paths.sh -- the single boundary where GAIA's release staging
# turns git's NUL-delimited tracked set into the newline-delimited list its
# downstream consumers read, and the single place that refuses the one input
# that conversion cannot survive.
#
# `git ls-files -z` emits one record per path, NUL-separated, and `-z` is what
# stops git C-quoting a path carrying a non-ASCII byte (#1662). Every consumer
# downstream of this point is newline-oriented and stays that way on purpose:
# `grep -f` reads a newline-delimited pattern file, and macOS ships openrsync,
# which has no `--from0`. So the stream has to be translated back to newlines,
# and a path holding a literal newline -- the one byte a POSIX path may legally
# contain that a newline-delimited list cannot represent -- splits into two
# records that name no file.
#
# What that costs, measured against fixture repositories holding a tracked
# `a<LF>b` (#1669): `rsync --files-from` exits 23 when a name it is handed does
# not exist, which under a `bash -e` step aborts the release with a `stat` error
# naming a path fragment nobody wrote. But it exits 0 whenever every name that
# reaches it happens to exist -- because both halves name real tracked files,
# because the exclude filter dropped both, or any mix of the two -- and then the
# tarball publishes WITHOUT the newline-bearing file while `.gaia/manifest.json`
# records it as shipping. The manifest side never compensates: its exclude
# patterns are compiled without the `m` flag, so an anchored pattern cannot
# match a spelling that spans a line break, and the joined path is always
# recorded as shipping.
#
# Refusing here is the only repair that behaves the same way in both outcomes.
# Keeping the stream NUL-delimited end to end would need `grep -z` and
# `rsync --from0`, neither of which is available on the macOS half of the
# surface that runs this, so the refusal is also the portable answer.
#
# The refusal is a diagnostic, not a silent drop: every offending path is named
# on stderr with its newline rendered as `\n`, so a maintainer reads the actual
# path instead of inferring it from a fragment.
#
#   bash .gaia/scripts/list-tracked-paths.sh <repo-dir> <output-file>
#
# Exit 0 on success (<output-file> holds the newline-delimited tracked set),
# 1 on refusal and only on refusal (a tracked path holds a literal newline;
# <output-file> is not written), 2 on every other failure: a usage error, the
# discovery failing, the newline scan failing, or the output write failing.
#
# The 1-versus-2 split is load-bearing, not bookkeeping, and the callers use it
# two different ways. The release workflow branches on it, because its annotation
# panel is a surface the stderr diagnostic never reaches, so the wrong label
# there sends a maintainer hunting a path that does not exist. Every other caller
# reports both arms in one line and defers to the diagnostic printed immediately
# above it, which stays legible only for as long as a write failure never wears
# exit 1. So every arm below that is not the refusal exits 2 explicitly,
# including the ones a bare redirect would otherwise leave at 1.

set -u

usage() {
  printf 'usage: list-tracked-paths.sh <repo-dir> <output-file>\n' >&2
}

if [ "$#" -ne 2 ]; then
  usage
  exit 2
fi

repo_dir="$1"
out_file="$2"

if [ ! -d "$repo_dir" ]; then
  printf 'list-tracked-paths: not a directory: %s\n' "$repo_dir" >&2
  exit 2
fi

nul_stream="$(mktemp)" || exit 2
trap 'rm -f "$nul_stream"' EXIT

# Fail-closed on the discovery itself. Reading git's status is what the callers
# needed a `pipefail` subshell for while the conversion sat in a pipe behind it;
# there is no pipe here, so the status is git's own and the check is direct. An
# unnoticed failure is the expensive one: the list comes out empty, the exclude
# filter yields an empty include list, and rsync stages nothing while every
# check downstream passes having copied no files at all.
if ! git -C "$repo_dir" -c core.quotepath=false ls-files -z > "$nul_stream"; then
  printf 'list-tracked-paths: ls-files discovery failed in %s\n' "$repo_dir" >&2
  exit 2
fi

# `ls-files -z` separates records with NUL and emits no newline of its own, so
# every LF byte in the stream is inside a path. Counting the separators is an
# exact test for "is any path affected" and costs one pass; naming the
# offenders costs a bash loop, which only the failing path pays. The loop's own
# tally is what the message reports, never the byte count that triggered it: a
# path holding two newlines contributes two bytes and one path.
#
# The scan runs under `pipefail` because it is the fail-closed check this whole
# boundary exists to perform, and a pipeline hides its own failure: a `tr` that
# dies part way through a stream it has already partly read still leaves `wc`
# exiting 0 and printing a count, and a short count reads as zero the same way
# a genuinely clean tree does. A guard whose detection can fail open reports
# green in exactly the case it exists to catch.
if ! lf_bytes="$(set -o pipefail; LC_ALL=C tr -cd '\n' < "$nul_stream" | wc -c | tr -d ' \t\n')"; then
  printf 'list-tracked-paths: newline scan of the tracked set failed\n' >&2
  exit 2
fi

if [ "$lf_bytes" != "0" ]; then
  LF=$'\n'
  offenders=0
  rendered=""
  while IFS= read -r -d '' path; do
    case "$path" in
      *"$LF"*)
        offenders=$((offenders + 1))
        rendered="${rendered}    ${path//$LF/\\n}${LF}"
        ;;
    esac
  done < "$nul_stream"
  printf 'list-tracked-paths: refusing to stage; %d tracked path(s) hold a literal newline,\n' "$offenders" >&2
  printf '  which a newline-delimited file list cannot represent. Rename or untrack:\n' >&2
  printf '%s' "$rendered" >&2
  exit 1
fi

# Guarded rather than left as a bare redirect. A redirect bash cannot open makes
# it skip the command and leave status 1, which is the refusal code, so an
# unwritable directory or a full disk would reach every caller wearing the one
# label this boundary exists to make trustworthy.
if ! tr '\0' '\n' < "$nul_stream" > "$out_file"; then
  printf 'list-tracked-paths: could not write the tracked-path list to %s\n' "$out_file" >&2
  exit 2
fi
