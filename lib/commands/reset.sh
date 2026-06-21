#!/usr/bin/env bash
# grove reset — kill grove's panes and respawn them. Custom panes are left alone.

cmd_reset() {
  require_tmux
  local session wt
  if [ $# -ge 1 ]; then
    require_repo
    session="$(_session_for "$1")"
    tmux has-session -t "$session" 2>/dev/null \
      || die "no session for '$1' (try: grove attach $1)"
    wt="$(tmux show-options -t "$session" -v @grove-worktree 2>/dev/null || true)"
  else
    [ -n "${TMUX:-}" ] || die "not inside a tmux session — pass a branch: grove reset <branch>"
    session="$(tmux display-message -p '#{session_name}')"
    wt="$(tmux show-options -v @grove-worktree 2>/dev/null || true)"
  fi
  [ -n "$wt" ] || die "session '$session' is not a grove session (no @grove-worktree)"

  local pane_id pane_tag killed=0
  while read -r pane_id pane_tag; do
    [ -n "$pane_tag" ] || continue
    tmux kill-pane -t "$pane_id" 2>/dev/null && killed=$((killed + 1)) || true
  done < <(tmux list-panes -s -t "$session" -F '#{pane_id} #{@grove-pane}')
  [ "$killed" -gt 0 ] && info "killed $killed grove pane(s)"
  _spawn_grove_panes "$session" "$wt"
  info "grove panes respawned in $session"
}
