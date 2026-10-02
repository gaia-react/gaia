#!/usr/bin/env bash
# parse-issue-body.sh: deterministic parser for the forensics issue
# body. Emits JSON to stdout.
#
# Exit code: 0 always (consumers inspect the JSON `valid` field). Exit 2
# is reserved for genuine script errors (missing input file, bad usage).
#
# POSIX-tools only: awk, sed, grep, bash. No jq, no yq, no python.
#
# Body schema:
#   - Four `##` section headers, in any order, exactly matching:
#     `## Symptom`, `## Classification`, `## Capture`, `## Reproduction context`.
#   - Each section non-empty.
#   - The `## Classification` section content includes a `class: <tag>` line.
#     The parser checks this `class` value is present and non-empty (deriving
#     it from `## Classification` when frontmatter is absent); it does NOT
#     enforce membership in the eight forensics taxonomy classes
#     (`init|update|wiki-sync|quality-gate|hook|scaffold|dev-server|other`).
#     The workflow's fix-branch slug sanitization bounds the value downstream.
#
# The body leads with a YAML frontmatter block (`---` … `---`) that
# supplies `class`, `gaia_version`, `created`, and (after back-fill)
# `gh_issue_url`. The GitHub-issue body is byte-identical to the local
# file body, so it ships WITH this frontmatter. As defense-in-depth the
# parser stays tolerant of an absent block: when frontmatter is missing
# it derives `class` from the `## Classification` section content and
# still emits the same JSON shape with empty / null values for any
# frontmatter-only field.

set -uo pipefail

usage() {
  echo "usage: parse-issue-body.sh <input-file>" >&2
  exit 2
}

# emit_internal_error <stage> <exit-code>
# Emits the internal-error JSON envelope on stdout. Used by the
# per-awk exit-code checks: when an awk pipeline returns non-zero, the
# consumer needs a deterministic signal distinguishing "infrastructure
# failure" from "valid:false / verdict:ambiguous". The script's overall
# exit code remains 0 (consumers parse JSON; exit 2 is reserved for
# usage errors).
emit_internal_error() {
  printf '{"internal_error":true,"stage":"%s","exit_code":%d}\n' "$1" "$2"
  exit 0
}

[ "$#" -eq 1 ] || usage
input_file="$1"
[ -f "$input_file" ] || { echo "parse-issue-body.sh: input file not found: $input_file" >&2; exit 2; }

# ---------------------------------------------------------------------------
# Working-area: a private temp dir holding one file per section. Avoids
# fragile in-memory section-splitting via shell sentinels.
# ---------------------------------------------------------------------------

work_directory=$(mktemp -d 2>/dev/null) || { echo "parse-issue-body.sh: mktemp failed" >&2; exit 2; }
trap 'rm -rf "$work_directory"' EXIT

# ---------------------------------------------------------------------------
# Step 1: opportunistically extract a YAML frontmatter block. The issue
# body ships WITH frontmatter (byte-identical to the local file body).
# As defense-in-depth the parser stays tolerant of an absent block,
# deriving `class` from `## Classification` when missing. The local file
# shape (saved at `.gaia/local/forensics/<tree_key>/<timestamp>-<class>.md`,
# `<tree_key>` identifying the working tree that saved it, printed by
# `bash .gaia/scripts/main-root-lib.sh --tree-key`) keeps the frontmatter, so
# the parser still picks up its values when present.
# ---------------------------------------------------------------------------

frontmatter_class=""
frontmatter_gaia_version=""
frontmatter_created=""
frontmatter_gh_issue_url=""
body_start=1

first_line=$(awk 'NR==1{print; exit}' "$input_file")
awk_status=$?
[ "$awk_status" -ne 0 ] && emit_internal_error "frontmatter-extract" "$awk_status"

if [ "$first_line" = "---" ]; then
  # Closing `---` line number (must be > 1, exact match). A frontmatter
  # open without a matching close is still malformed, emit the same
  # error as before so a hand-edited local file with a typo doesn't
  # silently drop frontmatter values.
  frontmatter_closing_line=$(awk 'NR>1 && $0=="---"{print NR; exit}' "$input_file")
  awk_status=$?
  [ "$awk_status" -ne 0 ] && emit_internal_error "frontmatter-extract" "$awk_status"
  if [ -z "${frontmatter_closing_line:-}" ]; then
    printf '{"valid":false,"error":"malformed-frontmatter","missing":[],"malformed":["frontmatter"]}\n'
    exit 0
  fi

  awk -v end="$frontmatter_closing_line" 'NR>1 && NR<end' "$input_file" > "$work_directory/frontmatter.txt"
  awk_status=$?
  [ "$awk_status" -ne 0 ] && emit_internal_error "frontmatter-extract" "$awk_status"

  # YAML-shaped key/value pairs. Accept `key: value` lines (first `: `
  # splits). Strip surrounding single or double quotes from value.
  while IFS= read -r line; do
    case "$line" in
      ''|'#'*) continue ;;
    esac
    key=$(printf '%s' "$line" | awk -F': ' '{print $1}')
    value=$(printf '%s' "$line" | sed -n 's/^[^:]*:[[:space:]]*//p')
    case "$value" in
      \"*\") value=$(printf '%s' "$value" | sed -e 's/^"//' -e 's/"$//') ;;
      \'*\') value=$(printf '%s' "$value" | sed -e "s/^'//" -e "s/'$//") ;;
    esac
    case "$key" in
      class) frontmatter_class="$value" ;;
      gaia_version) frontmatter_gaia_version="$value" ;;
      created) frontmatter_created="$value" ;;
      gh_issue_url) frontmatter_gh_issue_url="$value" ;;
    esac
  done < "$work_directory/frontmatter.txt"

  body_start=$((frontmatter_closing_line + 1))
fi

# ---------------------------------------------------------------------------
# Step 2: split the body into per-section files. The parser is
# fence-aware and matches ONLY the four exact canonical headers.
# ---------------------------------------------------------------------------

# Single awk pass, routing lines into per-section files.
#
# Fence-awareness: a line beginning with ``` toggles fenced-code state.
# Inside a fence every line - including a `## ` line - is section
# content, never a header (the fence line itself is content too). This
# keeps pasted stack traces, compiler output, or quoted markdown from
# hijacking the section split (RT-02).
#
# Header semantics (outside a fence):
#   - A line that EXACTLY equals one of the four canonical headers
#     (`## Symptom`, `## Classification`, `## Capture`,
#     `## Reproduction context`) starts that section.
#   - The same canonical header seen a second time is a DUPLICATE: it is
#     recorded to a sentinel file and rejected downstream (RT-03) rather
#     than silently re-dispatching and corrupting the body.
#   - ANY other `## ` line is treated as content of the current section,
#     NEVER as a malformed header. There is deliberately no
#     malformed-section-header path: a non-canonical `## ` line is always
#     content, so legitimate reports quoting `## Foo` parse (RT-02).
#
# A section ends at the next canonical header or EOF. Lines before the
# first canonical header are dropped (the schema places the four
# sections back-to-back; nothing precedes them).
awk -v start="$body_start" -v output_directory="$work_directory" '
  function flush() {
    if (current_section_name != "" && output_path != "") {
      print buffered_text > output_path
      close(output_path)
    }
    current_section_name = ""
    buffered_text = ""
    output_path = ""
  }
  function buffer(line) {
    if (current_section_name != "") {
      if (buffered_text == "") buffered_text = line
      else buffered_text = buffered_text "\n" line
    }
  }
  BEGIN {
    current_section_name = ""
    buffered_text = ""
    output_path = ""
    in_fence = 0
    seen_symptom = 0
    seen_classification = 0
    seen_capture = 0
    seen_reproduction = 0
  }
  NR < start { next }
  # Fenced-code toggle. The fence line is content of the current section.
  /^```/ {
    in_fence = !in_fence
    buffer($0)
    next
  }
  # Exact canonical headers (outside a fence) drive the section split.
  !in_fence && /^## / {
    name = substr($0, 4)
    if (name == "Symptom" || name == "Classification" || name == "Capture" || name == "Reproduction context") {
      is_duplicate = 0
      if (name == "Symptom")                   { if (seen_symptom)        is_duplicate = 1; else seen_symptom = 1 }
      else if (name == "Classification")       { if (seen_classification) is_duplicate = 1; else seen_classification = 1 }
      else if (name == "Capture")              { if (seen_capture)        is_duplicate = 1; else seen_capture = 1 }
      else if (name == "Reproduction context") { if (seen_reproduction)   is_duplicate = 1; else seen_reproduction = 1 }
      if (is_duplicate) {
        # Record the first duplicate canonical header (later ones
        # ignored). Do not start a new section; the body is rejected.
        duplicate_path = output_directory "/duplicate-header.txt"
        command = "test -f \"" duplicate_path "\""
        if (system(command) != 0) {
          print name > duplicate_path
          close(duplicate_path)
        }
        next
      }
      flush()
      if (name == "Symptom")                   { current_section_name = name; output_path = output_directory "/sec-symptom.txt" }
      else if (name == "Classification")       { current_section_name = name; output_path = output_directory "/sec-classification.txt" }
      else if (name == "Capture")              { current_section_name = name; output_path = output_directory "/sec-capture.txt" }
      else                                     { current_section_name = name; output_path = output_directory "/sec-reproduction.txt" }
      next
    }
    # Non-canonical `## ` line: content, not a header (RT-02).
    buffer($0)
    next
  }
  {
    buffer($0)
  }
  END {
    flush()
  }
' "$input_file"
awk_status=$?
[ "$awk_status" -ne 0 ] && emit_internal_error "section-split" "$awk_status"

# ---------------------------------------------------------------------------
# Step 3: failure-mode resolution. Order:
#   1. duplicate-section-header
#   2. missing-section
#   3. empty-section
# ---------------------------------------------------------------------------

if [ -f "$work_directory/duplicate-header.txt" ]; then
  duplicate_header=$(cat "$work_directory/duplicate-header.txt")
  escaped_header=$(printf '%s' "$duplicate_header" | awk '
    {
      gsub(/\\/, "\\\\")
      gsub(/"/, "\\\"")
      gsub(/\t/, "\\t")
      printf "%s", $0
    }
  ')
  printf '{"valid":false,"error":"duplicate-section-header","missing":[],"malformed":["%s"]}\n' "$escaped_header"
  exit 0
fi

have_symptom=0;        [ -f "$work_directory/sec-symptom.txt" ]        && have_symptom=1
have_classification=0; [ -f "$work_directory/sec-classification.txt" ] && have_classification=1
have_capture=0;        [ -f "$work_directory/sec-capture.txt" ]        && have_capture=1
have_reproduction=0;   [ -f "$work_directory/sec-reproduction.txt" ]   && have_reproduction=1

missing_list=""
[ "$have_symptom" -eq 0 ]        && missing_list="${missing_list}\"symptom\","
[ "$have_classification" -eq 0 ] && missing_list="${missing_list}\"classification\","
[ "$have_capture" -eq 0 ]        && missing_list="${missing_list}\"capture\","
[ "$have_reproduction" -eq 0 ]   && missing_list="${missing_list}\"reproduction_context\","
missing_list=${missing_list%,}

if [ -n "$missing_list" ]; then
  printf '{"valid":false,"error":"missing-section","missing":[%s],"malformed":[]}\n' "$missing_list"
  exit 0
fi

# Trim a single leading and a single trailing blank line per section.
# The blank line that typically separates a `## ` header from the
# first content line, and the blank line that typically precedes the
# next `## ` header, are markdown structure, not content. Stripping at
# most one such blank line on each end keeps redaction tokens
# byte-identical while not emitting trailing-newline noise.
trim_one_blank_each_end() {
  local file="$1"
  awk '
    {
      lines[NR] = $0
    }
    END {
      first_index = 1
      last_index = NR
      if (NR >= 1 && lines[1] == "") first_index = 2
      if (last_index >= first_index && lines[last_index] == "") last_index = last_index - 1
      for (i = first_index; i <= last_index; i++) {
        if (i > first_index) printf "\n"
        printf "%s", lines[i]
      }
    }
  ' "$file"
}

section_symptom=$(trim_one_blank_each_end "$work_directory/sec-symptom.txt")
awk_status=$?
[ "$awk_status" -ne 0 ] && emit_internal_error "section-content-extract" "$awk_status"
section_classification=$(trim_one_blank_each_end "$work_directory/sec-classification.txt")
awk_status=$?
[ "$awk_status" -ne 0 ] && emit_internal_error "section-content-extract" "$awk_status"
section_capture=$(trim_one_blank_each_end "$work_directory/sec-capture.txt")
awk_status=$?
[ "$awk_status" -ne 0 ] && emit_internal_error "section-content-extract" "$awk_status"
section_reproduction=$(trim_one_blank_each_end "$work_directory/sec-reproduction.txt")
awk_status=$?
[ "$awk_status" -ne 0 ] && emit_internal_error "section-content-extract" "$awk_status"

empty_list=""
[ -z "$section_symptom" ]        && empty_list="${empty_list}\"symptom\","
[ -z "$section_classification" ] && empty_list="${empty_list}\"classification\","
[ -z "$section_capture" ]        && empty_list="${empty_list}\"capture\","
[ -z "$section_reproduction" ]   && empty_list="${empty_list}\"reproduction_context\","
empty_list=${empty_list%,}

if [ -n "$empty_list" ]; then
  printf '{"valid":false,"error":"empty-section","missing":[%s],"malformed":[]}\n' "$empty_list"
  exit 0
fi

# ---------------------------------------------------------------------------
# Step 3b: derive missing frontmatter values from body sections. Only
# `class` is load-bearing downstream (the workflow uses it as the fix
# branch slug). `gaia_version` is informational; left empty when not in
# frontmatter and not declared as `gaia_version: <ver>` in `## Capture`.
# ---------------------------------------------------------------------------

if [ -z "$frontmatter_class" ]; then
  frontmatter_class=$(awk -F':[[:space:]]*' '
    /^class:[[:space:]]/ { print $2; exit }
  ' "$work_directory/sec-classification.txt")
  awk_status=$?
  [ "$awk_status" -ne 0 ] && emit_internal_error "class-derive" "$awk_status"
fi

if [ -z "$frontmatter_class" ]; then
  printf '{"valid":false,"error":"missing-class","missing":["class"],"malformed":[]}\n'
  exit 0
fi

if [ -z "$frontmatter_gaia_version" ]; then
  frontmatter_gaia_version=$(awk -F':[[:space:]]*' '
    /^gaia_version:[[:space:]]/ { print $2; exit }
  ' "$work_directory/sec-capture.txt")
  awk_status=$?
  [ "$awk_status" -ne 0 ] && emit_internal_error "gaia-version-derive" "$awk_status"
fi

# ---------------------------------------------------------------------------
# Step 4: emit success JSON. Every string value must be JSON-escaped.
# ---------------------------------------------------------------------------

# json_escape_file <path> -> stdout: escapes the file's bytes for
# embedding inside JSON double-quotes. Handles backslash, double-quote,
# tab, carriage return, and newline.
json_escape_file() {
  awk '
    BEGIN {
      first = 1
    }
    {
      if (first == 1) { first = 0 } else { printf "\\n" }
      line_length = length($0)
      for (i = 1; i <= line_length; i++) {
        character = substr($0, i, 1)
        if (character == "\\") {
          printf "\\\\"
        } else if (character == "\"") {
          printf "\\\""
        } else if (character == "\t") {
          printf "\\t"
        } else if (character == "\r") {
          printf "\\r"
        } else {
          printf "%s", character
        }
      }
    }
  ' "$1"
}

# Frontmatter values: never multi-line, but reuse the file-based escape
# by writing them to disk first.
printf '%s' "$frontmatter_class"        > "$work_directory/fm-class.txt"
printf '%s' "$frontmatter_gaia_version" > "$work_directory/fm-gaia-version.txt"
printf '%s' "$frontmatter_created"      > "$work_directory/fm-created.txt"

escaped_class=$(json_escape_file "$work_directory/fm-class.txt")
escaped_gaia_version=$(json_escape_file "$work_directory/fm-gaia-version.txt")
escaped_created=$(json_escape_file "$work_directory/fm-created.txt")

# Sections: write trimmed content back, then escape.
printf '%s' "$section_symptom"        > "$work_directory/sec-symptom-trim.txt"
printf '%s' "$section_classification" > "$work_directory/sec-classification-trim.txt"
printf '%s' "$section_capture"        > "$work_directory/sec-capture-trim.txt"
printf '%s' "$section_reproduction"   > "$work_directory/sec-reproduction-trim.txt"

escaped_symptom=$(json_escape_file "$work_directory/sec-symptom-trim.txt")
escaped_classification=$(json_escape_file "$work_directory/sec-classification-trim.txt")
escaped_capture=$(json_escape_file "$work_directory/sec-capture-trim.txt")
escaped_reproduction=$(json_escape_file "$work_directory/sec-reproduction-trim.txt")

if [ -z "$frontmatter_gh_issue_url" ]; then
  gh_url_field='null'
else
  printf '%s' "$frontmatter_gh_issue_url" > "$work_directory/fm-gh-url.txt"
  escaped_gh_issue_url=$(json_escape_file "$work_directory/fm-gh-url.txt")
  gh_url_field="\"$escaped_gh_issue_url\""
fi

printf '{"valid":true,"frontmatter":{"class":"%s","gaia_version":"%s","created":"%s","gh_issue_url":%s},"sections":{"symptom":"%s","classification":"%s","capture":"%s","reproduction_context":"%s"}}\n' \
  "$escaped_class" "$escaped_gaia_version" "$escaped_created" "$gh_url_field" \
  "$escaped_symptom" "$escaped_classification" "$escaped_capture" "$escaped_reproduction"
