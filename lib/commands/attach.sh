#!/usr/bin/env bash
# grove attach — worktree + session for a branch that already exists.

cmd_attach() {
  local index="" arg="" have_index=0
  while [ $# -gt 0 ]; do
    case "$1" in
      -i|--index)
        [ $# -ge 2 ] || die "grove attach: -i requires an index"
        index="$2"; have_index=1; shift 2 ;;
      *) arg="$1"; shift ;;
    esac
  done

  if [ "$have_index" = 1 ]; then _attach_by_index "$index"; return; fi

  [ -n "$arg" ] || die "usage: grove attach <branch> | -i <index>"
  require_repo
  local branch
  branch="$(resolve_branch "$arg")" \
    || die "no branch matching '$arg' — use: grove create $arg [from-branch]"
  _attach_branch "$branch"
}

_attach_by_index() {
  local n="$1"
  case "$n" in
    ''|*[!0-9]*) die "grove attach: index must be a non-negative integer, got '$n'" ;;
  esac
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    local -a paths=()
    local p
    while read -r p; do paths+=("$p"); done < <(_repo_worktree_paths)
    [ "$n" -lt "${#paths[@]}" ] \
      || die "grove attach: index $n out of range (0..$(( ${#paths[@]} - 1 )))"
    local branch
    branch="$(git -C "${paths[$n]}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
    _attach_branch "$branch"
  else
    require_tmux
    local -a rows=()
    local r
    while IFS= read -r r; do rows+=("$r"); done < <(_global_session_rows)
    [ "${#rows[@]}" -gt 0 ] || die "grove attach: no grove sessions running"
    [ "$n" -lt "${#rows[@]}" ] \
      || die "grove attach: index $n out of range (0..$(( ${#rows[@]} - 1 )))"
    local session="${rows[$n]%%|*}"
    info "attaching existing session: $session"; attach "$session"
  fi
}

_attach_branch() {
  local branch="$1"
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
    tmux set-option -t "$session" -q status-left-length "$(( ${#session} + 10 ))"
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
