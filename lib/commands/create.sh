#!/usr/bin/env bash
# grove create — new branch + worktree + tmux session.

cmd_create() {
  [ $# -ge 1 ] || die "usage: grove create <branch> [from-branch]"
  require_tmux
  require_repo
  local branch="$1" from="${2:-}"
  local root wt base session repo
  root="$(main_root)"; wt="$root/.worktrees/$branch"
  base="${from:-$(git rev-parse --abbrev-ref HEAD)}"

  git show-ref --verify --quiet "refs/heads/$branch" \
    && die "branch '$branch' already exists — use: grove attach $branch"

  if [ ! -d "$wt" ]; then
    ensure_excluded "$root"
    info "new branch '$branch' from '$base'"
    git worktree add -b "$branch" "$wt" "$base"
  fi

  session="$(_session_for "$branch")"
  repo="$(basename "$root")"
  info "starting session: $session"
  tmux new-session -d -s "$session" -c "$wt"
  _tag_session "$session" "$repo" "$branch" "$wt" "$base"
  tmux set-hook -t "$session" client-attached \
    "run-shell -b \"$GROVE_BIN _attached '$session'\""
  tmux send-keys -t "$session" "$GROVE_BIN _setup '$branch' '$wt' '$from'" Enter
  attach "$session"
}
