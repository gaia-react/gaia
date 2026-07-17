#!/usr/bin/env bash
# audit-machinery.sh: the one machinery path list for the Code Audit Team.
# Sourced, never executed; does no work at source time.
#
# Generating rule: every file whose bytes can change what a member reviews,
# who reviews it, where a clearance lands, or whether a clearance is
# believed. Listing this set here is documentation of intent, not
# enforcement, a bad actor who can rewrite the working tree can rewrite this
# guard too, so treat AUDIT_MACHINERY_PATHS as a naming aid for the roster
# and for review, never as a security boundary on its own.
#
# Bats suites are DELIBERATELY EXCLUDED from this set: their bytes change
# none of the four things above (a `.bats` file does not decide who reviews
# what, or whether a clearance is honored). They are covered instead by the
# roster's own `.bats` globs, which dispatch a real member to review them.
#
# One literal list, no second copy anywhere. Entries ending in `/**` are
# directory prefixes (every tracked file under them is machinery); every
# other entry is an exact path.
#
# Bash 3.2 compatible (macOS default). Never `cd`.

AUDIT_MACHINERY_PATHS="$(cat <<'EOF'
.gaia/audit-ci.yml
.claude/hooks/lib/audit-scope.sh
.claude/hooks/lib/audit-machinery.sh
.claude/hooks/lib/audit-clearance.sh
.gaia/scripts/audit-write-clearance.sh
.gaia/scripts/audit-member-digest.sh
.gaia/scripts/audit-machinery-complete.sh
.claude/hooks/lib/audit-dispositions.sh
.gaia/scripts/resolve-audit-members.sh
.gaia/scripts/resolve-audit-spawn.sh
.claude/hooks/pr-merge-audit-check.sh
.claude/hooks/audit-disposition-check.sh
.claude/hooks/post-audit-status.sh
.claude/hooks/audit-stamp-trailer.sh
.claude/hooks/local-janitor.sh
.claude/hooks/block-selfheal-paths.sh
.claude/hooks/lib/**
.gaia/scripts/audit-noop-detect.sh
.gaia/scripts/link-worktree.sh
.gaia/scripts/read-audit-ci-config.sh
.github/audit/**
.github/workflows/code-review-audit.yml
.gaia/cli/templates/workflows/code-review-audit.yml.tmpl
.gaia/cli/src/automation/templates/workflows/code-review-audit.yml.tmpl
.claude/agents/code-audit-frontend.md
.claude/agents/code-audit-maintainer-shell.md
.claude/agents/code-audit-maintainer-node.md
.claude/agents/code-audit-github-workflows.md
.claude/rules/**
.gaia/VERSION
EOF
)"

# audit_path_is_machinery <path> -> exit 0 iff the path is in the set above.
audit_path_is_machinery() {
  local path="$1" entry prefix

  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    case "$entry" in
      *"/**")
        prefix="${entry%\*\*}"
        case "$path" in
          "$prefix"*) return 0 ;;
        esac
        ;;
      *)
        [ "$path" = "$entry" ] && return 0
        ;;
    esac
  done <<EOF
$AUDIT_MACHINERY_PATHS
EOF

  return 1
}

# audit_delta_has_machinery: BATCH, paths on stdin; exit 0 iff any path is
# machinery, printing the first hit on stdout.
audit_delta_has_machinery() {
  local path

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    if audit_path_is_machinery "$path"; then
      printf '%s\n' "$path"
      return 0
    fi
  done

  return 1
}

# audit_machinery_flags: BATCH classifier for a path list (directive PERF-002).
# Reads newline-delimited paths on stdin; prints "<path>\t<0|1>" per NON-EMPTY
# input line (1 = machinery). It parses the AUDIT_MACHINERY_PATHS heredoc into
# shell arrays ONCE, then tests each path against those arrays, so a caller
# classifying every tracked file does not re-read the heredoc once per path the
# way audit_path_is_machinery does. The membership semantics are byte-identical
# to audit_path_is_machinery (exact match, or a `/**` directory-prefix match);
# empty input lines are skipped, symmetric with audit_owners_for_paths, so the
# digest walk can align this output line-for-line with that classifier's.
audit_machinery_flags() {
  local entry path prefix hit i ne np
  local exact=() prefixes=()

  # Parse the heredoc ONCE into exact-path and directory-prefix arrays.
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    case "$entry" in
      *"/**") prefixes[${#prefixes[@]}]="${entry%\*\*}" ;;
      *)      exact[${#exact[@]}]="$entry" ;;
    esac
  done <<EOF
$AUDIT_MACHINERY_PATHS
EOF

  ne=${#exact[@]}
  np=${#prefixes[@]}

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    hit=0
    i=0
    while [ "$i" -lt "$ne" ]; do
      if [ "$path" = "${exact[$i]}" ]; then hit=1; break; fi
      i=$((i + 1))
    done
    if [ "$hit" -eq 0 ]; then
      i=0
      while [ "$i" -lt "$np" ]; do
        prefix="${prefixes[$i]}"
        case "$path" in
          "$prefix"*) hit=1; break ;;
        esac
        i=$((i + 1))
      done
    fi
    printf '%s\t%d\n' "$path" "$hit"
  done
}
