#!/usr/bin/env bash
# grove clean — teardown, kill session, remove worktree, optionally delete branch.

cmd_clean() {
  [ $# -ge 1 ] || die "usage: grove clean <branch> [-f]"
  require_repo

  local branch force=""
  branch="$(resolve_branch "$1")" \
    || die "no branch matching '$1' — run 'grove list' to see available branches"
  case "${2:-}" in -f|--force) force="--force" ;; esac

  local root wt session
  root="$(main_root)"
  wt="$root/.worktrees/$branch"
  session="$(_session_for "$branch")"

  [ -d "$wt" ] \
    || die "branch '$branch' is not tracked by grove — run 'grove list' to see tracked branches"

  _run_hook teardown.sh "$branch" "$wt" ""
  tmux kill-session -t "$session" 2>/dev/null && info "killed session $session" || true

  # Surface the real error from `git worktree remove` instead of swallowing it —
  # otherwise dirty-tree failures look like silent successes and we'd then
  # offer to delete the branch underneath a still-checked-out worktree.
  local removed=0 remove_output
  if remove_output="$(git worktree remove $force "$wt" 2>&1)"; then
    info "removed worktree $wt"
    removed=1
  elif [ -n "$remove_output" ]; then
    printf 'grove: failed to remove worktree %s\n  %s\n' "$wt" "$remove_output" >&2
  fi
  git worktree prune

  if [ "$removed" -eq 1 ] && [ -t 0 ] && git show-ref --verify --quiet "refs/heads/$branch"; then
    read -r -p "delete branch '$branch'? [y/N] " ans
    case "$ans" in
      y|Y) git branch -D "$branch" && info "deleted branch $branch" ;;
      *)   info "kept branch $branch" ;;
    esac
  fi
}
