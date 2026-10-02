# shellcheck shell=bash
#
# Default left side of the GAIA statusline, used only when the user has no
# global `statusLine.command` of their own. Sourced by gaia-statusline.sh as
# "$GAIA_DIRECTORY/statusline/left-side.sh"; defines one function and runs nothing at
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

# gaia_statusline_left <state-root> <session-directory> <is-worktree> <model> <effort> <used_percentage> <window_size> <used_tokens>
# Sets _GAIA_STATUSLINE_LEFT to the rendered string (ANSI escapes included); returns 1
# and leaves it empty when there is nothing to show.
gaia_statusline_left() {
  local root="${1:-}" session_directory="${2:-}" is_worktree="${3:-}" model="${4:-}" effort="${5:-}"
  local used_percentage="${6:-}" window="${7:-}" tokens="${8:-}"
  local escape_character=$'\033' reset=$'\033[00m' rendered="" separator=" | " project branch effort_capitalized
  local integer_part fraction_part used_percentage_rounded filled i bar="" color marker="" checkpoint_override ask_tokens ask_window_percent line bands
  local yellow red fire skull
  _GAIA_STATUSLINE_LEFT=""

  project="${root##*/}"
  [ -n "$project" ] && rendered="${escape_character}[01;34m${project}${reset}"

  if [ -n "$session_directory" ]; then
    branch=$(git -C "$session_directory" --no-optional-locks rev-parse --abbrev-ref HEAD 2>/dev/null) || branch=""
    if [ -n "$branch" ]; then
      [ "$is_worktree" = "true" ] && branch="🌳 ${branch}"
      rendered="${rendered:+$rendered$separator}${escape_character}[01;32m${branch}${reset}"
    fi
  fi

  model="${model#Claude }"
  if [ -n "$effort" ]; then
    case "$effort" in
      xhigh) effort_capitalized="XHigh" ;;
      low) effort_capitalized="Low" ;;
      medium) effort_capitalized="Medium" ;;
      high) effort_capitalized="High" ;;
      max) effort_capitalized="Max" ;;
      *) effort_capitalized="$effort" ;;
    esac
    model="${model:+$model }(${effort_capitalized})"
  fi
  [ -n "$model" ] && rendered="${rendered:+$rendered$separator}${escape_character}[01;36m${model}${reset}"

  # The bar needs the percentage for fill and the percentage-derived token
  # count plus the window for color; without all three there is no honest bar.
  if [ -n "$used_percentage" ] && [ -n "$window" ] && [ -n "$tokens" ] && command -v gaia_context_bands >/dev/null 2>&1; then
    integer_part="${used_percentage%%.*}"
    fraction_part=""
    case "$used_percentage" in *.*) fraction_part="${used_percentage#*.}" ;; esac
    used_percentage_rounded=$((10#${integer_part:-0}))
    case "$fraction_part" in [5-9]*) used_percentage_rounded=$((used_percentage_rounded + 1)) ;; esac
    # round(used_percentage / 10) from the integer part alone: exact, no float math.
    filled=$(((10#${integer_part:-0} + 5) / 10))
    [ "$filled" -gt 10 ] && filled=10
    i=0
    while [ "$i" -lt 10 ]; do
      if [ "$i" -lt "$filled" ]; then bar="${bar}▓"; else bar="${bar}░"; fi
      i=$((i + 1))
    done
    color="${escape_character}[01;32m"
    if checkpoint_override=$(gaia_context_override "$root") && read -r ask_tokens ask_window_percent <<<"$checkpoint_override" &&
      line=$(gaia_context_line "$window" "$ask_tokens" "$ask_window_percent") &&
      bands=$(gaia_context_bands "$window" "$line") && read -r yellow red fire skull <<<"$bands"; then
      if [ "$tokens" -ge "$skull" ]; then
        color="${escape_character}[01;31m"
        marker=" 💀"
      elif [ "$tokens" -ge "$fire" ]; then
        color="${escape_character}[01;31m"
        marker=" 🔥"
      elif [ "$tokens" -ge "$red" ]; then
        color="${escape_character}[01;31m"
      elif [ "$tokens" -ge "$yellow" ]; then
        color="${escape_character}[01;33m"
      fi
    fi
    rendered="${rendered:+$rendered$separator}${color}${bar}${reset} ${used_percentage_rounded}%${marker}"
  fi

  [ -n "$rendered" ] || return 1
  _GAIA_STATUSLINE_LEFT="$rendered"
}
