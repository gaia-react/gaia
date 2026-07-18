#!/usr/bin/env bash
# PreToolUse Edit/Write/MultiEdit + Bash hook: deny writes to .gaia/manifest.json.
#
# .gaia/manifest.json is release-generated and lists only the files GAIA
# ships; adopter feature work never adds to it (.claude/rules/gaia-folder.md).
# This is a best-effort, defense-in-depth guard, not an airtight one: Bash
# vectors are unbounded, so it covers the well-known write shapes and stays
# biased toward allowing on ambiguity, per the serena-code-search-guard.sh
# precedent.
#
# Edit / Write / MultiEdit: inspect .tool_input.file_path. No exemption; no
# legitimate writer uses an edit tool on the manifest.
#
# Bash: inspect .tool_input.command.
#   - The command is split into segments on ;, &&, ||, and |. A segment is
#     exempt from write-vector inspection only when GAIA_MANIFEST_WRITE=
#     (any value) is one of its leading NAME=value environment-assignment
#     tokens, the shape the two legitimate Bash writers (the release CLI,
#     remove-i18n) use. The marker does not carry across a separator into a
#     later segment, and a marker appearing anywhere else in a segment (a
#     bare argument, a quoted string, a sed script) does not exempt it.
#   - A non-exempt segment is denied when it writes the guarded path via an
#     output redirect (>, >>), tee, sed -i (with or without a macOS ''
#     backup suffix), sponge, or cp/mv with the guarded path as destination.
#     Reading the manifest as a cp/mv source, or any other command, is
#     allowed.
set -euo pipefail

payload=$(cat)
tool_name=$(jq -r '.tool_name // empty' <<<"$payload")

DENY_MSG="BLOCKED: .gaia/manifest.json is release-generated and lists only files GAIA ships; feature work never adds to it. See .claude/rules/gaia-folder.md."

deny() {
  jq -n --arg r "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $r
    }
  }'
  exit 0
}

# Strip one matching pair of surrounding quotes from a token.
strip_quotes() {
  local s="$1"
  case "$s" in
    \"*\") s=${s#\"}; s=${s%\"} ;;
    \'*\') s=${s#\'}; s=${s%\'} ;;
  esac
  printf '%s' "$s"
}

# Guarded path (C1): after stripping surrounding quotes and a leading ./, the
# path equals .gaia/manifest.json or ends with /.gaia/manifest.json (absolute
# paths). Not guarded if any other character follows .json.
is_guarded_path() {
  local p
  p=$(strip_quotes "$1")
  p=${p#./}
  [[ "$p" == ".gaia/manifest.json" || "$p" == */.gaia/manifest.json ]]
}

case "$tool_name" in
  Edit | Write | MultiEdit)
    file_path=$(jq -r '.tool_input.file_path // empty' <<<"$payload")
    [[ -n "$file_path" ]] || exit 0
    is_guarded_path "$file_path" && deny "$DENY_MSG"
    exit 0
    ;;

  Bash)
    cmd=$(jq -r '.tool_input.command // empty' <<<"$payload")
    [[ -n "$cmd" ]] || exit 0

    read -r -a toks <<<"$cmd"
    n=${#toks[@]}

    # seg_start: 1 at the first token of a segment (command start, or right
    # after a ;/&&/||/| separator). seg_exempt is computed once per segment,
    # from its leading NAME=value environment-assignment tokens only.
    seg_start=1
    seg_exempt=0
    i=0
    while [ "$i" -lt "$n" ]; do
      tok="${toks[$i]}"

      case "$tok" in
        ';' | '&&' | '||' | '|')
          seg_start=1
          i=$((i + 1))
          continue
          ;;
      esac

      if [ "$seg_start" -eq 1 ]; then
        seg_exempt=0
        j=$i
        while [ "$j" -lt "$n" ]; do
          t2="${toks[$j]}"
          [[ "$t2" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || break
          case "$t2" in
            GAIA_MANIFEST_WRITE=*) seg_exempt=1 ;;
          esac
          j=$((j + 1))
        done
        seg_start=0
      fi

      if [ "$seg_exempt" -eq 0 ]; then
        case "$tok" in
          '>' | '>>')
            next="${toks[$((i + 1))]:-}"
            is_guarded_path "$next" && deny "$DENY_MSG"
            ;;
          tee | sponge)
            j=$((i + 1))
            while [ "$j" -lt "$n" ]; do
              t2="${toks[$j]}"
              case "$t2" in
                ';' | '&&' | '||' | '|') break ;;
              esac
              is_guarded_path "$t2" && deny "$DENY_MSG"
              j=$((j + 1))
            done
            ;;
          sed)
            has_i=0
            found=0
            j=$((i + 1))
            while [ "$j" -lt "$n" ]; do
              t2="${toks[$j]}"
              case "$t2" in
                ';' | '&&' | '||' | '|') break ;;
              esac
              [[ "$t2" == "-i" || "$t2" == -i* ]] && has_i=1
              is_guarded_path "$t2" && found=1
              j=$((j + 1))
            done
            [ "$has_i" -eq 1 ] && [ "$found" -eq 1 ] && deny "$DENY_MSG"
            ;;
          cp | mv)
            dest=""
            j=$((i + 1))
            while [ "$j" -lt "$n" ]; do
              t2="${toks[$j]}"
              case "$t2" in
                ';' | '&&' | '||' | '|') break ;;
              esac
              [[ "$t2" == -* ]] || dest="$t2"
              j=$((j + 1))
            done
            is_guarded_path "$dest" && deny "$DENY_MSG"
            ;;
        esac
      fi

      i=$((i + 1))
    done

    exit 0
    ;;

  *)
    exit 0
    ;;
esac
