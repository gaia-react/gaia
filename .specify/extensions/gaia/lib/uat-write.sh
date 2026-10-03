#!/usr/bin/env bash
# uat-write.sh: Render PO-authored UATs into Playwright e2e specs.
#
# Usage:
#   uat-write.sh <spec-path>
#
# Reads the GAIA SPEC artifact's frontmatter, extracts every UAT-NNN with its
# given/when/then prose, renders one Playwright spec file per UAT under
# <package>/.playwright/e2e/<spec-id-lowercase>/ (the package named `frontend`
# in .gaia/packages.json, `frontend/` when the registry is absent, the repo
# root when that package's path is `.`), and writes a JSON summary to stdout
# (mirrored to .gaia/local/cache/uat-write/<SPEC-ID>.json).
#
# Exit codes:
#   0  - success; stdout is a JSON object with ok:true
#   1  - operational failure (template missing, write permission denied, etc.);
#        stdout is {"ok": false, "error": "..."}; a package registry or
#        descriptor that cannot be read is one, and nothing is written
#   2  - usage error (no spec path / spec missing / malformed frontmatter);
#        stderr message, no stdout
#
# Side effects (success path):
#   - Writes <package>/.playwright/e2e/<spec-id-lc>/uat-<nnn>.spec.ts for every
#     UAT in the SPEC (action: written | rewritten | unchanged).
#   - Hard-deletes any existing uat-*.spec.ts in that directory whose UAT-NNN
#     is no longer present in the SPEC (action: deleted).
#   - Writes the same JSON summary to
#     .gaia/local/cache/uat-write/<SPEC-ID>.json.
#   - Creates parent dirs as needed.
#
# Idempotency: re-running on an unchanged SPEC produces a zero-diff repo.
# Hash compare per file uses sha256.
set -euo pipefail

# --- Argument / usage handling ---
if [ "$#" -lt 1 ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
  cat <<'EOF' >&2
usage: uat-write.sh <spec-path>

Renders every UAT-NNN in <spec-path> into a Playwright e2e spec under
<package>/.playwright/e2e/<spec-id-lowercase>/. See script header for full contract.
EOF
  exit 2
fi

spec_path="$1"

if [ ! -f "$spec_path" ]; then
  echo "uat-write.sh: spec file not found: $spec_path" >&2
  exit 2
fi

# --- Resolve script + template directory (relative to script location) ---
script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
templates_directory="$script_directory/../templates"
spec_template="$templates_directory/uat-spec.ts.tmpl"
fixme_template="$templates_directory/uat-fixme.ts.tmpl"

# Repo root for output paths is invocation pwd. Convention: invoked from repo
# root by the slash-command body.
repo_root="$PWD"

# --- Helpers ---

# Emit an operational-failure JSON to stdout and exit 1.
fail_operation() {
  local failure_message="$1"
  local message_escaped
  message_escaped=$(printf '%s' "$failure_message" | sed 's/\\/\\\\/g; s/"/\\"/g')
  printf '{"ok":false,"error":"%s"}\n' "$message_escaped"
  exit 1
}

# Sets e2e_relative_directory, the repo-relative directory the specs render
# into: the package named `frontend` (the registry, or the built-in default)
# plus `.playwright/e2e`. Not run in a command substitution, so fail_operation's
# stdout and exit reach the caller.
resolve_e2e_relative_directory() {
  local packages_library="$script_directory/../../../../.claude/hooks/lib/gaia-packages.sh"
  local packages_status=0 package_path
  if [ ! -f "$packages_library" ]; then
    fail_operation "package library missing: $packages_library. Next step: restore it from the GAIA release."
  fi
  # shellcheck disable=SC1090
  source "$packages_library"
  gaia_packages_load "$repo_root" || packages_status=$?
  if [ "$packages_status" -ne 0 ]; then
    fail_operation "$GAIA_PACKAGES_ERROR"
  fi
  if ! package_path=$(gaia_package_dir frontend); then
    fail_operation "gaia-packages: .gaia/packages.json registers no package named frontend. Next step: add a frontend entry, or delete the registry to use the built-in default."
  fi
  if [ "$package_path" = "." ]; then
    e2e_relative_directory='.playwright/e2e'
  else
    e2e_relative_directory="$package_path/.playwright/e2e"
  fi
}

# Compute sha256 of stdin; output the bare hex digest.
sha256_of_stdin() {
  if command -v shasum > /dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum > /dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    fail_operation "no sha256 tool available (need shasum or sha256sum)"
  fi
}

# Escape a value for safe inclusion inside a single-quoted JS string literal
# (test name, expect message). Backslash and single-quote are escaped; CR/NL
# collapsed to a single space, NULs dropped. The escaped form is also valid
# inside `//` line comments because JS comment semantics do not interpret
# backslash escapes, `\'` reads as the two characters \ and ' to a human, but
# the parser is unaffected.
sanitize_for_javascript_string() {
  local sanitized
  sanitized=$(printf '%s' "$1" | tr '\r\n' '  ' | tr -d '\000')
  sanitized="${sanitized//\\/\\\\}"
  sanitized="${sanitized//\'/\\\'}"
  printf '%s' "$sanitized"
}

# Resolved before anything is written, so a registry that cannot be read
# leaves the tree untouched.
resolve_e2e_relative_directory

# --- Extract frontmatter block (between first two `---` lines) ---
frontmatter_block=""
state="pre"
while IFS= read -r line; do
  case "$state" in
    pre)
      if [ "$line" = "---" ]; then
        state="in_frontmatter"
      fi
      ;;
    in_frontmatter)
      if [ "$line" = "---" ]; then
        state="post"
        break
      else
        frontmatter_block+="$line"$'\n'
      fi
      ;;
  esac
done < "$spec_path"

if [ "$state" != "post" ]; then
  echo "uat-write.sh: malformed frontmatter (no closing '---') in $spec_path" >&2
  exit 2
fi

# --- spec_id ---
spec_id_raw=$(printf '%s' "$frontmatter_block" | awk -F': ' '/^spec_id:/ {print $2; exit}')
spec_id_raw="${spec_id_raw// /}"
spec_id_raw="${spec_id_raw//\"/}"
spec_id_raw="${spec_id_raw//\'/}"

if [ -z "$spec_id_raw" ]; then
  echo "uat-write.sh: spec_id missing from frontmatter in $spec_path" >&2
  exit 2
fi

if ! [[ "$spec_id_raw" =~ ^SPEC-[0-9]+$ ]]; then
  echo "uat-write.sh: spec_id '$spec_id_raw' does not match SPEC-NNN" >&2
  exit 2
fi

spec_id="$spec_id_raw"
spec_id_lowercase=$(printf '%s' "$spec_id" | tr '[:upper:]' '[:lower:]')

# --- Extract uats: block ---
# Lines from "uats:" up to next top-level key (column 0, identifier:).
uats_block=$(printf '%s' "$frontmatter_block" | awk '
  /^uats:/ { capture = 1; next }
  capture && /^[A-Za-z_][A-Za-z0-9_]*:/ { capture = 0 }
  capture { print }
')

# --- Empty / missing UATs case (stop condition) ---
target_directory="$repo_root/$e2e_relative_directory/$spec_id_lowercase"

# Ensure cache dir + path resolved up-front (used in both empty and populated paths).
cache_directory="$repo_root/.gaia/local/cache/uat-write"
cache_file="$cache_directory/$spec_id.json"

if [ -z "$uats_block" ] || ! grep -qE '^[[:space:]]*-[[:space:]]+uat_id:' <<<"$uats_block"; then
  echo "uat-write.sh: no UATs in $spec_path; nothing to render" >&2
  # Even with no UATs, hard-delete any orphaned uat-*.spec.ts files in the
  # target dir (resolution README #3 is symmetric: SPEC truth wins).
  deleted_details=""
  deleted_count=0
  if [ -d "$target_directory" ]; then
    while IFS= read -r candidate_file; do
      [ -z "$candidate_file" ] && continue
      rm -f -- "$candidate_file"
      relative_path="${candidate_file#"$repo_root/"}"
      base=$(basename "$candidate_file" .spec.ts)
      deleted_uat_number="${base#uat-}"
      deleted_uat_id="UAT-${deleted_uat_number}"
      deleted_uat_id=$(printf '%s' "$deleted_uat_id" | tr '[:lower:]' '[:upper:]')
      if [ -n "$deleted_details" ]; then deleted_details+=","; fi
      deleted_details+="{\"uat_id\":\"$deleted_uat_id\",\"action\":\"deleted\",\"path\":\"$relative_path\"}"
      deleted_count=$((deleted_count + 1))
    done < <(find "$target_directory" -maxdepth 1 -type f -name 'uat-*.spec.ts' 2>/dev/null | sort)
  fi
  mkdir -p "$cache_directory"
  result=$(printf '{"ok":true,"spec_id":"%s","spec_dir":"%s/%s","framework":"playwright","summary":{"written":0,"rewritten":0,"deleted":%d,"fixme":0,"unchanged":0},"details":[%s]}' \
    "$spec_id" "$e2e_relative_directory" "$spec_id_lowercase" "$deleted_count" "$deleted_details")
  printf '%s\n' "$result" | tee "$cache_file" > /dev/null
  printf '%s\n' "$result"
  exit 0
fi

# --- Verify templates exist ---
if [ ! -f "$spec_template" ]; then
  fail_operation "template missing: $spec_template"
fi
if [ ! -f "$fixme_template" ]; then
  fail_operation "template missing: $fixme_template"
fi

# --- Parse UAT entries ---
# Each list item starts with `  - uat_id: UAT-NNN` and is followed by
# `    given:`, `    when:`, `    then:` lines. We accumulate until the next
# `  -` or end of block. Continuation lines (further-indented) are folded with
# a single space (rough YAML folding behavior, sufficient for short UATs).
#
# We do NOT support `|` block scalars in this renderer; PO-authored UATs are
# single-line GWT in practice. If a UAT's value spans multiple lines, lines
# beyond the first are folded into the value with a leading space.

# Output: tab-separated rows: uat_id<TAB>given<TAB>when<TAB>then
parsed=$(printf '%s\n' "$uats_block" | awk '
  function flush() {
    if (uat_id != "") {
      gsub(/\t/, " ", given_text); gsub(/\t/, " ", when_text); gsub(/\t/, " ", then_text)
      printf "%s\t%s\t%s\t%s\n", uat_id, given_text, when_text, then_text
    }
    uat_id = ""; given_text = ""; when_text = ""; then_text = ""; current = ""
  }
  function append_to(value_reference, addition,    separator) {
    # We cannot pass value_reference by-ref in awk; caller mutates global.
  }
  BEGIN { uat_id = ""; given_text = ""; when_text = ""; then_text = ""; current = "" }
  /^[[:space:]]*-[[:space:]]+uat_id:/ {
    flush()
    sub(/^[[:space:]]*-[[:space:]]+uat_id:[[:space:]]*/, "", $0)
    sub(/[[:space:]]+$/, "", $0)
    uat_id = $0
    current = "uat_id"
    next
  }
  /^[[:space:]]+given:/ {
    sub(/^[[:space:]]+given:[[:space:]]*/, "", $0)
    given_text = $0
    current = "g"
    next
  }
  /^[[:space:]]+when:/ {
    sub(/^[[:space:]]+when:[[:space:]]*/, "", $0)
    when_text = $0
    current = "w"
    next
  }
  /^[[:space:]]+then:/ {
    sub(/^[[:space:]]+then:[[:space:]]*/, "", $0)
    then_text = $0
    current = "t"
    next
  }
  /^[[:space:]]*$/ { next }
  {
    # Continuation line, fold into current field with a leading space.
    line = $0
    sub(/^[[:space:]]+/, "", line)
    if (current == "g") given_text = given_text " " line
    else if (current == "w") when_text = when_text " " line
    else if (current == "t") then_text = then_text " " line
    # uat_id lines are single-line; ignore continuations there.
  }
  END { flush() }
')

if [ -z "$parsed" ]; then
  # Defensive: uats_block had a list-marker line but no parseable entries.
  echo "uat-write.sh: uats: block present but no parseable UAT entries in $spec_path" >&2
  exit 2
fi

# --- Render loop ---
generated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
divergence_rule_path=".specify/extensions/gaia/rules/uat-divergence.md"

# Track which UAT files we wrote so we can find orphans afterwards.
seen_uat_files=""

# JSON detail accumulator (array body, comma-separated).
details=""

# Counters.
written=0
rewritten=0
deleted=0
fixme=0
unchanged=0

mkdir -p "$target_directory"

# Sort parsed rows by uat_id for deterministic output ordering.
parsed_sorted=$(printf '%s' "$parsed" | sort -t $'\t' -k1,1)

while IFS=$'\t' read -r uat_id uat_given uat_when uat_then; do
  [ -z "$uat_id" ] && continue

  if ! [[ "$uat_id" =~ ^UAT-[0-9]+$ ]]; then
    fail_operation "malformed uat_id '$uat_id' in $spec_path (must match UAT-NNN)"
  fi

  uat_number="${uat_id#UAT-}"
  uat_number_lowercase=$(printf '%s' "$uat_number" | tr '[:upper:]' '[:lower:]')
  output_relative_path="$e2e_relative_directory/$spec_id_lowercase/uat-$uat_number_lowercase.spec.ts"
  output_path="$repo_root/$output_relative_path"

  seen_uat_files+="$output_relative_path"$'\n'

  # --- Abstraction heuristic for fixme template ---
  # Trigger fixme if the `then` clause has NEITHER:
  #  (a) a quoted-string token of length >= 2 (single, double, or backtick), AND
  #  (b) a URL-like fragment (contains "/", "#", or "?")
  use_fixme=0
  has_quoted=0
  has_urlish=0
  if grep -qE "['\"\`][^'\"\`]{2,}['\"\`]" <<<"$uat_then"; then
    has_quoted=1
  fi
  if grep -qE '[/#?]' <<<"$uat_then"; then
    has_urlish=1
  fi
  if [ "$has_quoted" -eq 0 ] && [ "$has_urlish" -eq 0 ]; then
    use_fixme=1
  fi

  # Sanitize prose. Templates substitute the same placeholder (`${UAT_THEN}`,
  # etc.) into both comment positions AND a single-quoted JS string position
  # (line `await expect(false, '... ${UAT_THEN}').toBe(true)`). The renderer's
  # contract (README §"Implementation notes" #3) requires escaping quotes so
  # the rendered TS parses. We use the JS-single-quote-safe form universally:
  #  - backslash escaped to `\\`
  #  - single-quote escaped to `\'`
  #  - newlines collapsed to space (so single-line comments stay intact)
  # The escaped form remains valid inside `//` comments, JS comment semantics
  # do not interpret backslash escapes.
  given_sanitized=$(sanitize_for_javascript_string "$uat_given")
  when_sanitized=$(sanitize_for_javascript_string "$uat_when")
  then_sanitized=$(sanitize_for_javascript_string "$uat_then")

  # Pick template + abstraction blocker line.
  if [ "$use_fixme" -eq 1 ]; then
    template_path="$fixme_template"
    blocker_raw="then-clause has no quoted UI surface and no URL/path fragment; refine UAT to reference a concrete element or route"
    blocker_sanitized=$(sanitize_for_javascript_string "$blocker_raw")
  else
    template_path="$spec_template"
    blocker_sanitized=""
  fi

  # Read template.
  template_body=$(cat "$template_path")

  # Render with a sentinel for the timestamp first; hash the canonical form
  # (sans timestamp) for idempotency. The timestamp must not perturb hashes -
  # otherwise the SECOND run on an unchanged SPEC would always see a "new"
  # file (different timestamp ⇒ different hash ⇒ rewrite). We compare by
  # stripping the timestamp line from both rendered and existing content.
  render() {
    local stamp="$1"
    printf '%s' "$template_body" \
      | awk -v spec_id="$spec_id" \
            -v uat_id="$uat_id" \
            -v uat_given="$given_sanitized" \
            -v uat_when="$when_sanitized" \
            -v uat_then="$then_sanitized" \
            -v generated_at="$stamp" \
            -v divergence_rule_path="$divergence_rule_path" \
            -v abstraction_blocker="$blocker_sanitized" \
      '{
        gsub(/\$\{SPEC_ID\}/, spec_id)
        gsub(/\$\{UAT_ID\}/, uat_id)
        gsub(/\$\{UAT_GIVEN\}/, uat_given)
        gsub(/\$\{UAT_WHEN\}/, uat_when)
        gsub(/\$\{UAT_THEN\}/, uat_then)
        gsub(/\$\{GENERATED_AT\}/, generated_at)
        gsub(/\$\{DIVERGENCE_RULE_PATH\}/, divergence_rule_path)
        gsub(/\$\{ABSTRACTION_BLOCKER\}/, abstraction_blocker)
        print
      }'
  }

  # Strip the line carrying the generated-at marker (matches templates'
  # `// SPEC: ... | UAT: ... | generated: ...` line).
  strip_stamp() {
    awk '!/\| generated:/ { print }'
  }

  # Canonical hash: timestamp-stripped form.
  rendered_canonical=$(render "GENERATED_AT_PLACEHOLDER" | strip_stamp)
  rendered_hash=$(printf '%s' "$rendered_canonical" | sha256_of_stdin)

  # Decide action.
  action=""
  if [ -f "$output_path" ]; then
    existing_canonical=$(strip_stamp < "$output_path")
    existing_hash=$(printf '%s' "$existing_canonical" | sha256_of_stdin)
    if [ "$existing_hash" = "$rendered_hash" ]; then
      action="unchanged"
      unchanged=$((unchanged + 1))
    else
      render "$generated_at" > "$output_path"
      action="rewritten"
      rewritten=$((rewritten + 1))
    fi
  else
    render "$generated_at" > "$output_path"
    action="written"
    written=$((written + 1))
  fi

  if [ "$use_fixme" -eq 1 ]; then
    fixme=$((fixme + 1))
  fi

  # Append details row.
  if [ -n "$details" ]; then details+=","; fi
  details+=$(printf '{"uat_id":"%s","action":"%s","path":"%s","hash":"sha256:%s"}' \
    "$uat_id" "$action" "$output_relative_path" "$rendered_hash")

done <<< "$parsed_sorted"

# --- Orphan deletion ---
if [ -d "$target_directory" ]; then
  while IFS= read -r candidate_file; do
    [ -z "$candidate_file" ] && continue
    relative_path="${candidate_file#"$repo_root/"}"
    if grep -qxF "$relative_path" <<<"$seen_uat_files"; then
      continue
    fi
    rm -f -- "$candidate_file"
    base=$(basename "$candidate_file" .spec.ts)
    deleted_uat_number="${base#uat-}"
    deleted_uat_id="UAT-$(printf '%s' "$deleted_uat_number" | tr '[:lower:]' '[:upper:]')"
    if [ -n "$details" ]; then details+=","; fi
    details+=$(printf '{"uat_id":"%s","action":"deleted","path":"%s"}' "$deleted_uat_id" "$relative_path")
    deleted=$((deleted + 1))
  done < <(find "$target_directory" -maxdepth 1 -type f -name 'uat-*.spec.ts' 2>/dev/null | sort)
fi

# --- Sort details by uat_id for stable output ---
# Render-order entries (already sorted by uat_id via parsed_sorted) are
# followed by deleted-orphan entries (sorted by filename, which == sorted by
# uat_id since uat-NNN.spec.ts is monotonic). When both populations are
# present we need a single end-to-end sort. Implementation: split on the
# `},{` object-boundary, prepend each object's uat_id as a sort key, sort,
# strip the key, rejoin.
if [ -n "$details" ]; then
  sorted_objects=$(printf '%s' "$details" | awk '
    BEGIN { buffer = "" }
    {
      line_text = $0
      text_length = length(line_text)
      i = 1
      while (i <= text_length) {
        character = substr(line_text, i, 1)
        if (character == "}" && substr(line_text, i+1, 1) == ",") {
          buffer = buffer character
          print buffer
          buffer = ""
          i = i + 2  # skip the close-brace+comma boundary
          continue
        }
        buffer = buffer character
        i = i + 1
      }
    }
    END { if (buffer != "") print buffer }
  ' | awk '
    {
      match($0, /"uat_id":"[^"]+"/)
      key = substr($0, RSTART+10, RLENGTH-11)
      print key "\t" $0
    }
  ' | sort -k1,1 | cut -f2-)

  if [ -n "$sorted_objects" ]; then
    details=$(printf '%s' "$sorted_objects" | awk 'NR==1{printf "%s",$0; next}{printf ",%s",$0}')
  fi
fi

# --- Build final JSON, mirror to cache, emit on stdout ---
mkdir -p "$cache_directory"

result=$(printf '{"ok":true,"spec_id":"%s","spec_dir":"%s/%s","framework":"playwright","summary":{"written":%d,"rewritten":%d,"deleted":%d,"fixme":%d,"unchanged":%d},"details":[%s]}' \
  "$spec_id" "$e2e_relative_directory" "$spec_id_lowercase" "$written" "$rewritten" "$deleted" "$fixme" "$unchanged" "$details")

printf '%s\n' "$result" > "$cache_file"
printf '%s\n' "$result"
exit 0
