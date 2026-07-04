#!/usr/bin/env bash
# cost-consolidate.sh: shared consolidate-and-flatten routine for a
# spec-derived feature's scattered cost.md sections.
#
# A merged spec-derived feature's cost is scattered across the SPEC-root
# cost.md (its `## SPEC` section, written by token-tally.sh --action spec)
# and the plan folder's cost.md (`## Planning` + `## Execution`, written by
# --action plan/execute). At archive time these splice into one dollars-led
# SPEC-root cost.md with a grand-total `## Total` section, the plan folder's
# SUMMARY.md moves up beside SPEC.md, and the plan[-N]/ subfolder is removed,
# so the archived folder ends up exactly AUDIT.md, SPEC.md, SUMMARY.md,
# cost.md. Both archive entry points -- spec-close.md's Archive branch and the
# spec-archive-merged.sh safety-net sweep -- invoke this ONE routine so they
# cannot diverge. plan-archive.sh's spec-less arm calls the second mode below
# to give a spec-less one-off plan its own grand total.
#
# Two modes:
#
#   cost-consolidate.sh spec <repo_root> <spec_id>
#     Runs against the ACTIVE SPEC folder
#     <repo_root>/.gaia/local/specs/<spec_id>/, BEFORE the caller moves it to
#     archived/. Locates the plan folder that actually executed (plan,
#     plan-2, plan-3, ... -- the highest-numbered one with an `## Execution`
#     section, or the plain `plan` if none has one), splices its Planning and
#     Execution sections plus the SPEC-root's own SPEC section and a grand
#     Total into one cost.md, moves SUMMARY.md up if not already there, and
#     removes every plan/plan-N subfolder. Idempotent: a second run over an
#     already-flat folder (no plan/ folder left) falls back to whatever
#     Planning/Execution the prior run already spliced into cost.md, so the
#     result is unchanged.
#
#   cost-consolidate.sh plan-total <cost_md_path>
#     Appends/refreshes a `## Total` section on a spec-less plan's cost.md
#     (Planning + Execution only, no SPEC section). Idempotent: replaces
#     whatever Total was already there.
#
# Grand total (shared by both modes): sum each present section's rendered
# `**Est. cost (USD):** $X.XX` figure at the same 2-decimal rounding, plus the
# four token buckets beneath. If any present section has no priced figure or
# is itself marked `_Lower bound: ..._`, the total is marked a lower bound
# too -- never a fabricated number. If no section has a priced figure at all,
# the total renders as unavailable.
#
# Guarantees, matching plan-archive.sh and spec-archive-merged.sh:
#   - Exit code is ALWAYS 0 (advisory / fail-open); never blocks a caller.
#   - stdout carries at most one human summary line; diagnostics to stderr.
#   - Never fabricates a dollar or token figure for missing/partial input.
set -uo pipefail

# extract_section prints a `## <title>` block from a cost.md: the heading
# line through the line before the next `## ` heading (or EOF), trailing
# blanks trimmed. Absent section -> empty output. Mirrors token-tally.sh's
# own extract_section, so a block this script reads or writes round-trips
# byte-for-byte through either implementation.
extract_section() {
  awk -v hdr="## $2" '
    $0 == hdr { inb = 1 }
    inb && $0 != hdr && /^## / { inb = 0 }
    inb { buf = buf $0 "\n" }
    END { sub(/\n+$/, "", buf); if (length(buf)) print buf }
  ' "$1" 2>/dev/null
}

# _plan_num validates a folder basename is the bare "plan" or "plan-<digits>"
# shape and prints its ordinal (bare plan -> 1, plan-N -> N) so the highest
# value wins the "which plan folder executed" comparison. Anything else
# (garbage, a non-numeric suffix) fails, so it is never matched or pruned.
_plan_num() {
  case "$1" in
    plan) printf '1' ;;
    plan-*)
      local n="${1#plan-}"
      case "$n" in
        ''|*[!0-9]*) return 1 ;;
      esac
      printf '%s' "$n"
      ;;
    *) return 1 ;;
  esac
}

# ---------- grand-total helpers (shared by both modes) ----------

# _section_dollar prints a section's priced figure (no `$`) from its
# `**Est. cost (USD):** $X.XX` line, or nothing if the section is unpriced.
_section_dollar() {
  # shellcheck disable=SC2016 # sed script is intentionally single-quoted
  printf '%s\n' "$1" | sed -nE 's/^\*\*Est\. cost \(USD\):\*\* \$([0-9]+\.[0-9]{2})$/\1/p' | head -1
}

# _section_is_lower_bound: does the section carry any `_Lower bound: ..._` marker?
_section_is_lower_bound() {
  printf '%s\n' "$1" | grep -q '^_Lower bound:'
}

# _bucket_value prints a section's raw bucket-table cell for the given label
# ("Fresh input", "Cache write", "Cache read", "Output"), or nothing if the
# section carries no such row.
_bucket_value() {
  printf '%s\n' "$1" | awk -F'|' -v want="$2" '
    NF >= 4 {
      label = $2
      gsub(/^[ \t]+|[ \t]+$/, "", label)
      if (label == want) {
        v = $3
        gsub(/^[ \t]+|[ \t]+$/, "", v)
        print v
        exit
      }
    }
  '
}

# _bucket_int is _bucket_value coerced to an integer (0 when absent or
# unparseable), safe to feed straight into shell arithmetic.
_bucket_int() {
  local v
  v="$(_bucket_value "$1" "$2")"
  case "$v" in
    ''|*[!0-9]*) printf '0' ;;
    *) printf '%s' "$v" ;;
  esac
}

# render_grand_total takes each present section's full text block (empty
# args for an absent section) and prints a `## Total` block: the dollars
# headline (or an unavailable marker when nothing is priced), a lower-bound
# marker when any present section is itself unpriced or marked a lower
# bound, and the summed token-bucket table.
render_grand_total() {
  local sec d
  local sum_dollars="0.00" any_priced=0 any_floor=0
  local sum_fresh=0 sum_cwrite=0 sum_cread=0 sum_out=0

  for sec in "$@"; do
    [[ -n "$sec" ]] || continue
    d="$(_section_dollar "$sec")"
    if [[ -n "$d" ]]; then
      any_priced=1
      sum_dollars="$(awk -v a="$sum_dollars" -v b="$d" 'BEGIN { printf "%.2f", a + b }')"
    else
      any_floor=1
    fi
    _section_is_lower_bound "$sec" && any_floor=1

    sum_fresh=$((sum_fresh + $(_bucket_int "$sec" "Fresh input")))
    sum_cwrite=$((sum_cwrite + $(_bucket_int "$sec" "Cache write")))
    sum_cread=$((sum_cread + $(_bucket_int "$sec" "Cache read")))
    sum_out=$((sum_out + $(_bucket_int "$sec" "Output")))
  done
  local sum_total=$((sum_fresh + sum_cwrite + sum_cread + sum_out))

  printf '## Total\n\n'
  if [[ "$any_priced" -eq 1 ]]; then
    printf '**Est. cost (USD):** $%s\n' "$sum_dollars"
    [[ "$any_floor" -eq 1 ]] && printf '_Lower bound: one or more sections are a lower bound or unavailable; the total is a floor._\n'
  else
    printf '_Est. cost (USD): unavailable (no section carries a priced figure)._\n'
  fi
  printf '\n| Bucket | Tokens |\n'
  printf '| --- | --- |\n'
  printf '| Fresh input | %s |\n' "$sum_fresh"
  printf '| Cache write | %s |\n' "$sum_cwrite"
  printf '| Cache read | %s |\n' "$sum_cread"
  printf '| Output | %s |\n' "$sum_out"
  printf '| **Total** | %s |\n' "$sum_total"
}

# ---------- mode: spec ----------

mode_spec() {
  local repo_root="${1%/}" spec_id="$2"
  if [[ -z "$repo_root" || -z "$spec_id" ]]; then
    echo "cost-consolidate: spec mode needs <repo_root> <spec_id>" >&2
    return 0
  fi

  local spec_folder="$repo_root/.gaia/local/specs/$spec_id"
  if [[ ! -d "$spec_folder" ]]; then
    echo "cost-consolidate: $spec_folder does not exist; nothing to consolidate" >&2
    return 0
  fi
  local spec_cost="$spec_folder/cost.md"

  # Locate the plan folder that actually executed (AUDIT directive 3): among
  # plan, plan-2, plan-3, ..., the highest-numbered one whose cost.md carries
  # an `## Execution` section; if none has Execution, fall back to the plain
  # plan.
  local best_plan="" best_num=-1 has_bare_plan=0
  local d name num
  for d in "$spec_folder"/plan "$spec_folder"/plan-*; do
    [[ -d "$d" ]] || continue
    name="${d##*/}"
    num="$(_plan_num "$name")" || continue
    [[ "$name" == "plan" ]] && has_bare_plan=1
    if [[ -f "$d/cost.md" ]] && grep -qx '## Execution' "$d/cost.md" 2>/dev/null; then
      if (( num > best_num )); then
        best_num=$num
        best_plan="$d"
      fi
    fi
  done
  if [[ -z "$best_plan" && "$has_bare_plan" -eq 1 ]]; then
    best_plan="$spec_folder/plan"
  fi

  # Read sections. Start from whatever is already in the SPEC-root cost.md
  # (the idempotency fallback: a second run finds no plan folder left and
  # must reproduce what the first run already spliced in), then let a live
  # plan folder's fresh Planning/Execution override.
  local spec_section="" planning_section="" execution_section=""
  if [[ -f "$spec_cost" ]]; then
    spec_section="$(extract_section "$spec_cost" "SPEC")"
    planning_section="$(extract_section "$spec_cost" "Planning")"
    execution_section="$(extract_section "$spec_cost" "Execution")"
  fi
  if [[ -n "$best_plan" && -f "$best_plan/cost.md" ]]; then
    local fresh_planning fresh_execution
    fresh_planning="$(extract_section "$best_plan/cost.md" "Planning")"
    fresh_execution="$(extract_section "$best_plan/cost.md" "Execution")"
    [[ -n "$fresh_planning" ]] && planning_section="$fresh_planning"
    [[ -n "$fresh_execution" ]] && execution_section="$fresh_execution"
  fi

  # Move SUMMARY.md up beside SPEC.md, never clobbering one already there.
  if [[ -n "$best_plan" && -f "$best_plan/SUMMARY.md" && ! -f "$spec_folder/SUMMARY.md" ]]; then
    mv "$best_plan/SUMMARY.md" "$spec_folder/SUMMARY.md" 2>/dev/null || true
  fi

  # Splice SPEC + Planning + Execution + Total into one dollars-led cost.md.
  local total_section
  total_section="$(render_grand_total "$spec_section" "$planning_section" "$execution_section")"
  {
    printf '# Cost: %s\n\n' "$spec_id"
    [[ -n "$spec_section" ]] && printf '%s\n\n' "$spec_section"
    [[ -n "$planning_section" ]] && printf '%s\n\n' "$planning_section"
    [[ -n "$execution_section" ]] && printf '%s\n\n' "$execution_section"
    printf '%s\n' "$total_section"
  } >"$spec_cost" 2>/dev/null || echo "cost-consolidate: cost.md write failed: $spec_cost" >&2

  # Prune every plan/plan-N subfolder, superseded or not.
  for d in "$spec_folder"/plan "$spec_folder"/plan-*; do
    [[ -d "$d" ]] || continue
    name="${d##*/}"
    _plan_num "$name" >/dev/null 2>&1 || continue
    rm -rf -- "$d"
  done

  printf 'Consolidated cost for %s: cost.md spliced (SPEC/Planning/Execution/Total), plan folder(s) pruned\n' "$spec_id"
}

# ---------- mode: plan-total ----------

mode_plan_total() {
  local cost_md="$1"
  if [[ -z "$cost_md" ]]; then
    echo "cost-consolidate: plan-total mode needs <cost_md_path>" >&2
    return 0
  fi
  if [[ ! -f "$cost_md" ]]; then
    echo "cost-consolidate: $cost_md not found; skipping plan-total" >&2
    return 0
  fi

  # preamble is everything before the first `## ` heading (the `# Cost: ...`
  # title line), preserved verbatim.
  local preamble planning execution total_section
  preamble="$(awk '/^## /{exit} {print}' "$cost_md")"
  planning="$(extract_section "$cost_md" "Planning")"
  execution="$(extract_section "$cost_md" "Execution")"
  total_section="$(render_grand_total "" "$planning" "$execution")"

  {
    [[ -n "$preamble" ]] && printf '%s\n\n' "$preamble"
    [[ -n "$planning" ]] && printf '%s\n\n' "$planning"
    [[ -n "$execution" ]] && printf '%s\n\n' "$execution"
    printf '%s\n' "$total_section"
  } >"$cost_md" 2>/dev/null || { echo "cost-consolidate: plan-total write failed: $cost_md" >&2; return 0; }

  printf 'Added grand total to %s\n' "$cost_md"
}

# ---------- dispatch ----------

case "${1:-}" in
  spec)
    mode_spec "${2:-}" "${3:-}"
    ;;
  plan-total)
    mode_plan_total "${2:-}"
    ;;
  *)
    echo "usage: cost-consolidate.sh spec <repo_root> <spec_id> | plan-total <cost_md_path>" >&2
    ;;
esac

exit 0
