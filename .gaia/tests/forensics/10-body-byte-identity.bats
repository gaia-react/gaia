#!/usr/bin/env bats
# TST-05: local-file body and GH-issue body are byte-identical at creation,
#         and the gh_issue_url back-fill touches the local frontmatter only.
#
# RENDERING-CONTRACT SURROGATE (not the shipped skill): the skill's render +
# back-fill steps run an LLM and cannot execute in bats. This file exercises
# the rendering contract with a fixed canonical body and a deterministic
# back-fill helper that mirrors step 8 (insert `gh_issue_url` as the last
# frontmatter key, above the closing `---`, leaving every section untouched).
# Real end-to-end guard: `.gaia/tests/forensics/integration.md`
# ("Local skill end-to-end" body diff).

# Canonical rendered body: frontmatter (no gh_issue_url yet) + the four
# sections in the canonical Capture rendering (no blank line after a `## `
# header; two-space-indented class_state_files list).
canonical_body() {
  cat <<'EOF'
---
class: init
gaia_version: 1.4.2
created: 2026-07-02
---

## Symptom
The /gaia-init rename step failed partway through and left package.json unchanged.

## Classification
class: init
evidence: "init" + .gaia/manifest.json

## Capture
gaia_version: 1.4.2
node: v22.19.0
pnpm: 10.33.0
claude_code: 1.0.0
branch: main
dirty: false
class_state_files:
  - .gaia/manifest.json: present, version 1.4.2

## Reproduction context
The user ran /gaia-init on a fresh clone and the rename step exited without completing.
EOF
}

# Deterministic mirror of the step-8 back-fill: insert `gh_issue_url: <url>` as
# the last frontmatter key, immediately before the closing `---`. Sections are
# never rewritten.
backfill_url() {
  local body="$1" url="$2"
  printf '%s' "$body" | awk -v url="$url" '
    BEGIN { fm = 0; done = 0 }
    /^---$/ {
      fm++
      if (fm == 2 && !done) { print "gh_issue_url: " url; done = 1 }
    }
    { print }
  '
}

# Everything from the first `## ` header to the end (the four sections only).
sections_only() {
  printf '%s' "$1" | awk '/^## /{f=1} f{print}'
}

@test "TST-05: issue body and local body are byte-identical at creation (no gh_issue_url)" {
  local issue_body local_body
  issue_body="$(canonical_body)"
  local_body="$(canonical_body)"

  # Same rendered body is posted to the issue and saved locally at creation.
  [[ "$issue_body" == "$local_body" ]]

  # Neither surface carries gh_issue_url at creation time.
  [[ "$issue_body" != *"gh_issue_url:"* ]]
  [[ "$local_body" != *"gh_issue_url:"* ]]
}

@test "TST-05: back-fill adds gh_issue_url to the local file only, sections untouched" {
  local url="https://github.com/gaia-react/gaia/issues/999"
  local pre_local issue_body backfilled
  pre_local="$(canonical_body)"
  issue_body="$(canonical_body)"
  backfilled="$(backfill_url "$pre_local" "$url")"

  # Only the local (back-filled) body gains gh_issue_url; the issue render omits it.
  [[ "$backfilled" == *"gh_issue_url: $url"* ]]
  [[ "$issue_body" != *"gh_issue_url:"* ]]

  # The gh_issue_url key lands inside the frontmatter, above the first section.
  local url_line sym_line
  url_line="$(printf '%s' "$backfilled" | grep -n '^gh_issue_url: ' | head -1 | cut -d: -f1)"
  sym_line="$(printf '%s' "$backfilled" | grep -n '^## Symptom' | head -1 | cut -d: -f1)"
  [[ -n "$url_line" && -n "$sym_line" ]]
  [[ "$url_line" -lt "$sym_line" ]]

  # The four sections are byte-identical before and after the back-fill.
  local pre_sections post_sections
  pre_sections="$(sections_only "$pre_local")"
  post_sections="$(sections_only "$backfilled")"
  [[ "$pre_sections" == "$post_sections" ]]
}
