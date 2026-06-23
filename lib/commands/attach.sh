#!/usr/bin/env bash
# grove attach — worktree + session for a branch that already exists.

cmd_attach() {
  [ $# -ge 1 ] || die "usage: grove attach <branch>"
  require_repo
  local branch
  branch="$(resolve_branch "$1")" \
    || die "no branch matching '$1' — use: grove create $1 [from-branch]"
  local root wt session base existing_path
  root="$(main_root)"; wt="$root/.worktrees/$branch"

  existing_path="$(_worktree_path_for "$branch")"
  if [ -n "$existing_path" ] && [ "$existing_path" != "$wt" ]; then
    die "branch '$branch' is already checked out at $existing_path — use: grove migrate $branch"
  fi

  require_tmux
  session="$(_session_for "$branch")"
  base="$(_default_base)"

  if tmux has-session -t "$session" 2>/dev/null; then
    info "attaching existing session: $session"; attach "$session"; return
  fi
  if [ ! -d "$wt" ]; then
    ensure_excluded "$root"
    info "worktree for existing branch '$branch'"
    git worktree add "$wt" "$branch"
    _run_hook setup.sh "$branch" "$wt" ""
  fi
  _start_session "$branch" "$wt" "$base"
}
