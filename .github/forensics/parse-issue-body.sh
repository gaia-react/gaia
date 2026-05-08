#!/usr/bin/env bash
# parse-issue-body.sh — deterministic parser for the SPEC-001 strict
# forensics issue body schema. Emits JSON to stdout.
#
# Exit code: 0 always (consumers inspect the JSON `valid` field). Exit 2
# is reserved for genuine script errors (missing input file, bad usage).
#
# POSIX-tools only: awk, sed, grep, bash. No jq, no yq, no python.
#
# Contract: SPEC-002 (UAT-009, UAT-013, UAT-015) and the body-parser
# task spec at
# `.gaia/local/plans/spec-002-forensics-triage-action/task-body-parser.md`.

set -u

usage() {
  echo "usage: parse-issue-body.sh <input-file>" >&2
  exit 2
}

[ "$#" -eq 1 ] || usage
input_file="$1"
[ -f "$input_file" ] || { echo "parse-issue-body.sh: input file not found: $input_file" >&2; exit 2; }

# ---------------------------------------------------------------------------
# Working-area: a private temp dir holding one file per section. Avoids
# fragile in-memory section-splitting via shell sentinels.
# ---------------------------------------------------------------------------

work_dir=$(mktemp -d 2>/dev/null) || { echo "parse-issue-body.sh: mktemp failed" >&2; exit 2; }
trap 'rm -rf "$work_dir"' EXIT

# ---------------------------------------------------------------------------
# Step 1: validate frontmatter shape and extract the required keys.
# ---------------------------------------------------------------------------

# First non-blank line (well, first line — SPEC-001 emits `---` as line 1)
# must be the frontmatter sentinel.
first_line=$(awk 'NR==1{print; exit}' "$input_file")
if [ "$first_line" != "---" ]; then
  printf '{"valid":false,"error":"malformed-frontmatter","missing":[],"malformed":["frontmatter"]}\n'
  exit 0
fi

# Closing `---` line number (must be > 1, exact match).
fm_end=$(awk 'NR>1 && $0=="---"{print NR; exit}' "$input_file")
if [ -z "${fm_end:-}" ]; then
  printf '{"valid":false,"error":"malformed-frontmatter","missing":[],"malformed":["frontmatter"]}\n'
  exit 0
fi

# Frontmatter content lines (between line 2 and fm_end-1).
awk -v end="$fm_end" 'NR>1 && NR<end' "$input_file" > "$work_dir/frontmatter.txt"

fm_class=""
fm_gaia_version=""
fm_created=""
fm_gh_issue_url=""

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
    class) fm_class="$value" ;;
    gaia_version) fm_gaia_version="$value" ;;
    created) fm_created="$value" ;;
    gh_issue_url) fm_gh_issue_url="$value" ;;
  esac
done < "$work_dir/frontmatter.txt"

if [ -z "$fm_class" ] || [ -z "$fm_gaia_version" ] || [ -z "$fm_created" ]; then
  printf '{"valid":false,"error":"malformed-frontmatter","missing":[],"malformed":["frontmatter"]}\n'
  exit 0
fi

# ---------------------------------------------------------------------------
# Step 2: split the post-frontmatter body into per-section files. Detect
# malformed `## ` headers (anything not in the canonical four).
# ---------------------------------------------------------------------------

body_start=$((fm_end + 1))

# Single awk pass: route lines into per-section files; record the first
# malformed header (if any) into a sentinel file.
#
# A section starts at `^## (Symptom|Classification|Capture|Reproduction context)$`
# and ends at the next `^## ` line or EOF. Lines BEFORE the first valid
# `## ` header are dropped (the SPEC-001 schema places the four sections
# back-to-back; nothing precedes them). Lines under a malformed header
# are also dropped — the malformed header itself is reported.
awk -v start="$body_start" -v out_dir="$work_dir" '
  function flush() {
    if (cur != "" && out_path != "") {
      print buf > out_path
      close(out_path)
    }
    cur = ""
    buf = ""
    out_path = ""
  }
  BEGIN {
    cur = ""
    buf = ""
    out_path = ""
  }
  NR < start { next }
  /^## / {
    name = substr($0, 4)
    flush()
    if (name == "Symptom") {
      cur = name; out_path = out_dir "/sec-symptom.txt"
    } else if (name == "Classification") {
      cur = name; out_path = out_dir "/sec-classification.txt"
    } else if (name == "Capture") {
      cur = name; out_path = out_dir "/sec-capture.txt"
    } else if (name == "Reproduction context") {
      cur = name; out_path = out_dir "/sec-reproduction.txt"
    } else {
      # Record first malformed header (subsequent ones ignored).
      bad_path = out_dir "/malformed-header.txt"
      cmd = "test -f \"" bad_path "\""
      if (system(cmd) != 0) {
        print name > bad_path
        close(bad_path)
      }
      cur = ""
      out_path = ""
    }
    next
  }
  {
    if (cur != "") {
      if (buf == "") buf = $0
      else buf = buf "\n" $0
    }
  }
  END {
    flush()
  }
' "$input_file"

# ---------------------------------------------------------------------------
# Step 3: failure-mode resolution. Order:
#   1. malformed-section-header
#   2. missing-section
#   3. empty-section
# ---------------------------------------------------------------------------

if [ -f "$work_dir/malformed-header.txt" ]; then
  bad_header=$(cat "$work_dir/malformed-header.txt")
  esc_header=$(printf '%s' "$bad_header" | awk '
    {
      gsub(/\\/, "\\\\")
      gsub(/"/, "\\\"")
      gsub(/\t/, "\\t")
      printf "%s", $0
    }
  ')
  printf '{"valid":false,"error":"malformed-section-header","missing":[],"malformed":["%s"]}\n' "$esc_header"
  exit 0
fi

have_symptom=0;        [ -f "$work_dir/sec-symptom.txt" ]        && have_symptom=1
have_classification=0; [ -f "$work_dir/sec-classification.txt" ] && have_classification=1
have_capture=0;        [ -f "$work_dir/sec-capture.txt" ]        && have_capture=1
have_reproduction=0;   [ -f "$work_dir/sec-reproduction.txt" ]   && have_reproduction=1

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
# (UAT-015 wants verbatim section *content*; the blank line that
# typically separates a `## ` header from the first content line, and
# the blank line that typically precedes the next `## ` header, are
# markdown structure, not content. Stripping at most one such blank
# line on each end keeps redaction tokens byte-identical while not
# emitting trailing-newline noise.)
trim_one_blank_each_end() {
  local file="$1"
  awk '
    {
      lines[NR] = $0
    }
    END {
      s = 1
      e = NR
      if (NR >= 1 && lines[1] == "") s = 2
      if (e >= s && lines[e] == "") e = e - 1
      for (i = s; i <= e; i++) {
        if (i > s) printf "\n"
        printf "%s", lines[i]
      }
    }
  ' "$file"
}

sec_symptom=$(trim_one_blank_each_end "$work_dir/sec-symptom.txt")
sec_classification=$(trim_one_blank_each_end "$work_dir/sec-classification.txt")
sec_capture=$(trim_one_blank_each_end "$work_dir/sec-capture.txt")
sec_reproduction=$(trim_one_blank_each_end "$work_dir/sec-reproduction.txt")

empty_list=""
[ -z "$sec_symptom" ]        && empty_list="${empty_list}\"symptom\","
[ -z "$sec_classification" ] && empty_list="${empty_list}\"classification\","
[ -z "$sec_capture" ]        && empty_list="${empty_list}\"capture\","
[ -z "$sec_reproduction" ]   && empty_list="${empty_list}\"reproduction_context\","
empty_list=${empty_list%,}

if [ -n "$empty_list" ]; then
  printf '{"valid":false,"error":"empty-section","missing":[%s],"malformed":[]}\n' "$empty_list"
  exit 0
fi

# ---------------------------------------------------------------------------
# Step 4: emit success JSON. Every string value must be JSON-escaped.
# ---------------------------------------------------------------------------

# json_escape_file <path> -> stdout: escapes the file's bytes for
# embedding inside JSON double-quotes. Handles backslash, double-quote,
# tab, carriage return, and newline. Other control characters in the
# 0x00–0x1f range are not expected from SPEC-001 issue bodies but if
# present are kept as-is (the consumer is responsible for validating
# against its own JSON parser).
json_escape_file() {
  awk '
    BEGIN { first = 1 }
    {
      if (first == 1) { first = 0 } else { printf "\\n" }
      n = length($0)
      for (i = 1; i <= n; i++) {
        c = substr($0, i, 1)
        if (c == "\\") {
          printf "\\\\"
        } else if (c == "\"") {
          printf "\\\""
        } else if (c == "\t") {
          printf "\\t"
        } else if (c == "\r") {
          printf "\\r"
        } else {
          printf "%s", c
        }
      }
    }
  ' "$1"
}

# Frontmatter values: never multi-line, but reuse the file-based escape
# by writing them to disk first.
printf '%s' "$fm_class"        > "$work_dir/fm-class.txt"
printf '%s' "$fm_gaia_version" > "$work_dir/fm-gaia-version.txt"
printf '%s' "$fm_created"      > "$work_dir/fm-created.txt"

esc_class=$(json_escape_file "$work_dir/fm-class.txt")
esc_gaia_version=$(json_escape_file "$work_dir/fm-gaia-version.txt")
esc_created=$(json_escape_file "$work_dir/fm-created.txt")

# Sections: write trimmed content back, then escape.
printf '%s' "$sec_symptom"        > "$work_dir/sec-symptom-trim.txt"
printf '%s' "$sec_classification" > "$work_dir/sec-classification-trim.txt"
printf '%s' "$sec_capture"        > "$work_dir/sec-capture-trim.txt"
printf '%s' "$sec_reproduction"   > "$work_dir/sec-reproduction-trim.txt"

esc_symptom=$(json_escape_file "$work_dir/sec-symptom-trim.txt")
esc_classification=$(json_escape_file "$work_dir/sec-classification-trim.txt")
esc_capture=$(json_escape_file "$work_dir/sec-capture-trim.txt")
esc_reproduction=$(json_escape_file "$work_dir/sec-reproduction-trim.txt")

if [ -z "$fm_gh_issue_url" ]; then
  gh_url_field='null'
else
  printf '%s' "$fm_gh_issue_url" > "$work_dir/fm-gh-url.txt"
  esc_gh=$(json_escape_file "$work_dir/fm-gh-url.txt")
  gh_url_field="\"$esc_gh\""
fi

printf '{"valid":true,"frontmatter":{"class":"%s","gaia_version":"%s","created":"%s","gh_issue_url":%s},"sections":{"symptom":"%s","classification":"%s","capture":"%s","reproduction_context":"%s"}}\n' \
  "$esc_class" "$esc_gaia_version" "$esc_created" "$gh_url_field" \
  "$esc_symptom" "$esc_classification" "$esc_capture" "$esc_reproduction"
