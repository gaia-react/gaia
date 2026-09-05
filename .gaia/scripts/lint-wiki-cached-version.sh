#!/usr/bin/env bash
# shellcheck shell=bash
#
# lint-wiki-cached-version.sh: flag a `version:` field in the frontmatter of any
# tracked wiki page. Exit 0 when no page carries one, 1 with a file:line report
# on any hit, 2 on the check's own failure. Run it from anywhere:
# `bash .gaia/scripts/lint-wiki-cached-version.sh [<repo_root>]`.
# gaia:maintainer-only:start
#
# Enforced by the sibling bats suite
# .gaia/scripts/tests/lint-wiki-cached-version.bats, which the `Audit CI Tests`
# scripts shard runs, and folded into .gaia/tests/shell-lint.sh, whose `**/*.md`
# paths-filter entry is what arms it on the surface it reads.
# gaia:maintainer-only:end
#
# Why: the field is a hand-kept copy of a number `package.json` already holds,
# and nothing invalidates it. When the whole surface was measured against
# `package.json`, most of the pages carrying the field disagreed with it, which
# is the ordinary end state of a cache with no invalidation rather than a lapse
# in care. A reader cannot tell a fresh copy from a stale one without going to
# `package.json`, which is the trip the field existed to save, so the field
# earns nothing even while it is right.
#
# The page's own `package:` field names the package. That is the pointer, and
# `package.json` is the answer.
#
# FORBIDDEN, not synced, and the distinction is the whole design. A check that
# compared the field against `package.json` would be a second cache: it would
# have to know which `package.json` entry each page means, carry that mapping by
# hand, and go stale in the mapping instead of in the number. It also could not
# speak at all for the pages naming a version of something `package.json` does
# not hold, which is where a stale figure is least visible. Forbidding the field
# needs no mapping, covers every page identically, and cannot itself rot.
#
# Fail-closed by construction, at each stage guards-must-fail.md names:
#   discovery -- git unavailable, or no tracked wiki markdown at all, exits 2
#   arming    -- a wiki directory that is absent exits 2, never 0
#   match     -- the field test reads the frontmatter block only, delimited by
#                the leading `---` fence, so the same word inside body prose or
#                a fenced sample is not a hit
#
# Bash 3.2 compatible. Never `cd`.

set -uo pipefail

readonly PROG="lint-wiki-cached-version"

# The one forbidden frontmatter field, named once.
readonly FORBIDDEN_FIELD="version"

# frontmatter_field_line <file>
#
# Print `<line-number>:<text>` for the forbidden field inside the file's leading
# frontmatter block, or nothing. The block is the region between the first line
# (which must be exactly `---`) and the next `---` line. A file with no leading
# fence has no frontmatter and yields nothing.
frontmatter_field_line() {
  awk -v field="$FORBIDDEN_FIELD" '
    NR == 1 { if ($0 != "---") exit 0; inblock = 1; next }
    inblock && $0 == "---" { exit 0 }
    inblock && index($0, field ":") == 1 { printf "%d:%s\n", NR, $0; exit 0 }
  ' "$1"
}

main() {
  local root
  if [ "$#" -gt 1 ]; then
    printf '%s: too many arguments\n' "$PROG" >&2
    printf 'usage: bash .gaia/scripts/%s.sh [<repo_root>]\n' "$PROG" >&2
    return 2
  fi
  if [ "$#" -eq 1 ]; then
    root="$1"
    if [ ! -d "$root" ]; then
      printf '%s: not a directory: %s\n' "$PROG" "$root" >&2
      return 2
    fi
  else
    root="$(git rev-parse --show-toplevel 2>/dev/null)" || root=''
    if [ -z "$root" ]; then
      printf '%s: not inside a git repository and no <repo_root> given\n' "$PROG" >&2
      return 2
    fi
  fi

  # Arming. An absent wiki tree is a moved or deleted directory, not a clean
  # one: reporting clean over it would be the fail-open this gate exists inside.
  if [ ! -d "$root/wiki" ]; then
    printf '%s: wiki directory not found under %s\n' "$PROG" "$root" >&2
    return 2
  fi

  # Discovery over tracked files, so an untracked scratch page under wiki/ is
  # not graded and a page git knows about cannot be missed. NUL-delimited: a
  # page whose name carries a non-ASCII byte is C-quoted by a newline-delimited
  # listing, and the quoted form is not the path the consumer then opens.
  local file hit findings=0 seen=0
  while IFS= read -r -d '' file; do
    seen=$((seen + 1))
    [ -f "$root/$file" ] || continue
    hit="$(frontmatter_field_line "$root/$file")"
    [ -n "$hit" ] || continue
    if [ "$findings" -eq 0 ]; then
      printf '%s: wiki pages caching a version in frontmatter:\n' "$PROG" >&2
    fi
    printf '  %s:%s\n' "$file" "$hit" >&2
    findings=$((findings + 1))
  done < <(git -C "$root" ls-files -z -- 'wiki/*.md' 'wiki/**/*.md' 2>/dev/null)

  # Checked after the sweep rather than before it, because the NUL-delimited
  # listing is consumed by the loop itself; `seen` is what the pre-sweep
  # emptiness test would have asked, and nothing is reported when it is zero.
  if [ "$seen" -eq 0 ]; then
    printf '%s: discovery found no tracked markdown under wiki/ in %s.\n' "$PROG" "$root" >&2
    printf 'This tree carries dozens of wiki pages, so an empty set is a broken discovery\n' >&2
    printf 'rather than a clean surface; it would otherwise report every page compliant\n' >&2
    printf 'having read none of them.\n' >&2
    return 2
  fi

  if [ "$findings" -gt 0 ]; then
    printf '\n%s: %d page(s) above carry a %s: frontmatter field.\n' \
      "$PROG" "$findings" "$FORBIDDEN_FIELD" >&2
    printf 'Delete the line. The number is a hand-kept copy of one package.json already holds,\n' >&2
    printf 'nothing invalidates it, and the page already names its package in frontmatter, which\n' >&2
    printf 'is the pointer a reader needs. Do not substitute a corrected number; a fresher cache\n' >&2
    printf 'rots the same way.\n' >&2
    return 1
  fi
  printf '%s: clean\n' "$PROG"
  return 0
}

main "$@"
