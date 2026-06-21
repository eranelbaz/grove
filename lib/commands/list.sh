#!/usr/bin/env bash
# grove list — per-repo or global session listing.

cmd_list() {
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    _list_repo
  else
    _list_global
  fi
}

_list_repo() {
  local repo path branch session live
  repo="$(basename "$(main_root)")"
  while read -r path; do
    branch="$(git -C "$path" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
    session="$(session_name "$repo" "$branch")"
    if tmux has-session -t "$session" 2>/dev/null; then
      live="${C_GREEN}● live${C_RESET}"
    else
      live='  ----'
    fi
    printf '%b  %-24s  %s\n' "$live" "$branch" "$path"
  done < <(git worktree list --porcelain | awk '/^worktree /{print $2}')
}

_list_global() {
  require_tmux
  local rows
  rows="$(tmux list-sessions -F '#{session_name}|#{@grove-repo}|#{@grove-branch}|#{@grove-worktree}' 2>/dev/null \
    | awk -F'|' '$2 != ""' | sort -t'|' -k2,2 -k3,3 || true)"
  if [ -z "$rows" ]; then
    printf 'no grove sessions running (run `grove create <branch>` from a repo)\n' >&2
    return
  fi
  printf '%s\n' "$rows" | awk -F'|' -v b="$C_BOLD" -v g="$C_GREEN" -v r="$C_RESET" '
    BEGIN { last="" }
    {
      if ($2 != last) {
        if (last != "") print ""
        printf "%s%s%s\n", b, $2, r
        last = $2
      }
      printf "  %s● live%s  %-24s  %s\n", g, r, $3, $4
    }'
}
