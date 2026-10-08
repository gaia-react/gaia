#!/usr/bin/env bash
#
# Ownership classifier for the /gaia-fitness heal phase
# (.claude/skills/gaia/references/fitness.md). The heal edits a file only when
# this script says the project owns it, so ownership is decided from the
# project's own records, never from a model's reading of the file.
#
# Usage:
#   bash .gaia/scripts/fitness-ownership.sh [--root <project-root>] <path>...
#
# A path is repo-relative or absolute, and may carry a finding's `:<line>`
# suffix. With no --root the project is the git top level of the working
# directory.
#
# stdout: one `<class>\t<path>` line per input path, in input order. The path
# is repo-relative for a path inside the project, and as given otherwise.
# Classes, first rule that matches wins:
#   third-party   outside the project tree (an absolute path elsewhere, such
#                 as a plugin's cached skill, or a path that climbs out with
#                 `..`), or under the target of a .gaia/vendor/*.json pin.
#                 A vendor pin wins over the manifest: the vendored tree is
#                 shipped by GAIA but written upstream.
#   ignored       gitignored: installed by a tool (a skill an installer drops
#                 in place) or kept per machine (.claude/settings.local.json).
#   gaia-shipped  `.gaia/manifest.json` itself, or a manifest entry of class
#                 `owned`.
#   adopter       everything else, including the manifest's `shared` and
#                 `wiki-owned` entries, which GAIA seeds and the project
#                 customizes.
#
# An absolute path is matched against --root as spelled, so a root given
# through a symlink and a path given through its target classify the path as
# outside: third-party, the class that is never edited.
#
# Exit 0: classified. Exit 2: usage error. Exit 3: an input could not be read
# (not a git work tree, jq missing, the manifest missing or without a `files`
# object, a vendor pin without a `target`). Both print nothing on stdout and
# one `fitness-ownership: <reason>` line on stderr. The caller heals nothing
# on a non-zero exit: a classifier that answered without its inputs would call
# vendored and GAIA-shipped files the project's own.

set -uo pipefail

fail_usage() {
  printf 'fitness-ownership: %s\n' "$1" >&2
  exit 2
}

fail_input() {
  printf 'fitness-ownership: %s\n' "$1" >&2
  exit 3
}

root=""
paths=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root)
      [ "$#" -ge 2 ] || fail_usage "--root needs a directory"
      root="$2"
      shift 2
      ;;
    --)
      shift
      while [ "$#" -gt 0 ]; do
        paths+=("$1")
        shift
      done
      ;;
    -*) fail_usage "unknown option: $1" ;;
    *)
      paths+=("$1")
      shift
      ;;
  esac
done
[ "${#paths[@]}" -gt 0 ] || fail_usage "usage: fitness-ownership.sh [--root <project-root>] <path>..."

command -v jq >/dev/null 2>&1 || fail_input "jq is required to read .gaia/manifest.json"

if [ -z "$root" ]; then
  root="$(git rev-parse --show-toplevel 2>/dev/null)" || fail_input "not inside a git work tree; pass --root"
fi
root="${root%/}"
[ "$(git -C "$root" rev-parse --is-inside-work-tree 2>/dev/null)" = "true" ] ||
  fail_input "$root is not a git work tree"

manifest="$root/.gaia/manifest.json"
jq -e '.files | type == "object"' "$manifest" >/dev/null 2>&1 ||
  fail_input "$manifest is missing or has no files object"

vendor_targets=()
for pin in "$root"/.gaia/vendor/*.json; do
  [ -e "$pin" ] || continue
  target="$(jq -r 'if (.target | type) == "string" then .target else empty end' "$pin" 2>/dev/null)"
  [ -n "$target" ] || fail_input "vendor pin ${pin#"$root"/} has no target"
  vendor_targets+=("${target%/}")
done

result=""
for given in ${paths[@]+"${paths[@]}"}; do
  path="$given"
  if [[ "$path" =~ ^(.+):[0-9]+$ ]]; then
    path="${BASH_REMATCH[1]}"
  fi
  case "$path" in
    "$root"/*) path="${path#"$root"/}" ;;
    /*)
      result+="third-party"$'\t'"$path"$'\n'
      continue
      ;;
  esac
  while [ "${path#./}" != "$path" ]; do
    path="${path#./}"
  done
  [ -n "$path" ] || fail_usage "empty path in: $given"

  case "/$path/" in
    */../*)
      result+="third-party"$'\t'"$path"$'\n'
      continue
      ;;
  esac

  class=""
  for target in ${vendor_targets[@]+"${vendor_targets[@]}"}; do
    case "$path" in
      "$target" | "$target"/*)
        class="third-party"
        break
        ;;
    esac
  done

  if [ -z "$class" ]; then
    git -C "$root" check-ignore -q -- "$path" 2>/dev/null
    case "$?" in
      0) class="ignored" ;;
      1) ;;
      *) fail_input "git check-ignore failed for $path" ;;
    esac
  fi

  if [ -z "$class" ]; then
    if [ "$path" = ".gaia/manifest.json" ]; then
      class="gaia-shipped"
    elif [ "$(jq -r --arg path "$path" '.files[$path] // empty' "$manifest")" = "owned" ]; then
      class="gaia-shipped"
    else
      class="adopter"
    fi
  fi
  result+="$class"$'\t'"$path"$'\n'
done

printf '%s' "$result"
