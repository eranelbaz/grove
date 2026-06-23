#!/usr/bin/env bash
# grove reset — kill grove's panes and respawn them. Custom panes are left alone.

cmd_reset() {
  require_tmux
  if [ $# -ge 1 ]; then
    require_repo
    local arg
    for arg in "$@"; do
      _reset_one "$arg" || true
    done
    return
  fi

  [ -n "${TMUX:-}" ] || die "not inside a tmux session — pass a branch: grove reset <branch>..."
  local session wt
  session="$(tmux display-message -p '#{session_name}')"
  wt="$(tmux show-options -v @grove-worktree 2>/dev/null || true)"
  [ -n "$wt" ] || die "session '$session' is not a grove session (no @grove-worktree)"
  _reset_panes "$session" "$wt"
}

_reset_one() {
  local input="$1" branch session wt
  branch="$(resolve_branch "$input")" || {
    printf 'grove: no branch matching %q — skipping\n' "$input" >&2
    return 1
  }
  session="$(_session_for "$branch")"
  if ! tmux has-session -t "$session" 2>/dev/null; then
    printf 'grove: no session for %q (try: grove attach %s) — skipping\n' "$input" "$branch" >&2
    return 1
  fi
  wt="$(tmux show-options -t "$session" -v @grove-worktree 2>/dev/null || true)"
  if [ -z "$wt" ]; then
    printf 'grove: session %q is not a grove session (no @grove-worktree) — skipping\n' "$session" >&2
    return 1
  fi
  _reset_panes "$session" "$wt"
}

_reset_panes() {
  local session="$1" wt="$2"
  local pane_id pane_tag killed=0
  while read -r pane_id pane_tag; do
    [ -n "$pane_tag" ] || continue
    tmux kill-pane -t "$pane_id" 2>/dev/null && killed=$((killed + 1)) || true
  done < <(tmux list-panes -s -t "$session" -F '#{pane_id} #{@grove-pane}')
  [ "$killed" -gt 0 ] && info "killed $killed grove pane(s) in $session"
  local window_id
  while read -r window_id; do
    _spawn_grove_panes "$session:$window_id" "$wt"
  done < <(tmux list-windows -t "$session" -F '#{window_id}')
  _install_window_hook "$session"
  info "grove panes respawned in $session"
}
