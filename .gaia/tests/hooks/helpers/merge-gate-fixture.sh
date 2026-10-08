#!/usr/bin/env bash
# Fixture for the merge-gate suites that assert on what the gate asks gh and
# what it posts: a sandbox repository modelling a pull request, and a gh stub
# that logs every invocation and answers from files.
#
# Source it from `setup()`, after `run-hook.sh`. Every function here is
# prefixed `mgf_`.
#
# The stub answers `pr view` from one record file whatever the arguments, and
# applies the caller's own `--jq` expression to it with the real jq, so the
# fork query, the merge gate's record read and post-audit-status.sh's head read
# all see one consistent pull request. `gh api` with `-X POST` succeeds and is
# only logged; any other `gh api` answers from the statuses file through the
# caller's `--jq`, as GitHub's list endpoint would.
#
# The directive below: `status` and `output` are set by bats' own `run`, which
# the linter cannot see in a `.sh` file.
# shellcheck disable=SC2154

# mgf_init: build REPO, a `feature` branch off a `main` base commit, with the
# member resolver and the libraries it loads copied in beside it (untracked,
# so they never appear in a diff under test), and install the gh stub.
mgf_init() {
  MGF_REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  MGF_HOOK="$MGF_REPO_ROOT/.claude/hooks/pr-merge-audit-check.sh"
  MGF_LIBRARY_DIRECTORY="$MGF_REPO_ROOT/.claude/hooks/lib"
  REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO/.gaia"

  # The stamp library prefers GITHUB_REPOSITORY over `gh repo view`, and a
  # GitHub Actions runner sets it to the real repository, which would route the
  # POST away from the stubbed test-owner/test-repo every assertion expects.
  unset GITHUB_REPOSITORY

  git -C "$REPO" init --quiet --initial-branch=main
  git -C "$REPO" config user.email "test@example.com"
  git -C "$REPO" config user.name "Test"
  git -C "$REPO" config commit.gpgsign false

  printf '1.4.0\n' > "$REPO/.gaia/VERSION"
  echo "# readme" > "$REPO/README.md"
  seed_audit_roster "$REPO"
  git -C "$REPO" add .gaia/VERSION .gaia/audit-ci.yml README.md
  git -C "$REPO" commit --quiet -m "init"
  git -C "$REPO" checkout --quiet -b feature

  mkdir -p "$REPO/.gaia/scripts" "$REPO/.claude/hooks/lib"
  cp "$MGF_REPO_ROOT/.gaia/scripts/resolve-audit-members.sh" "$REPO/.gaia/scripts/"
  chmod +x "$REPO/.gaia/scripts/resolve-audit-members.sh"
  local library_file
  for library_file in audit-scope.sh audit-machinery.sh audit-clearance.sh audit-digest.sh audit-base-provenance.sh; do
    cp "$MGF_LIBRARY_DIRECTORY/$library_file" "$REPO/.claude/hooks/lib/$library_file"
  done

  mgf_install_gh_stub
}

# mgf_install_gh_stub: the logging gh described in the header, first on PATH.
mgf_install_gh_stub() {
  MGF_STUB_DIRECTORY="$BATS_TEST_TMPDIR/gh-stub"
  MGF_GH_LOG="$MGF_STUB_DIRECTORY/gh.log"
  mkdir -p "$MGF_STUB_DIRECTORY/bin"
  : > "$MGF_GH_LOG"
  cat > "$MGF_STUB_DIRECTORY/bin/gh" <<EOF
#!/usr/bin/env bash
stub_directory="$MGF_STUB_DIRECTORY"
EOF
  cat >> "$MGF_STUB_DIRECTORY/bin/gh" <<'EOF'
printf '%s\n' "$*" >> "$stub_directory/gh.log"
jq_expression=''
previous=''
for argument in "$@"; do
  [ "$previous" != --jq ] || jq_expression="$argument"
  previous="$argument"
done
answer() {
  if [ -n "$jq_expression" ]; then
    printf '%s' "$1" | jq -r "$jq_expression"
  else
    printf '%s\n' "$1"
  fi
}
case "$1 ${2-}" in
  "auth "*) exit 0 ;;
  "repo view") answer '{"nameWithOwner":"test-owner/test-repo"}'; exit 0 ;;
  "pr view")
    if [ -f "$stub_directory/pr-view-fails" ]; then
      cat "$stub_directory/pr-view-fails" >&2
      exit 1
    fi
    # A numbered read answers from numbered-record.json when a case planted
    # one, modelling a head that moved after the unnumbered record read.
    if [[ "${3-}" =~ ^[0-9]+$ ]] && [ -f "$stub_directory/numbered-record.json" ]; then
      answer "$(cat "$stub_directory/numbered-record.json")"
      exit 0
    fi
    [ -f "$stub_directory/record.json" ] || { echo 'no pull requests found for branch "feature"' >&2; exit 1; }
    answer "$(cat "$stub_directory/record.json")"
    exit 0
    ;;
  "pr ready")
    # The draft flip after a posted status; a case plants ready-fails to make
    # it refuse.
    [ ! -f "$stub_directory/ready-fails" ] || exit 1
    exit 0
    ;;
  "api "*)
    case " $* " in
      *" -X POST "*) exit 0 ;;
    esac
    answer "$(cat "$stub_directory/statuses.json" 2>/dev/null || printf '[]')"
    exit 0
    ;;
esac
exit 1
EOF
  chmod +x "$MGF_STUB_DIRECTORY/bin/gh"
  export PATH="$MGF_STUB_DIRECTORY/bin:$PATH"
}

# mgf_commit <path> <content> [<path> <content>...]: one commit on the branch.
mgf_commit() {
  while [ "$#" -gt 0 ]; do
    mkdir -p "$REPO/$(dirname "$1")"
    printf '%s\n' "$2" > "$REPO/$1"
    git -C "$REPO" add "$1"
    shift 2
  done
  git -C "$REPO" commit --quiet -m "change"
}

# mgf_record <number> <is-cross-repository> <title> [<changed-path>...]: the
# pull request every `gh pr view` answers with, its head at the CURRENT local
# HEAD, so call it after the commits that make up the pull request.
mgf_record() {
  local number="$1" cross="$2" title="$3" head
  shift 3
  head="$(git -C "$REPO" rev-parse HEAD)"
  printf '%s\n' "$@" | jq -R -s -c \
    --argjson number "$number" --argjson is_cross_repository "$cross" --arg title "$title" --arg head_object_id "$head" \
    '{number: $number, isCrossRepository: $is_cross_repository, title: $title, baseRefName: "", headRefOid: $head_object_id,
      files: (split("\n") | map(select(length > 0)) | map({path: .}))}' \
    > "$MGF_STUB_DIRECTORY/record.json"
}

# mgf_member_digest <member>: the member's content digest for REPO's HEAD,
# through the real digest engine.
mgf_member_digest() {
  bash -c '. "$1"; audit_member_digest "$2" "$3"' _ "$MGF_LIBRARY_DIRECTORY/audit-digest.sh" "$REPO" "$1"
}

# mgf_marker <member>: write an earned clearance for <member> at REPO's HEAD,
# in the writer's schema-3 shape, and print its path.
mgf_marker() {
  local member="$1" digest sha tree infix sidecar path
  digest="$(mgf_member_digest "$member")"
  sha="$(git -C "$REPO" rev-parse HEAD)"
  tree="$(git -C "$REPO" rev-parse 'HEAD^{tree}')"
  if [ "$member" = code-audit-frontend ]; then infix=''; sidecar=true; else infix=".$member"; sidecar=false; fi
  path="$REPO/.gaia/local/audit/${digest}${infix}.ok"
  mkdir -p "$REPO/.gaia/local/audit"
  printf '{"version":"1.4.0","schema":3,"member":"%s","provenance":"earned","digest":"%s","tree":"%s","sha":"%s","audited_at":"2026-01-01T00:00:00Z","sidecar":%s}\n' \
    "$member" "$digest" "$tree" "$sha" "$sidecar" > "$path"
  printf '%s\n' "$path"
}

# mgf_status_success: make HEAD carry a GAIA-Audit success whose description
# the gate's commit-status signal accepts for the current frontend digest.
mgf_status_success() {
  local description
  description="1.4.0 $(mgf_member_digest code-audit-frontend) $(git -C "$REPO" rev-parse 'HEAD^{tree}')"
  jq -n -c --arg description "$description" '[{context: "GAIA-Audit", state: "success", description: $description}]' \
    > "$MGF_STUB_DIRECTORY/statuses.json"
}

# mgf_run_merge [command] [hook]: drive the gate from REPO with a Bash payload,
# stdout and stderr captured separately (needs bats >= 1.5.0).
mgf_run_merge() {
  local command="${1:-gh pr merge 12 --squash}" hook="${2:-$MGF_HOOK}" payload
  payload="$(jq -n -c --arg command "$command" '{tool_name: "Bash", tool_input: {command: $command}}')"
  # shellcheck disable=SC2016 # the inner bash expands its own positionals
  run --separate-stderr bash -c 'cd "$1" && printf %s "$2" | bash "$3"' _ "$REPO" "$payload" "$hook"
}

# mgf_post_lines: every status POST the stub saw, one per line. A POST is any
# call on `statuses/<sha>`: gh api posts when given `-f` fields, with or
# without `-X POST`, while the read the gate makes goes to
# `commits/<sha>/statuses`.
mgf_post_lines() {
  grep -E -- '(^| )repos/[^ ]+/statuses/[0-9a-f]{40}( |$)' "$MGF_GH_LOG" || true
}

# mgf_post_count: how many status POSTs the stub saw.
mgf_post_count() {
  mgf_post_lines | grep -c . || true
}

# mgf_scratch_hook <perl-substitution>: a copy of the gate with one source
# mutation applied, beside links to the real libraries and scripts it loads by
# its own location, so a mutant runs exactly as the real hook would. Prints the
# copy's path; fails when the substitution changed nothing.
mgf_scratch_hook() {
  local scratch="$BATS_TEST_TMPDIR/scratch-$RANDOM" copy
  mkdir -p "$scratch/.claude/hooks"
  ln -s "$MGF_LIBRARY_DIRECTORY" "$scratch/.claude/hooks/lib"
  ln -s "$MGF_REPO_ROOT/.gaia" "$scratch/.gaia"
  copy="$scratch/.claude/hooks/pr-merge-audit-check.sh"
  perl -0pe "$1" "$MGF_HOOK" > "$copy"
  if cmp -s "$copy" "$MGF_HOOK"; then
    printf 'mutation left the hook unchanged: %s\n' "$1" >&2
    return 1
  fi
  printf '%s\n' "$copy"
}
