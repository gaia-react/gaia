# shellcheck shell=bash
#
# Shared reader of SPEC UATs, the plan's UAT routing table and rendered UAT
# spec files. Sourced, never executed: the renderer (uat-write.sh) and the
# checks that judge rendered specs against the SPEC call these functions by
# name, so a rename or a changed output shape breaks every caller.
#
# Every function writes data to stdout and diagnostics to stderr. Status 2 means
# invalid input; status 1 an operational failure. No `set -e` here: callers own
# their shell options.
#
# Canonical text. A SPEC UAT field is canonicalized in full by
# uat_lib_canonical_text (fold continuation lines, trim, strip one layer of
# matching YAML quotes and unescape it, then normalize whitespace). Text that is
# already canonical (a rendered spec's contract lines, a plan's criterion line)
# goes through uat_lib_whitespace_text only, because quote stripping is not
# idempotent: a canonical then-clause that itself starts and ends with the same
# quote would lose those quotes on a second pass and read as changed.
#
# Bash 3.2 compatible; BSD and GNU tools. User text never reaches awk through
# `-v` (which processes backslash escapes): it arrives on stdin or through
# ENVIRON.

if [ -n "${UAT_LIB_SH:-}" ]; then
  return 0
fi
UAT_LIB_SH=1

_UAT_LIB_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

uat_lib_whitespace_text() {
  local text
  text=$(LC_ALL=C tr -d '\000' | LC_ALL=C tr '\t\r\n' '   ' | LC_ALL=C tr -s ' ')
  text="${text# }"
  text="${text% }"
  printf '%s' "$text"
}

uat_lib_canonical_text() {
  LC_ALL=C tr -d '\000' | LC_ALL=C awk '
    NR == 1 { value = $0; next }
    {
      line = $0
      sub(/^[ \t]+/, "", line)
      value = value " " line
    }
    END {
      sub(/^[ \t\r\n]+/, "", value)
      sub(/[ \t\r\n]+$/, "", value)
      length_of_value = length(value)
      first = substr(value, 1, 1)
      last = substr(value, length_of_value, 1)
      if (length_of_value >= 2 && first == "\"" && last == "\"") {
        inner = substr(value, 2, length_of_value - 2)
        value = ""
        position = 1
        inner_length = length(inner)
        while (position <= inner_length) {
          character = substr(inner, position, 1)
          if (character == "\\" && position < inner_length) {
            following = substr(inner, position + 1, 1)
            if (following == "\\" || following == "\"") {
              value = value following
              position += 2
              continue
            }
          }
          value = value character
          position++
        }
      } else if (length_of_value >= 2 && first == "\047" && last == "\047") {
        inner = substr(value, 2, length_of_value - 2)
        value = ""
        while ((at = index(inner, "\047\047")) > 0) {
          value = value substr(inner, 1, at)
          inner = substr(inner, at + 2)
        }
        value = value inner
      }
      printf "%s", value
    }
  ' | uat_lib_whitespace_text
}

# Prints the frontmatter between the first two `---` lines; status 2 when the
# block never closes.
_uat_lib_frontmatter() {
  awk '
    {
      line = $0
      sub(/\r$/, "", line)
    }
    state == 0 && line == "---" { state = 1; next }
    state == 1 && line == "---" { state = 2; exit }
    state == 1 { print }
    END { if (state != 2) exit 2 }
  ' "$1"
}

uat_lib_parse_spec() {
  local spec_path="${1:-}" frontmatter spec_id records record tag text
  local item_open=0 item_id='' item_given='' item_when='' item_then=''
  local rows='' seen_ids='' problems=0 canonical_id given_text when_text then_text

  if [ ! -f "$spec_path" ]; then
    printf 'uat-lib: SPEC not found: %s\n' "$spec_path" >&2
    return 2
  fi
  if ! frontmatter=$(_uat_lib_frontmatter "$spec_path"); then
    printf "uat-lib: malformed frontmatter (no closing '---') in %s\n" "$spec_path" >&2
    return 2
  fi

  spec_id=$(printf '%s\n' "$frontmatter" | awk '/^spec_id:/ { sub(/^spec_id:/, ""); print; exit }' | uat_lib_canonical_text)
  if [ -z "$spec_id" ]; then
    printf 'uat-lib: spec_id missing from frontmatter in %s\n' "$spec_path" >&2
    return 2
  fi
  if ! [[ "$spec_id" =~ ^SPEC-[0-9]+$ ]]; then
    printf "uat-lib: spec_id '%s' does not match SPEC-NNN in %s\n" "$spec_id" "$spec_path" >&2
    return 2
  fi

  # Tags: N starts a list item, U carries its uat_id, G/W/T one physical line of
  # given/when/then (the value after the key, then each continuation line).
  records=$(printf '%s\n' "$frontmatter" | awk '
    /^uats:/ { capture = 1; next }
    capture && /^[A-Za-z_][A-Za-z0-9_]*:/ { capture = 0 }
    !capture { next }
    /^[ \t]*$/ { next }
    {
      line = $0
      if (line ~ /^[ \t]*-[ \t]+/) {
        print "N"
        sub(/^[ \t]*-[ \t]+/, "", line)
        current = ""
      } else if (line !~ /^[ \t]+[A-Za-z_][A-Za-z0-9_]*:([ \t]|$)/) {
        if (current != "") print current "\t" line
        next
      }
      sub(/^[ \t]+/, "", line)
      if (line ~ /^uat_id:/) { sub(/^uat_id:/, "", line); print "U\t" line; current = ""; next }
      if (line ~ /^given:/) { sub(/^given:/, "", line); current = "G"; print current "\t" line; next }
      if (line ~ /^when:/) { sub(/^when:/, "", line); current = "W"; print current "\t" line; next }
      if (line ~ /^then:/) { sub(/^then:/, "", line); current = "T"; print current "\t" line; next }
      current = ""
    }
  ')

  _uat_lib_flush_item() {
    [ "$item_open" -eq 1 ] || return 0
    canonical_id=$(printf '%s' "$item_id" | uat_lib_canonical_text)
    if ! [[ "$canonical_id" =~ ^UAT-[0-9]+$ ]]; then
      printf "uat-lib: malformed uat_id '%s' in %s (must match UAT-NNN)\n" "$canonical_id" "$spec_path" >&2
      problems=$((problems + 1))
      return 0
    fi
    if grep -qxF -- "$canonical_id" <<<"$seen_ids"; then
      printf 'uat-lib: duplicate uat_id %s in %s\n' "$canonical_id" "$spec_path" >&2
      problems=$((problems + 1))
      return 0
    fi
    seen_ids="$seen_ids$canonical_id"$'\n'
    given_text=$(printf '%s' "$item_given" | uat_lib_canonical_text)
    when_text=$(printf '%s' "$item_when" | uat_lib_canonical_text)
    then_text=$(printf '%s' "$item_then" | uat_lib_canonical_text)
    if [ -z "$given_text" ] || [ -z "$when_text" ] || [ -z "$then_text" ]; then
      printf 'uat-lib: %s in %s needs a non-empty given, when and then\n' "$canonical_id" "$spec_path" >&2
      problems=$((problems + 1))
      return 0
    fi
    rows="$rows$canonical_id"$'\t'"$given_text"$'\t'"$when_text"$'\t'"$then_text"$'\n'
  }

  while IFS= read -r record; do
    [ -n "$record" ] || continue
    tag="${record%%$'\t'*}"
    if [ "$tag" = "N" ]; then
      _uat_lib_flush_item
      item_open=1
      item_id=''
      item_given=''
      item_when=''
      item_then=''
      continue
    fi
    text="${record#*$'\t'}"
    case "$tag" in
      U) item_id="$text" ;;
      G) item_given="${item_given:+$item_given$'\n'}$text" ;;
      W) item_when="${item_when:+$item_when$'\n'}$text" ;;
      T) item_then="${item_then:+$item_then$'\n'}$text" ;;
    esac
  done <<<"$records"
  _uat_lib_flush_item
  unset -f _uat_lib_flush_item

  if [ "$problems" -gt 0 ]; then
    return 2
  fi
  if [ -z "$rows" ]; then
    printf 'uat-lib: no parseable UAT in the uats: block of %s\n' "$spec_path" >&2
    return 2
  fi
  printf '%s' "$rows" | LC_ALL=C sort
}

uat_lib_parse_routing() {
  local routing_file="${1:-}" status=0 rows

  if [ ! -f "$routing_file" ]; then
    printf 'uat-lib: routing file not found: %s\n' "$routing_file" >&2
    return 2
  fi
  rows=$(awk '
    function trim(text) {
      sub(/^[ \t\r]+/, "", text)
      sub(/[ \t\r]+$/, "", text)
      return text
    }
    {
      line = trim($0)
      if (line == "<!-- gaia:uat-routing:start -->") { starts++; if (ends > 0) misordered = 1; inside = 1; next }
      if (line == "<!-- gaia:uat-routing:end -->") { ends++; if (starts == 0) misordered = 1; inside = 0; next }
      if (!inside || substr(line, 1, 1) != "|") next
      if (line ~ /^\|[ \t:|-]+$/) next
      sub(/^\|/, "", line)
      sub(/\|$/, "", line)
      cell_count = split(line, cells, "|")
      if (trim(cells[1]) == "uat_id") next
      row = trim(cells[1])
      for (cell = 2; cell <= cell_count; cell++) row = row "\t" trim(cells[cell])
      print row
    }
    END { if (starts != 1 || ends != 1 || misordered) exit 2 }
  ' "$routing_file") || status=$?
  if [ "$status" -ne 0 ]; then
    printf 'uat-routing: the gaia:uat-routing start and end markers are missing or unbalanced in %s\n' "$routing_file" >&2
    return 2
  fi
  if [ -n "$rows" ]; then
    printf '%s\n' "$rows"
  fi
}

uat_lib_validate_routing() {
  local spec_path="${1:-}" routing_file="${2:-}" spec_rows routing_rows spec_ids
  local problems=0 routed_ids='' e2e_paths='' row uat_id surface phase feature_folder file_name
  local cell_count spec_id_entry kebab_segment='[a-z0-9]+(-[a-z0-9]+)*'

  spec_rows=$(uat_lib_parse_spec "$spec_path") || return 2
  routing_rows=$(uat_lib_parse_routing "$routing_file") || return 2
  spec_ids=$(printf '%s\n' "$spec_rows" | cut -f1)

  while IFS= read -r row; do
    [ -n "$row" ] || continue
    cell_count=$(printf '%s' "$row" | awk -F'\t' '{ print NF }')
    IFS=$'\t' read -r uat_id surface phase feature_folder file_name _ <<<"$row"
    if [ "$cell_count" -ne 5 ]; then
      printf 'uat-routing: the row for %s has %s cells; expected uat_id, surface, phase, feature_folder, file_name\n' "${uat_id:-<blank>}" "$cell_count" >&2
      problems=$((problems + 1))
      continue
    fi
    if ! grep -qxF -- "$uat_id" <<<"$spec_ids"; then
      printf 'uat-routing: %s is routed but absent from the SPEC\n' "$uat_id" >&2
      problems=$((problems + 1))
    fi
    if grep -qxF -- "$uat_id" <<<"$routed_ids"; then
      printf 'uat-routing: %s has more than one row\n' "$uat_id" >&2
      problems=$((problems + 1))
    fi
    routed_ids="$routed_ids$uat_id"$'\n'
    if ! [[ "$phase" =~ ^[1-9][0-9]*$ ]]; then
      printf "uat-routing: %s has phase '%s'; expected a positive integer\n" "$uat_id" "$phase" >&2
      problems=$((problems + 1))
    fi
    case "$surface" in
      e2e)
        if ! [[ "$feature_folder" =~ ^$kebab_segment(/$kebab_segment)*$ ]]; then
          printf "uat-routing: %s is e2e with feature_folder '%s'; expected kebab-case segments\n" "$uat_id" "$feature_folder" >&2
          problems=$((problems + 1))
        fi
        if ! [[ "$file_name" =~ ^$kebab_segment\.spec\.ts$ ]]; then
          printf "uat-routing: %s is e2e with file_name '%s'; expected a kebab-case name ending .spec.ts\n" "$uat_id" "$file_name" >&2
          problems=$((problems + 1))
        fi
        if grep -qiE '(spec|uat|plan)-[0-9]' <<<"$feature_folder/$file_name"; then
          printf "uat-routing: %s's feature_folder or file_name carries a working-document id; name the behavior instead\n" "$uat_id" >&2
          problems=$((problems + 1))
        fi
        if grep -qxF -- "$feature_folder/$file_name" <<<"$e2e_paths"; then
          printf 'uat-routing: %s resolves to %s/%s, a path another e2e row already claims\n' "$uat_id" "$feature_folder" "$file_name" >&2
          problems=$((problems + 1))
        fi
        e2e_paths="$e2e_paths$feature_folder/$file_name"$'\n'
        ;;
      story | non-ui)
        if [ "$feature_folder" != "-" ] || [ "$file_name" != "-" ]; then
          printf "uat-routing: %s is %s; its feature_folder and file_name must both be '-'\n" "$uat_id" "$surface" >&2
          problems=$((problems + 1))
        fi
        ;;
      *)
        printf "uat-routing: %s has surface '%s'; expected e2e, story or non-ui\n" "$uat_id" "$surface" >&2
        problems=$((problems + 1))
        ;;
    esac
  done <<<"$routing_rows"

  while IFS= read -r spec_id_entry; do
    [ -n "$spec_id_entry" ] || continue
    if ! grep -qxF -- "$spec_id_entry" <<<"$routed_ids"; then
      printf 'uat-routing: %s has no routing row\n' "$spec_id_entry" >&2
      problems=$((problems + 1))
    fi
  done <<<"$spec_ids"

  [ "$problems" -eq 0 ] || return 2
}

uat_lib_e2e_directory() {
  local repo_root="${1:-}" packages_library packages_status=0 package_path
  packages_library="$_UAT_LIB_DIRECTORY/../../../.claude/hooks/lib/gaia-packages.sh"
  if [ ! -f "$packages_library" ]; then
    printf 'package library missing: %s. Next step: restore it from the GAIA release.\n' "$packages_library" >&2
    return 1
  fi
  # shellcheck disable=SC1090
  source "$packages_library"
  gaia_packages_load "$repo_root" || packages_status=$?
  if [ "$packages_status" -ne 0 ]; then
    printf '%s\n' "$GAIA_PACKAGES_ERROR" >&2
    return 1
  fi
  if ! package_path=$(gaia_package_dir frontend); then
    printf '%s\n' "gaia-packages: .gaia/packages.json registers no package named frontend. Next step: add a frontend entry, or delete the registry to use the built-in default." >&2
    return 1
  fi
  if [ "$package_path" = "." ]; then
    printf '%s\n' '.playwright/e2e'
  else
    printf '%s\n' "$package_path/.playwright/e2e"
  fi
}

uat_lib_embedded_hash() {
  local file="${1:-}" first_line='' marker_pattern='^// gaia-uat-contract sha256:([0-9a-f]{64})$'
  [ -f "$file" ] || return 0
  IFS= read -r first_line <"$file" || true
  if [[ "$first_line" =~ $marker_pattern ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  fi
}

uat_lib_body_hash() {
  local file="${1:-}"
  if command -v shasum >/dev/null 2>&1; then
    tail -n +2 "$file" | shasum -a 256 | awk '{ print $1 }'
  elif command -v sha256sum >/dev/null 2>&1; then
    tail -n +2 "$file" | sha256sum | awk '{ print $1 }'
  else
    printf '%s\n' 'uat-lib: no sha256 tool available (need shasum or sha256sum)' >&2
    return 1
  fi
}

# The first `// Given: `, `// When: ` and `// Then: ` lines carry the contract.
uat_lib_contract() {
  local file="${1:-}" given_text when_text then_text
  [ -f "$file" ] || return 1
  given_text=$(awk 'index($0, "// Given: ") == 1 { print substr($0, 11); found = 1; exit } END { if (!found) exit 1 }' "$file") || return 1
  when_text=$(awk 'index($0, "// When: ") == 1 { print substr($0, 10); found = 1; exit } END { if (!found) exit 1 }' "$file") || return 1
  then_text=$(awk 'index($0, "// Then: ") == 1 { print substr($0, 10); found = 1; exit } END { if (!found) exit 1 }' "$file") || return 1
  printf '%s\t%s\t%s\n' \
    "$(printf '%s' "$given_text" | uat_lib_whitespace_text)" \
    "$(printf '%s' "$when_text" | uat_lib_whitespace_text)" \
    "$(printf '%s' "$then_text" | uat_lib_whitespace_text)"
}
