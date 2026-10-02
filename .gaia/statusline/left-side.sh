# shellcheck shell=bash
#
# Default left side of the GAIA statusline, used only when the user has no
# global `statusLine.command` of their own. Sourced by gaia-statusline.sh as
# "$GAIA_DIR/statusline/left-side.sh"; defines one function and runs nothing at
# source time.
#
# Shape: project | branch | model (effort) | context bar. The project is the
# MAIN checkout's folder name, so a linked worktree shows the main project; the
# branch carries a tree marker inside a linked worktree.
#
# The bar is colored from the shared threshold lib's bands (green below yellow,
# yellow from yellow, red from red, fire and skull markers above), the same
# bands the audit-loop checkpoint reads, so the bar and the checkpoint cannot
# disagree. Hot path: bash arithmetic and builtins only, plus the one git call
# for the branch.

# gaia_statusline_left <state-root> <session-dir> <is-worktree> <model> <effort> <used_percentage> <window_size> <used_tokens>
# Sets _GAIA_SL_LEFT to the rendered string (ANSI escapes included); returns 1
# and leaves it empty when there is nothing to show.
gaia_statusline_left() {
  local root="${1:-}" dir="${2:-}" is_wt="${3:-}" model="${4:-}" effort="${5:-}"
  local pct="${6:-}" window="${7:-}" tokens="${8:-}"
  local esc=$'\033' reset=$'\033[00m' out="" sep=" | " project branch effort_cap
  local int_part frac_part pct_int filled i bar="" color marker="" cfg ask_t ask_p line bands
  local yellow red fire skull
  _GAIA_SL_LEFT=""

  project="${root##*/}"
  [ -n "$project" ] && out="${esc}[01;34m${project}${reset}"

  if [ -n "$dir" ]; then
    branch=$(git -C "$dir" --no-optional-locks rev-parse --abbrev-ref HEAD 2>/dev/null) || branch=""
    if [ -n "$branch" ]; then
      [ "$is_wt" = "true" ] && branch="🌳 ${branch}"
      out="${out:+$out$sep}${esc}[01;32m${branch}${reset}"
    fi
  fi

  model="${model#Claude }"
  if [ -n "$effort" ]; then
    case "$effort" in
      xhigh) effort_cap="XHigh" ;;
      low) effort_cap="Low" ;;
      medium) effort_cap="Medium" ;;
      high) effort_cap="High" ;;
      max) effort_cap="Max" ;;
      *) effort_cap="$effort" ;;
    esac
    model="${model:+$model }(${effort_cap})"
  fi
  [ -n "$model" ] && out="${out:+$out$sep}${esc}[01;36m${model}${reset}"

  # The bar needs the percentage for fill and the percentage-derived token
  # count plus the window for color; without all three there is no honest bar.
  if [ -n "$pct" ] && [ -n "$window" ] && [ -n "$tokens" ] && command -v gaia_ctx_bands >/dev/null 2>&1; then
    int_part="${pct%%.*}"
    frac_part=""
    case "$pct" in *.*) frac_part="${pct#*.}" ;; esac
    pct_int=$((10#${int_part:-0}))
    case "$frac_part" in [5-9]*) pct_int=$((pct_int + 1)) ;; esac
    # round(pct / 10) from the integer part alone: exact, no float math.
    filled=$(((10#${int_part:-0} + 5) / 10))
    [ "$filled" -gt 10 ] && filled=10
    i=0
    while [ "$i" -lt 10 ]; do
      if [ "$i" -lt "$filled" ]; then bar="${bar}▓"; else bar="${bar}░"; fi
      i=$((i + 1))
    done
    color="${esc}[01;32m"
    if cfg=$(gaia_ctx_override "$root") && read -r ask_t ask_p <<<"$cfg" &&
      line=$(gaia_ctx_line "$window" "$ask_t" "$ask_p") &&
      bands=$(gaia_ctx_bands "$window" "$line") && read -r yellow red fire skull <<<"$bands"; then
      if [ "$tokens" -ge "$skull" ]; then
        color="${esc}[01;31m"
        marker=" 💀"
      elif [ "$tokens" -ge "$fire" ]; then
        color="${esc}[01;31m"
        marker=" 🔥"
      elif [ "$tokens" -ge "$red" ]; then
        color="${esc}[01;31m"
      elif [ "$tokens" -ge "$yellow" ]; then
        color="${esc}[01;33m"
      fi
    fi
    out="${out:+$out$sep}${color}${bar}${reset} ${pct_int}%${marker}"
  fi

  [ -n "$out" ] || return 1
  _GAIA_SL_LEFT="$out"
}
