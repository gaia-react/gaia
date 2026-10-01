#!/usr/bin/env bats
# Order guard for `wiki/concepts/PR Merge Workflow.md`: the cross-repository
# (fork) check must come before every step that checks out the PR head and
# before every fenced command that runs a repo script.
#
# Why order and not presence. Every script the page tells an agent to run
# (`bash .gaia/...`, `bash .claude/...`, `.gaia/cli/gaia ...`) executes from the
# checked-out tree. A fork head that reached the working tree makes those
# scripts the fork's own code running with the operator's credentials, and no
# guard that runs afterwards can be trusted to refuse. The first step of the
# page is therefore the only control that acts in time, and it only acts when
# an agent reaches it before anything else. A page that carried the check but
# listed it below the first script fence would pass a presence test and still
# run fork code first.
#
# The order is read from the page's shell fences by line number of first
# occurrence: the first fenced line naming `isCrossRepository` against the
# fenced lines that check out a head or run a repo script. Prose lines are not
# read, because prose does not run.
#
# The checker is a function over a file, so the mutation tests below drive the
# same function against scratch copies of the page and prove it can fail:
# the check moved below the member-resolver fence, a head checkout inserted
# above it, and the check absent altogether.
#
# Assertion style: .claude/rules/bats-assertions.md. `.gaia/tests/` is
# release-excluded and out of wiki-style.md's scope.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  PAGE="${REPO_ROOT}/wiki/concepts/PR Merge Workflow.md"
  [ -f "$PAGE" ] || {
    echo "the audited page is absent: ${PAGE}" >&2
    return 1
  }
}

# Every tag that carries shell, the same set the fence suite reads.
FENCE_OPEN_RE='^```(bash|sh|shell)[[:space:]]*$'

# fenced_lines <file>: `<line-number><TAB><text>` for every line inside a shell
# fence, fence markers excluded.
fenced_lines() {
  awk -v re="$FENCE_OPEN_RE" '
    !inside && $0 ~ re { inside = 1; next }
    inside && /^```[[:space:]]*$/ { inside = 0; next }
    inside { printf "%d\t%s\n", NR, $0 }
  ' "$1"
}

# fence_block_of <file> <literal>: `<open-line> <close-line>` of the first shell
# fence whose body contains <literal>, or nothing.
fence_block_of() {
  awk -v re="$FENCE_OPEN_RE" -v pat="$2" '
    !inside && $0 ~ re { inside = 1; start = NR; hit = 0; next }
    inside && /^```[[:space:]]*$/ { if (hit) { print start, NR; exit } inside = 0; next }
    inside && index($0, pat) { hit = 1 }
  ' "$1"
}

# first_fork_check_line <file>: the line of the first FENCED line naming
# isCrossRepository, or nothing.
first_fork_check_line() {
  fenced_lines "$1" | awk -F'\t' 'index($2, "isCrossRepository") { print $1; exit }'
}

# gated_lines <file>: `<line-number><TAB><text>` for every fenced line that
# checks out a PR head or runs a repo script.
gated_lines() {
  fenced_lines "$1" | awk -F'\t' '
    $2 ~ /(^|[^[:alnum:]_.\/-])gh[[:space:]]+pr[[:space:]]+checkout([[:space:]]|$)/ { print; next }
    $2 ~ /(^|[^[:alnum:]_.\/-])git[[:space:]]+fetch[[:space:]].*pull\// { print; next }
    $2 ~ /(^|[^[:alnum:]_.\/-])git[[:space:]]+checkout([[:space:]]|$)/ { print; next }
    $2 ~ /(^|[^[:alnum:]_.\/-])bash[[:space:]]+\.(gaia|claude)\// { print; next }
    $2 ~ /(^|[^[:alnum:]_.\/-])\.gaia\/cli\/gaia([[:space:]]|$)/ { print; next }
  '
}

# order_violations <file>: prints one line per gated fenced line at or before
# the fork check, or a single line when the fork check is missing. Exit 0 when
# the order holds (nothing printed), 1 when it does not.
order_violations() {
  local file="$1" fork_line gated
  fork_line="$(first_fork_check_line "$file")"
  gated="$(gated_lines "$file")"
  if [ -z "$fork_line" ]; then
    echo "no fenced isCrossRepository check in ${file}"
    return 1
  fi
  if [ -z "$gated" ]; then
    echo "no gated fenced line found in ${file}: the guard would be vacuous"
    return 1
  fi
  local bad
  bad="$(awk -F'\t' -v fork="$fork_line" '$1 <= fork { print "line " $1 " precedes the fork check at " fork ": " $2 }' <<<"$gated")"
  if [ -n "$bad" ]; then
    printf '%s\n' "$bad"
    return 1
  fi
  return 0
}

@test "the fork check precedes every head checkout and every repo-script fence" {
  run order_violations "$PAGE"
  [ "$status" -eq 0 ] || {
    echo "$output" >&2
    return 1
  }
  [ -z "$output" ]
}

@test "the guard reads real gated lines: it sees the member resolver, the checkout and the cleanup" {
  gated="$(gated_lines "$PAGE")"
  grep -qF 'resolve-audit-members.sh' <<<"$gated" || return 1
  grep -qF 'git checkout main' <<<"$gated" || return 1
  grep -qF 'audit-noop-detect.sh' <<<"$gated" || return 1
  # The check sits in a shell fence, not only in prose.
  [ -n "$(first_fork_check_line "$PAGE")" ]
}

@test "the guard fails when the fork check is moved below the first resolve-audit-members.sh fence" {
  scratch="${BATS_TEST_TMPDIR}/moved-below.md"
  fork_block="$(fence_block_of "$PAGE" isCrossRepository)"
  resolver_block="$(fence_block_of "$PAGE" resolve-audit-members.sh)"
  [ -n "$fork_block" ] || return 1
  [ -n "$resolver_block" ] || return 1
  fork_start="${fork_block% *}"
  fork_end="${fork_block#* }"
  resolver_end="${resolver_block#* }"
  # The mutation is only a move if the check really starts above the resolver.
  [ "$fork_end" -lt "$resolver_end" ] || return 1
  {
    sed -n "1,$((fork_start - 1))p" "$PAGE"
    sed -n "$((fork_end + 1)),${resolver_end}p" "$PAGE"
    printf '\n'
    sed -n "${fork_start},${fork_end}p" "$PAGE"
    sed -n "$((resolver_end + 1)),\$p" "$PAGE"
  } >"$scratch"
  run order_violations "$scratch"
  [ "$status" -eq 1 ] || return 1
  grep -qF 'precedes the fork check' <<<"$output" || return 1
  grep -qF 'resolve-audit-members.sh' <<<"$output"
}

@test "the guard fails when a gh pr checkout line sits above the fork check" {
  scratch="${BATS_TEST_TMPDIR}/checkout-above.md"
  fork_block="$(fence_block_of "$PAGE" isCrossRepository)"
  [ -n "$fork_block" ] || return 1
  fork_start="${fork_block% *}"
  {
    sed -n "1,$((fork_start - 1))p" "$PAGE"
    # shellcheck disable=SC2016 # the backticks are literal fence markers
    printf '```bash\ngh pr checkout <N>\n```\n\n'
    sed -n "${fork_start},\$p" "$PAGE"
  } >"$scratch"
  run order_violations "$scratch"
  [ "$status" -eq 1 ] || return 1
  grep -qF 'gh pr checkout <N>' <<<"$output"
}

@test "the guard fails when a pull/<n>/head fetch sits above the fork check" {
  scratch="${BATS_TEST_TMPDIR}/fetch-above.md"
  fork_block="$(fence_block_of "$PAGE" isCrossRepository)"
  [ -n "$fork_block" ] || return 1
  fork_start="${fork_block% *}"
  {
    sed -n "1,$((fork_start - 1))p" "$PAGE"
    # shellcheck disable=SC2016 # the backticks are literal fence markers
    printf '```bash\ngit fetch origin pull/<N>/head\n```\n\n'
    sed -n "${fork_start},\$p" "$PAGE"
  } >"$scratch"
  run order_violations "$scratch"
  [ "$status" -eq 1 ] || return 1
  grep -qF 'pull/<N>/head' <<<"$output"
}

@test "the guard fails when the fork check is absent from the fences" {
  scratch="${BATS_TEST_TMPDIR}/no-check.md"
  fork_block="$(fence_block_of "$PAGE" isCrossRepository)"
  [ -n "$fork_block" ] || return 1
  fork_start="${fork_block% *}"
  fork_end="${fork_block#* }"
  {
    sed -n "1,$((fork_start - 1))p" "$PAGE"
    sed -n "$((fork_end + 1)),\$p" "$PAGE"
  } >"$scratch"
  run order_violations "$scratch"
  [ "$status" -eq 1 ] || return 1
  grep -qF 'no fenced isCrossRepository check' <<<"$output"
}

@test "a prose-only mention of the check does not satisfy the guard" {
  scratch="${BATS_TEST_TMPDIR}/prose-only.md"
  fork_block="$(fence_block_of "$PAGE" isCrossRepository)"
  [ -n "$fork_block" ] || return 1
  fork_start="${fork_block% *}"
  fork_end="${fork_block#* }"
  {
    sed -n "1,$((fork_start - 1))p" "$PAGE"
    printf 'Ask for isCrossRepository first.\n'
    sed -n "$((fork_end + 1)),\$p" "$PAGE"
  } >"$scratch"
  run order_violations "$scratch"
  [ "$status" -eq 1 ] || return 1
  grep -qF 'no fenced isCrossRepository check' <<<"$output"
}
