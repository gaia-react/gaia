#!/usr/bin/env bash
# Create a tmp git repo seeded for SPEC-ledger lib testing. Prints the repo
# path on stdout; the caller cd's into it. Modeled on
# .gaia/tests/hooks/helpers/tmp-git-repo.sh.
#
# Inside the tmp repo:
#   - git init (main), test identity, commit.gpgsign false
#   - .gaia/local/specs, .gaia/local/cache, .gaia/local/telemetry,
#     .gaia/scripts/spec, .gaia/scripts dirs
#   - a minimal valid ledger .gaia/local/specs/ledger.json: { "version": 1, "specs": [] }
#   - copies (NOT symlinks) of the scripts under test from the real repo so
#     ${BASH_SOURCE[0]}-relative sourcing inside the scripts resolves to the
#     tmp lib dir and finds the sibling with-ledger-lock.sh
#   - copies of ledger-path-lib.sh, main-root-lib.sh and branch-name-lib.sh
#     under .gaia/scripts, usage.sh with every library it sources (through
#     helpers/usage-gate.sh), and an empty .gaia/local/telemetry/usage.jsonl,
#     so the archive sweeps' usage-ledger gate resolves against this tmp repo,
#     not the real one. Tests append close rows with seed_close_row.
#   - one initial commit so require_git / rev-parse --git-dir succeeds
#
# Flags (repeatable, order-independent):
#   --seed-draft SPEC-NNN       append a ledger row status:"draft"
#   --seed-inprogress SPEC-NNN  append a ledger row status:"in-progress"
#   --seed-file SPEC-NNN        write .gaia/local/specs/SPEC-NNN.md with
#                               status: in-progress frontmatter and NO ledger
#                               row (the legacy fallback case)
#   --seed-folder SPEC-NNN      write the foldered shape
#                               .gaia/local/specs/SPEC-NNN/SPEC.md with
#                               status: in-progress frontmatter and NO ledger
#                               row (the foldered legacy fallback case)
#   --seed-merged SPEC-NNN      append a ledger row status:"merged" and NO
#                               folder (the archive-sweep skip-no-folder case)
#   --seed-merged-folder SPEC-NNN  append a ledger row status:"merged" AND
#                               write the foldered shape
#                               .gaia/local/specs/SPEC-NNN/SPEC.md with
#                               status: specified + immutable: true frontmatter,
#                               plus a consolidated SPEC-NNN/SUMMARY.md (the
#                               archive-sweep happy-path fixture: a merged row
#                               with an active, already-consolidated folder
#                               still to be swept). A test exercising the
#                               consolidation gate itself removes the seeded
#                               SUMMARY.md to simulate a folder consolidation
#                               never ran on.
#   --seed-provisional SPEC-NNN [subject]  append a ledger row
#                               status:"draft", reservation:"provisional",
#                               subject:<subject|id> (the offline-allocated row
#                               an online reconnect/reserve_pending resolves)
#   --seed-abandoned SPEC-NNN   append a ledger row status:"abandoned" and NO
#                               folder (the archive-sweep skip-no-folder case)
#   --seed-abandoned-folder SPEC-NNN  append a ledger row status:"abandoned"
#                               AND write the foldered shape
#                               .gaia/local/specs/SPEC-NNN/AUDIT.md (the
#                               archive-sweep happy-path fixture: an abandoned
#                               row with an active folder still to be swept;
#                               no SUMMARY.md/consolidation is ever expected)
#
# Remote flags (order-DEPENDENT: --with-origin must precede
# --seed-remote-tag / --origin-reject-spec-tags in the argument list; they
# run AFTER the initial commit, in the order given, since they need a
# pushed main branch to clone/push against):
#   --with-origin               after the initial commit, create a bare
#                               origin at the deterministic sibling path
#                               "<repo-path>.git" (derived, not randomized
#                               separately, so the caller retrieves it with
#                               no second return channel: origin="${REPO}.git"),
#                               `git remote add origin`, `git push -u origin
#                               main`.
#   --seed-remote-tag spec/NNN [subject]  push an annotated empty-tree
#                               reservation tag straight into the bare origin
#                               (create-push-delete the local ref; the local
#                               working repo's tag list stays empty) so a
#                               fresh clone's remote union sees it.
#   --origin-reject-spec-tags   install a git `update` hook in the bare
#                               origin that rejects any refs/tags/spec/* push
#                               (exit 1) while allowing everything else, and
#                               pin the bare origin's own core.hooksPath to
#                               its local hooks/ dir so a machine-wide global
#                               core.hooksPath override cannot silently
#                               bypass it (verified necessary on this repo).
#
# Second clone: use the companion helper
# helpers/clone-spec-repo.sh <origin-bare> to clone a --with-origin fixture;
# it inherits the libs as real files (not symlinks) via `git clone` since the
# origin's pushed commit already contains them.
set -euo pipefail

EMPTY_TREE="4b825dc642cb6eb9a060e54bf8d69288fbee4904"

# Real repo containing this helper: the helper lives at
# .gaia/tests/lib/helpers/ inside the real repo working tree.
_helper_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
real_repo="$(git -C "$_helper_directory" rev-parse --show-toplevel)"
real_library_directory="${real_repo}/.gaia/scripts/spec"
real_scripts="${real_repo}/.gaia/scripts"

repository_directory="$(mktemp -d -t gaia-spec-lib-test-XXXXXX)"
cd "$repository_directory"

git init --quiet --initial-branch=main
git config user.email "test@example.com"
git config user.name "Test"
git config commit.gpgsign false

mkdir -p .gaia/local/specs .gaia/local/cache .gaia/local/telemetry \
  .gaia/scripts/spec .gaia/scripts

printf '{\n  "version": 1,\n  "specs": []\n}\n' > .gaia/local/specs/ledger.json

# Copy (not symlink) so the scripts' ${BASH_SOURCE[0]}-relative source of
# with-ledger-lock.sh resolves to this tmp lib dir.
for library_name in spec-allocator.sh plan-allocator.sh ledger-update.sh ledger-lib.sh with-ledger-lock.sh \
         spec-renumber.sh spec-reconcile.sh \
         spec-archive-merged.sh spec-archive-abandoned.sh title-normalize.sh; do
  cp "${real_library_directory}/${library_name}" ".gaia/scripts/spec/${library_name}"
  chmod +x ".gaia/scripts/spec/${library_name}"
done

# Copy the ledger-path resolver and the usage gate so the archive sweeps'
# gate resolves against this tmp repo's own git identity and usage ledger
# instead of the real repo's. ledger-path-lib.sh sources its own sibling
# main-root-lib.sh by on-disk location, so that sibling is copied alongside it
# too. branch-name-lib.sh is what the SPEC allocator, renumber, and reconcile
# read branch names through.
for script_name in ledger-path-lib.sh main-root-lib.sh branch-name-lib.sh; do
  cp "${real_scripts}/${script_name}" ".gaia/scripts/${script_name}"
  chmod +x ".gaia/scripts/${script_name}"
done
# shellcheck source=usage-gate.sh
. "${_helper_directory}/usage-gate.sh"
copy_usage_gate "$real_repo" "$repository_directory"

# Empty usage ledger so the gate reads; individual tests append close rows
# with seed_close_row, or remove the file to exercise the unreadable form.
: > .gaia/local/telemetry/usage.jsonl

# Remote (--with-origin / --seed-remote-tag / --origin-reject-spec-tags) ops
# are stashed here, in argument order, and executed AFTER the initial commit
# below (they need a pushed main branch to clone/push against). Each entry is
# "type<UNIT_SEPARATOR>arg1<UNIT_SEPARATOR>arg2" using the UNIT_SEPARATOR ($'\x1f') delimiter so a flat array can
# carry variable-arity ops without nested-array support.
remote_ops=()
UNIT_SEPARATOR=$'\x1f'

# Apply seed flags before the initial commit so the seeded state is committed
# (require_git only needs a git-dir; committing keeps the tree clean).
while [[ $# -gt 0 ]]; do
  case "$1" in
    --seed-draft)
      id="$2"; shift 2
      temporary_file="$(mktemp)"
      jq --arg id "$id" \
        '.specs += [{id: $id, allocated_at: "2026-01-01T00:00:00Z", source: "allocated", status: "draft"}]' \
        .gaia/local/specs/ledger.json > "$temporary_file"
      mv "$temporary_file" .gaia/local/specs/ledger.json
      ;;
    --seed-inprogress)
      id="$2"; shift 2
      temporary_file="$(mktemp)"
      jq --arg id "$id" \
        '.specs += [{id: $id, allocated_at: "2026-01-01T00:00:00Z", source: "allocated", status: "in-progress"}]' \
        .gaia/local/specs/ledger.json > "$temporary_file"
      mv "$temporary_file" .gaia/local/specs/ledger.json
      ;;
    --seed-file)
      id="$2"; shift 2
      cat > ".gaia/local/specs/${id}.md" <<EOF
---
spec_id: ${id}
status: in-progress
---

# ${id}
EOF
      ;;
    --seed-folder)
      id="$2"; shift 2
      mkdir -p ".gaia/local/specs/${id}"
      cat > ".gaia/local/specs/${id}/SPEC.md" <<EOF
---
spec_id: ${id}
status: in-progress
---

# ${id}
EOF
      ;;
    --seed-merged)
      id="$2"; shift 2
      temporary_file="$(mktemp)"
      jq --arg id "$id" \
        '.specs += [{id: $id, allocated_at: "2026-01-01T00:00:00Z", source: "allocated", status: "merged", merged_at: "2026-01-02T00:00:00Z"}]' \
        .gaia/local/specs/ledger.json > "$temporary_file"
      mv "$temporary_file" .gaia/local/specs/ledger.json
      ;;
    --seed-merged-folder)
      id="$2"; shift 2
      temporary_file="$(mktemp)"
      jq --arg id "$id" \
        '.specs += [{id: $id, allocated_at: "2026-01-01T00:00:00Z", source: "allocated", status: "merged", merged_at: "2026-01-02T00:00:00Z"}]' \
        .gaia/local/specs/ledger.json > "$temporary_file"
      mv "$temporary_file" .gaia/local/specs/ledger.json
      mkdir -p ".gaia/local/specs/${id}"
      cat > ".gaia/local/specs/${id}/SPEC.md" <<EOF
---
spec_id: ${id}
status: specified
immutable: true
---

# ${id}
EOF
      cat > ".gaia/local/specs/${id}/SUMMARY.md" <<EOF
---
wiki_promote_default: ask
wiki_promote_targets: []
---
# ${id}

Consolidated summary body.
EOF
      ;;
    --seed-abandoned)
      id="$2"; shift 2
      temporary_file="$(mktemp)"
      jq --arg id "$id" \
        '.specs += [{id: $id, allocated_at: "2026-01-01T00:00:00Z", source: "allocated", status: "abandoned", abandoned_at: "2026-01-02T00:00:00Z"}]' \
        .gaia/local/specs/ledger.json > "$temporary_file"
      mv "$temporary_file" .gaia/local/specs/ledger.json
      ;;
    --seed-abandoned-folder)
      id="$2"; shift 2
      temporary_file="$(mktemp)"
      jq --arg id "$id" \
        '.specs += [{id: $id, allocated_at: "2026-01-01T00:00:00Z", source: "allocated", status: "abandoned", abandoned_at: "2026-01-02T00:00:00Z"}]' \
        .gaia/local/specs/ledger.json > "$temporary_file"
      mv "$temporary_file" .gaia/local/specs/ledger.json
      mkdir -p ".gaia/local/specs/${id}"
      cat > ".gaia/local/specs/${id}/AUDIT.md" <<EOF
# ${id} Adversarial Audit

Verdict body.
EOF
      ;;
    --seed-provisional)
      id="$2"; shift 2
      subject="$id"
      if [[ $# -gt 0 && "$1" != --* ]]; then
        subject="$1"; shift
      fi
      temporary_file="$(mktemp)"
      jq --arg id "$id" --arg subject "$subject" \
        '.specs += [{id: $id, allocated_at: "2026-01-01T00:00:00Z", source: "allocated", status: "draft", reservation: "provisional", subject: $subject}]' \
        .gaia/local/specs/ledger.json > "$temporary_file"
      mv "$temporary_file" .gaia/local/specs/ledger.json
      ;;
    --with-origin)
      remote_ops+=("with-origin${UNIT_SEPARATOR}${UNIT_SEPARATOR}")
      shift
      ;;
    --seed-remote-tag)
      tag="$2"; shift 2
      subject="$tag"
      if [[ $# -gt 0 && "$1" != --* ]]; then
        subject="$1"; shift
      fi
      remote_ops+=("seed-remote-tag${UNIT_SEPARATOR}${tag}${UNIT_SEPARATOR}${subject}")
      ;;
    --origin-reject-spec-tags)
      remote_ops+=("origin-reject-spec-tags${UNIT_SEPARATOR}${UNIT_SEPARATOR}")
      shift
      ;;
    *)
      echo "tmp-spec-repo.sh: unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

git add -A
git commit --quiet -m "init"

# Execute stashed remote ops, in argument order, now that main has a commit
# to push. None of these touch the work-tree's tracked files, so no follow-up
# commit is needed.
origin_directory=""
for remote_operation in ${remote_ops[@]+"${remote_ops[@]}"}; do
  IFS="$UNIT_SEPARATOR" read -r operation_type operation_first_argument operation_second_argument <<< "$remote_operation"
  case "$operation_type" in
    with-origin)
      origin_directory="${repository_directory}.git"
      git init --quiet --bare --initial-branch=main "$origin_directory"
      git remote add origin "$origin_directory"
      git push --quiet -u origin main
      ;;
    seed-remote-tag)
      if [ -z "$origin_directory" ]; then
        echo "tmp-spec-repo.sh: --seed-remote-tag requires --with-origin earlier in the argument list" >&2
        exit 1
      fi
      git tag -a "$operation_first_argument" "$EMPTY_TREE" -m "$operation_second_argument"
      git push --quiet origin "refs/tags/$operation_first_argument"
      git tag -d "$operation_first_argument" >/dev/null
      ;;
    origin-reject-spec-tags)
      if [ -z "$origin_directory" ]; then
        echo "tmp-spec-repo.sh: --origin-reject-spec-tags requires --with-origin earlier in the argument list" >&2
        exit 1
      fi
      # This machine's global core.hooksPath (~/.gitconfig) overrides every
      # repo's local hooks/ dir; pin the bare origin's own hooksPath back to
      # its local hooks/ so the reject hook actually fires instead of being
      # silently skipped.
      git -C "$origin_directory" config core.hooksPath "$origin_directory/hooks"
      mkdir -p "$origin_directory/hooks"
      cat > "$origin_directory/hooks/update" <<'HOOK'
#!/bin/sh
# update <refname> <old-sha> <new-sha>; reject any spec/* tag reservation,
# allow everything else (including the initial main push).
case "$1" in
  refs/tags/spec/*)
    echo "reject: refs/tags/spec/* namespace is protected" >&2
    exit 1
    ;;
esac
exit 0
HOOK
      chmod +x "$origin_directory/hooks/update"
      ;;
  esac
done

echo "$repository_directory"
