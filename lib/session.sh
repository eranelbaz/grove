#!/usr/bin/env bash
# grove session — tmux session lifecycle (start, attach, tag, spawn panes).

attach() {
  local session="$1"
  if [ -n "${TMUX:-}" ]; then tmux switch-client -t "$session"
  else tmux attach-session -t "$session"; fi
}

_tag_session() {
  local session="$1" repo="$2" branch="$3" wt="$4" base="${5:-}"
  tmux set-option -t "$session" -q @grove-repo "$repo"
  tmux set-option -t "$session" -q @grove-branch "$branch"
  tmux set-option -t "$session" -q @grove-worktree "$wt"
  [ -n "$base" ] && tmux set-option -t "$session" -q @grove-base "$base"
  return 0
}

_start_session() {
  local branch="$1" wt="$2" base="${3:-}" setup_cmd="${4:-}" session repo
  session="$(_session_for "$branch")"
  repo="$(basename "$(main_root)")"
  if tmux has-session -t "$session" 2>/dev/null; then
    _tag_session "$session" "$repo" "$branch" "$wt" "$base"
    info "attaching existing session: $session"; attach "$session"; return
  fi
  info "starting session: $session"
  local cols rows
  read -r cols rows <<<"$(_client_size)"
  tmux new-session -d -s "$session" -c "$wt" -x "$cols" -y "$rows"
  _tag_session "$session" "$repo" "$branch" "$wt" "$base"
  if [ -n "$setup_cmd" ]; then
    tmux send-keys -t "$session" "$setup_cmd" Enter
  fi
  attach "$session"
}

_cmd_setup() {
  local branch="$1" wt="$2" from="${3:-}"
  _run_hook setup.sh "$branch" "$wt" "$from"
}

# Target may be a session, session:window_id, or pane_id — anything tmux's -t
# flag accepts. Splits the active pane of that target and pins our 3 panes
# on the right.
_spawn_grove_panes() {
  local target="$1" wt="$2" tree_pane status_pane pr_pane commits_pane
  tree_pane="$(tmux split-window -h -p "$DIFF_PANE_WIDTH_PCT" -t "$target" -c "$wt" -P -F '#{pane_id}' \
                "exec $GROVE_BIN _pane diff" 2>/dev/null || true)"
  if [ -z "$tree_pane" ]; then
    info "grove panes skipped (split failed — terminal may be too narrow)"
    return
  fi
  tmux set-option -p -t "$tree_pane" -q @grove-pane tree
  commits_pane="$(tmux split-window -v -l "$COMMITS_PANE_LINES" -t "$tree_pane" -c "$wt" -P -F '#{pane_id}' \
                    "exec $GROVE_BIN _pane commits" 2>/dev/null || true)"
  [ -n "$commits_pane" ] && tmux set-option -p -t "$commits_pane" -q @grove-pane commits
  pr_pane="$(tmux split-window -v -l "$PR_PANE_LINES" -t "$tree_pane" -c "$wt" -P -F '#{pane_id}' \
               "exec $GROVE_BIN _pane pr" 2>/dev/null || true)"
  [ -n "$pr_pane" ] && tmux set-option -p -t "$pr_pane" -q @grove-pane pr
  status_pane="$(tmux split-window -v -l "$STATUS_PANE_LINES" -t "$tree_pane" -c "$wt" -P -F '#{pane_id}' \
                   "exec $GROVE_BIN _pane status" 2>/dev/null || true)"
  [ -n "$status_pane" ] && tmux set-option -p -t "$status_pane" -q @grove-pane status
  tmux select-pane -t "$target" -L 2>/dev/null || true
}

# Re-fires whenever a window is added to a grove session so the right-side
# panes appear in every window, not just the first one.
_install_window_hook() {
  local session="$1"
  tmux set-hook -t "$session" after-new-window \
    "run-shell -b \"$GROVE_BIN _pin '#{session_name}:#{window_id}'\""
}

_cmd_pin() {
  local target="${1:-}"
  [ -n "$target" ] || die "_pin requires a target"
  local session="${target%%:*}" wt
  wt="$(tmux show-options -t "$session" -v @grove-worktree 2>/dev/null || true)"
  [ -n "$wt" ] || return 0
  _spawn_grove_panes "$target" "$wt"
}

# One-shot client-attached handler used by cmd_create. Splits happen here (not
# pre-attach) so they land against the actual client-sized window — pre-attach
# splits can race with switch-client's resize and end up against the wrong dims.
_cmd_attached_spawn() {
  local session="${1:-}"
  [ -n "$session" ] || return 0
  local wt
  wt="$(tmux show-options -t "$session" -v @grove-worktree 2>/dev/null || true)"
  [ -n "$wt" ] || return 0
  tmux set-hook -t "$session" -u client-attached
  _reset_panes "$session" "$wt"
}

_restart_session_at() {
  local branch="$1" wt="$2" session base existing_wt
  command -v tmux >/dev/null 2>&1 || return 0
  session="$(_session_for "$branch")"
  if tmux has-session -t "$session" 2>/dev/null; then
    existing_wt="$(tmux show-options -t "$session" -v @grove-worktree 2>/dev/null || true)"
    if [ -n "$existing_wt" ] && [ "$existing_wt" != "$wt" ]; then
      tmux kill-session -t "$session" 2>/dev/null && info "killed stale session $session ($existing_wt)" || true
    fi
  fi
  base="$(_default_base)"
  _start_session "$branch" "$wt" "$base"
}
