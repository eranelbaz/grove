#!/usr/bin/env bash
# grove base — show or set the diff-pane base for the current session.

cmd_base() {
  require_tmux
  [ -n "${TMUX:-}" ] || die "not inside a tmux session — attach via 'grove attach' first"
  local session current
  session="$(tmux display-message -p '#{session_name}')"
  if [ $# -eq 0 ]; then
    current="$(tmux show-options -v @grove-base 2>/dev/null || true)"
    printf '%s\n' "${current:-(unset)}"
    return
  fi
  require_repo
  local new_base="$1"
  git rev-parse --verify --quiet "$new_base" >/dev/null \
    || die "no such ref: $new_base"
  tmux set-option -t "$session" -q @grove-base "$new_base"
  info "base set to '$new_base' for session $session"
}
