#!/bin/bash
# GAIA "preferred base" statusline renderer.
#
# Self-contained left-side renderer: project | branch | model | context-bar.
# Vendored so /gaia-init can offer it as either a global install or a
# project-only base.
#
# Reads JSON from stdin (Claude Code convention) and prints a single line.
# No network calls. No `set -e`; partial failure must degrade gracefully.

input=$(cat)

if command -v jq >/dev/null 2>&1; then
  cwd=$(printf '%s' "$input" | jq -r '.workspace.current_dir // empty' 2>/dev/null)
  [ -z "$cwd" ] && cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
  model=$(printf '%s' "$input" | jq -r '.model.display_name // empty' 2>/dev/null | sed 's/^Claude //')
  effort=$(printf '%s' "$input" | jq -r '.effortLevel // empty' 2>/dev/null)
  used_pct=$(printf '%s' "$input" | jq -r '.context_window.used_percentage // empty' 2>/dev/null)
else
  cwd=""
  model=""
  effort=""
  used_pct=""
fi
[ -z "$cwd" ] && cwd="$PWD"

if git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1; then
  git_root=$(git -C "$cwd" --no-optional-locks rev-parse --show-toplevel 2>/dev/null)
  project=$(basename "$git_root")
  branch=$(git -C "$cwd" --no-optional-locks rev-parse --abbrev-ref HEAD 2>/dev/null)
  git_info=$(printf '\033[01;34m%s\033[00m | \033[01;32m%s\033[00m' "$project" "$branch")
else
  project=$(basename "$cwd")
  git_info=$(printf '\033[01;34m%s\033[00m' "$project")
fi

if [ -n "$effort" ]; then
  effort_cap=$(printf '%s' "$effort" | awk '{print toupper(substr($0,1,1)) tolower(substr($0,2))}')
  model="${model} (${effort_cap})"
fi

context_bar=""
if [ -n "$used_pct" ]; then
  filled=$(printf '%s' "$used_pct" | awk '{printf "%d", ($1 / 10 + 0.5)}')
  [ -z "$filled" ] && filled=0
  [ "$filled" -gt 10 ] && filled=10
  empty=$((10 - filled))
  bar=""
  for _ in $(seq 1 "$filled" 2>/dev/null); do bar="${bar}▓"; done
  for _ in $(seq 1 "$empty" 2>/dev/null); do bar="${bar}░"; done
  pct_int=$(printf '%.0f' "$used_pct" 2>/dev/null)
  [ -z "$pct_int" ] && pct_int=0
  if [ "$pct_int" -ge 80 ]; then
    color="\033[01;31m"
  elif [ "$pct_int" -ge 50 ]; then
    color="\033[01;33m"
  else
    color="\033[01;32m"
  fi
  context_bar=$(printf "${color}%s\033[00m %d%%" "$bar" "$pct_int")
fi

out=""
sep=""
[ -n "$git_info" ] && { out="${out}${sep}${git_info}"; sep=" | "; }
[ -n "$model" ] && { out="${out}${sep}\033[01;36m${model}\033[00m"; sep=" | "; }
[ -n "$context_bar" ] && { out="${out}${sep}${context_bar}"; sep=" | "; }

printf '%b' "${out:-Claude Code}"
