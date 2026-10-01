#!/usr/bin/env bats

# Regression guard for the GAIA-Audit required-check registration across the
# setup recipes (.claude/commands/gaia-init.md and setup-gaia.md).
#
# The merge gate keys on the GAIA-Audit COMMIT STATUS, not the
# code-review-audit JOB NAME. The audit job reaches a green terminal step on
# every path (including a local-mode stand-down where no audit ran), so
# registering the job name as the required check would let an unaudited PR
# merge through the github.com button.
#
# Division of responsibility between the two recipes:
#   - setup-gaia.md REGISTERS the check: it owns the literal
#     `required_status_checks` PUT with `contexts[]=GAIA-Audit`, inside
#     Phase 3's admin-gated recommended defaults, right after the
#     default-branch protection PUT, for every admin with no other
#     precondition.
#   - gaia-init.md DELEGATES that registration to /setup-gaia rather than
#     inlining the command; it touches nothing on GitHub and must NOT carry
#     the PUT itself.
# Neither recipe may register the bare code-review-audit job name.
#
# The recipes are prose, so the testable surface is the literal command
# strings (setup-gaia) and the delegation references (gaia-init).
#
# This suite lives under .github/audit/tests/ because that is the directory
# the CI bats runner (audit-ci-tests.yml, check name "Audit CI Tests")
# executes.

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIR/../../.." && pwd )"
  GAIA_INIT="$REPO_ROOT/.claude/commands/gaia-init.md"
  SETUP_CI="$REPO_ROOT/.claude/commands/setup-gaia.md"
  [ -f "$GAIA_INIT" ] || skip "gaia-init.md not found"
  [ -f "$SETUP_CI" ] || skip "setup-gaia.md not found"
}

# -----------------------------------------------------------------------------
# gaia-init recipe delegates registration to /setup-gaia and inlines no
# registration command of its own.
# -----------------------------------------------------------------------------

@test "gaia-init delegates GAIA-Audit required-check registration to /setup-gaia" {
  run grep -F "/setup-gaia" "$GAIA_INIT"
  [ "$status" -eq 0 ]
  run grep -E "registers? the .GAIA-Audit. required check" "$GAIA_INIT"
  [ "$status" -eq 0 ]
}

@test "gaia-init does not inline the required_status_checks registration command" {
  run grep -F "protection/required_status_checks" "$GAIA_INIT"
  [ "$status" -ne 0 ]
}

@test "gaia-init does not register the bare code-review-audit job name as the required check" {
  run grep -F "contexts[]=code-review-audit" "$GAIA_INIT"
  [ "$status" -ne 0 ]
}

# -----------------------------------------------------------------------------
# setup-gaia recipe registers the GAIA-Audit status, not the job name, via
# the required_status_checks branch-protection endpoint.
# -----------------------------------------------------------------------------

@test "setup-gaia registers GAIA-Audit as the required check" {
  run grep -F "contexts[]=GAIA-Audit" "$SETUP_CI"
  [ "$status" -eq 0 ]
}

@test "setup-gaia registration targets the required_status_checks endpoint" {
  run grep -F "protection/required_status_checks" "$SETUP_CI"
  [ "$status" -eq 0 ]
}

@test "setup-gaia does not register the bare code-review-audit job name as the required check" {
  run grep -F "contexts[]=code-review-audit" "$SETUP_CI"
  [ "$status" -ne 0 ]
}

# -----------------------------------------------------------------------------
# setup-gaia registration placement: Phase 3, after the protection PUT, with
# no CI decision between the admin probe and the registration.
# -----------------------------------------------------------------------------

# phase3_section <file>: the lines under "## Phase 3:" up to the next "## ".
phase3_section() {
  awk '/^## /{inside = ($0 ~ /^## Phase 3:/)} inside' "$1"
}

# check_registration_placement <file>: every registration line sits in
# Phase 3, after the protection PUT, and the text from the admin probe to the
# registration names no CI decision.
check_registration_placement() {
  local file="$1" section in_file in_section between
  section="$(phase3_section "$file")"
  in_file="$(grep -cF 'contexts[]=GAIA-Audit' "$file" || true)"
  in_section="$(grep -cF 'contexts[]=GAIA-Audit' <<<"$section" || true)"
  [ "$in_section" -ge 1 ] || {
    echo "no registration inside Phase 3" >&2
    return 1
  }
  [ "$in_section" -eq "$in_file" ] || {
    echo "a registration sits outside Phase 3 (${in_section} of ${in_file} inside)" >&2
    return 1
  }
  awk '
    /branches\/<default-branch>\/protection" --input -/ && !protection { protection = NR }
    /contexts\[\]=GAIA-Audit/ && !registration { registration = NR }
    END { exit !(protection && registration && protection < registration) }
  ' <<<"$section" || {
    echo "the registration does not follow the protection PUT" >&2
    return 1
  }
  between="$(awk '
    /setup-ci check-admin/ { inside = 1 }
    /contexts\[\]=GAIA-Audit/ { inside = 0 }
    inside
  ' <<<"$section")"
  [ -n "$between" ] || {
    echo "no admin probe precedes the registration in Phase 3" >&2
    return 1
  }
  if grep -nE '(^|[^A-Za-z])CI([^A-Za-z]|$)|setup_complete|ci mode' <<<"$between"; then
    echo "a CI decision gates the registration" >&2
    return 1
  fi
}

@test "setup-gaia registers GAIA-Audit in Phase 3, after the protection PUT, with no CI precondition" {
  check_registration_placement "$SETUP_CI"
}

@test "the placement check fails when the registration moves out of Phase 3" {
  local copy="${BATS_TEST_TMPDIR}/moved.md"
  awk '/^#### Register GAIA-Audit as the required check/ { print "## Phase 3.4: Moved"; print "" } { print }' \
    "$SETUP_CI" >"$copy"
  grep -qF '## Phase 3.4: Moved' "$copy"
  run check_registration_placement "$copy"
  [ "$status" -ne 0 ]
}

@test "the placement check fails when a CI decision gates the registration" {
  local copy="${BATS_TEST_TMPDIR}/gated.md"
  awk '/^#### Register GAIA-Audit as the required check/ { print "Only when GAIA CI is enabled:"; print "" } { print }' \
    "$SETUP_CI" >"$copy"
  run check_registration_placement "$copy"
  [ "$status" -ne 0 ]
}

@test "the placement check fails when the protection PUT is gone" {
  local copy="${BATS_TEST_TMPDIR}/unprotected.md"
  grep -vF '/protection" --input -' "$SETUP_CI" >"$copy"
  run check_registration_placement "$copy"
  [ "$status" -ne 0 ]
}
