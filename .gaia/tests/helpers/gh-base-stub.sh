#!/usr/bin/env bash
# gh-base-stub.sh: a `gh` stand-in for bats suites that exercise the trusted-base
# resolution and the gates built on it. Sourced, never executed. Bash 3.2.
#
#   gh_base_stub_install <bin-directory>
#       Writes an executable `gh` into <bin-directory>; put that directory first
#       on PATH. The stub reads its answers from environment variables at call
#       time, so a test changes an answer by exporting a variable, not by
#       reinstalling.
#
# Answers (defaults in parentheses):
#   gh auth status                       exit 0 (exit 1 when GH_STUB_AUTH_FAIL is set)
#   gh repo view --json nameWithOwner    GH_STUB_REPOSITORY (owner/repo)
#   gh pr view ... --json ...            an object with baseRefName from
#                                        GH_STUB_BASE_BRANCH (main),
#                                        isCrossRepository false, isDraft false,
#                                        merged over by GH_STUB_PR_JSON (an object)
#   gh pr ready                          exit 0
#   gh api repos/R/branches/B            {"commit":{"sha":GH_STUB_BASE_TIP}}
#   gh api repos/R/commits/S/statuses    GH_STUB_STATUSES_JSON ([])
#   gh api repos/R/statuses/S            a status post when --method POST or -X
#                                        POST is given (--field or -f carry the body)
#   --jq / -q EXPR                       piped through the real jq, raw output
#
# Failure switches:
#   GH_STUB_FAIL           every call exits 1 with a message on stderr
#   GH_STUB_HANG           every call sleeps past any deadline
#   GH_STUB_FAIL_BRANCHES  only `gh api repos/*/branches/*` exits 1
#   GH_STUB_HANG_BRANCHES  only `gh api repos/*/branches/*` sleeps past any deadline
# The branches-only switches let a fixture fail the base lookup while the fork
# query and `gh auth status` still answer.
#
# Logging: GH_STUB_LOG names a file that receives one line per invocation, the
# argv joined by spaces. GH_STUB_PID_LOG names a file that receives
# "<stub pid> <sleeper pid>" when a hang switch fires, so a test can assert no
# process outlives the caller's deadline.

gh_base_stub_install() {
  local bin_directory="$1"
  mkdir -p "$bin_directory"
  cat > "$bin_directory/gh" <<'STUB_EOF'
#!/usr/bin/env bash
if [ -n "${GH_STUB_LOG:-}" ]; then
  printf '%s\n' "$*" >> "$GH_STUB_LOG"
fi

hang() {
  sleep 4242 &
  local sleeper=$!
  if [ -n "${GH_STUB_PID_LOG:-}" ]; then
    printf '%s %s\n' "$$" "$sleeper" >> "$GH_STUB_PID_LOG"
  fi
  wait "$sleeper"
  exit 1
}

fail() {
  printf 'gh stub: %s\n' "$1" >&2
  exit 1
}

if [ -n "${GH_STUB_HANG:-}" ]; then hang; fi
if [ -n "${GH_STUB_FAIL:-}" ]; then fail "forced failure"; fi

jq_expression=""
method="GET"
positional=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --jq | -q) jq_expression="${2:-}"; shift 2 ;;
    --method | -X) method="${2:-GET}"; shift 2 ;;
    --field | -f | -F | --raw-field | --json | --repo | -R | --hostname | --header | -H)
      shift 2
      ;;
    -*) shift ;;
    *) positional+=("$1"); shift ;;
  esac
done

emit() {
  if [ -n "$jq_expression" ]; then
    jq -r "$jq_expression"
  else
    cat
  fi
}

first="${positional[0]:-}"
second="${positional[1]:-}"

case "$first $second" in
  "auth status")
    if [ -n "${GH_STUB_AUTH_FAIL:-}" ]; then
      printf 'You are not logged into any GitHub hosts.\n' >&2
      exit 1
    fi
    exit 0
    ;;
  "repo view")
    jq -n --arg repository "${GH_STUB_REPOSITORY:-owner/repo}" '{nameWithOwner: $repository}' | emit
    exit 0
    ;;
  "pr view")
    extra_json="${GH_STUB_PR_JSON:-}"
    [ -n "$extra_json" ] || extra_json="{}"
    jq -n \
      --arg base "${GH_STUB_BASE_BRANCH:-main}" \
      --argjson extra "$extra_json" \
      '{baseRefName: $base, isCrossRepository: false, isDraft: false} + $extra' | emit
    exit 0
    ;;
  "pr ready")
    exit 0
    ;;
esac

if [ "$first" = "api" ]; then
  endpoint="$second"
  case "$endpoint" in
    repos/*/branches/*)
      if [ -n "${GH_STUB_HANG_BRANCHES:-}" ]; then hang; fi
      if [ -n "${GH_STUB_FAIL_BRANCHES:-}" ]; then fail "branches lookup failed"; fi
      jq -n --arg sha "${GH_STUB_BASE_TIP:-}" '{commit: {sha: $sha}}' | emit
      exit 0
      ;;
    repos/*/commits/*/statuses)
      printf '%s' "${GH_STUB_STATUSES_JSON:-[]}" | emit
      exit 0
      ;;
    repos/*/statuses/*)
      if [ "$method" = "POST" ]; then
        printf '{}' | emit
        exit 0
      fi
      fail "unexpected statuses read"
      ;;
  esac
fi

fail "unhandled call: $*"
STUB_EOF
  chmod +x "$bin_directory/gh"
}
