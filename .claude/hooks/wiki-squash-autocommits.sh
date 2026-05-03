#!/bin/bash
# GAIA-owned wiki hook. Upstream contract: claude-obsidian/hooks/hooks.json::PostToolUse (auto-commit per Write|Edit)
# Why GAIA overrides: per-edit commits clutter history; we let the upstream
# PostToolUse fire as-is and then squash the trailing run of `wiki: auto-commit`
# commits into one at Stop. We do NOT mirror upstream's v1.6.0 addition of
# `.vault-meta/` to the staged paths — that directory is DragonScale-only and
# GAIA does not ship it.
#
# If on main, the squashed commit is pushed to a wiki/* branch and merged via
# PR rather than landing directly on main.

[ -d .git ] || exit 0

n=0
while git log "HEAD~$n" -1 --format='%s' 2>/dev/null | grep -q '^wiki: auto-commit '; do
  n=$((n + 1))
done

# Nothing to do if there are no wiki auto-commits at HEAD.
[ "$n" -ge 1 ] || exit 0

# Squash if 2+ consecutive auto-commits.
if [ "$n" -ge 2 ]; then
  git reset --soft "HEAD~$n" >/dev/null 2>&1 || exit 0
  # --no-verify: wiki-only squash, no source files changed — pre-commit gate is irrelevant here
  git commit -m "wiki: auto-commit $(date '+%Y-%m-%d %H:%M')" --no-verify >/dev/null 2>&1 || exit 0
fi

current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)

if [ "$current_branch" = "main" ]; then
  wiki_branch="wiki/$(date '+%Y-%m-%d-%H-%M')"

  # Push the squashed commit to a new wiki branch without checking it out.
  # This push is the safety net: even if PR creation or auto-merge fails,
  # the wiki content is preserved on a remote branch.
  git push origin "HEAD:refs/heads/$wiki_branch" >/dev/null 2>&1 || exit 0

  # Conditional-reset design:
  # The previous version of this hook ALWAYS reset local main + discarded
  # wiki/ + .raw/ working tree state immediately after the push, then tried
  # to create the PR. If PR creation or auto-merge failed, the wiki update
  # lived only on the remote wiki/<timestamp> branch — and the user's local
  # working tree had already been wiped. Silent loss.
  #
  # Now we only reset/discard if we have positive confirmation that the
  # wiki commit is on its way to main (auto-merge enabled, or instant
  # merge with no required checks). If anything fails, we preserve local
  # state and emit a stderr warning so Claude Code surfaces it to the user.
  should_reset=0

  if command -v gh >/dev/null 2>&1; then
    pr_create_ok=0
    gh pr create \
      --title "wiki: auto-commit $(date '+%Y-%m-%d %H:%M')" \
      --body "Automated wiki update." \
      --base main \
      --head "$wiki_branch" >/dev/null 2>&1 && pr_create_ok=1

    if [ "$pr_create_ok" = "1" ]; then
      merge_err=$(gh pr merge "$wiki_branch" --squash --auto 2>&1)
      merge_status=$?

      if [ "$merge_status" -eq 0 ]; then
        # Auto-merge enabled (or instant merge if no required checks).
        # Safe to reset local main; the commit is in flight.
        should_reset=1
      else
        # Auto-merge failed. Don't reset — preserve local state.
        if echo "$merge_err" | grep -qi 'auto merge\|autoMerge\|auto-merge'; then
          echo "WIKI_NEEDS_MANUAL_MERGE: Wiki changes are on branch '$wiki_branch' and a PR was created, but auto-merge is not enabled on this repository. Please either merge the PR manually or enable auto-merge in the repository settings (Settings → General → Allow auto-merge). Local working tree preserved." >&2
        else
          echo "WIKI_PR_MERGE_FAILED: branch '$wiki_branch' / PR was opened but merge failed: $merge_err. Local working tree preserved." >&2
        fi
      fi
    else
      echo "WIKI_PR_CREATE_FAILED: branch '$wiki_branch' was pushed but PR could not be opened. Local working tree preserved." >&2
    fi
  fi

  if [ "$should_reset" = "1" ]; then
    # Reset local main back to origin so it never advances ahead of remote main.
    # The commit is safe on the wiki branch + queued for merge.
    # --mixed preserves any non-wiki working-tree changes (e.g. README edits);
    # we then discard only wiki/ and .raw/ so they don't linger as unstaged files.
    git fetch origin main >/dev/null 2>&1
    git reset --mixed origin/main >/dev/null 2>&1 || true
    git checkout -- wiki/ .raw/ 2>/dev/null || true
    git clean -fd wiki/ .raw/ >/dev/null 2>&1 || true
  fi
fi

exit 0
