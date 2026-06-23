#!/usr/bin/env bash
# grove create — new branch + worktree + tmux session.

cmd_create() {
  [ $# -ge 1 ] || die "usage: grove create <branch> [from-branch]"
  require_tmux
  require_repo
  local branch="$1" from="${2:-}"
  local root wt base
  root="$(main_root)"; wt="$root/.worktrees/$branch"
  base="${from:-$(git rev-parse --abbrev-ref HEAD)}"

  git show-ref --verify --quiet "refs/heads/$branch" \
    && die "branch '$branch' already exists — use: grove attach $branch"

  if [ ! -d "$wt" ]; then
    ensure_excluded "$root"
    info "new branch '$branch' from '$base'"
    git worktree add -b "$branch" "$wt" "$base"
  fi
  _start_session "$branch" "$wt" "$base" "$GROVE_BIN _setup '$branch' '$wt' '$from'"
}
