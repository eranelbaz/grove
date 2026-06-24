#!/usr/bin/env bash
# grove list — per-repo or global session listing.

_grove_pr_cache=""
_grove_pr_cache_key=""
_grove_ps_cache=""
_grove_children=()
_grove_children_built=0

_load_pr_cache() {
  local key="$1" path="$2"
  [ "$_grove_pr_cache_key" = "$key" ] && return 0
  _grove_pr_cache_key="$key"
  _grove_pr_cache=""
  command -v gh >/dev/null 2>&1 || return 0
  _grove_pr_cache="$(cd "$path" 2>/dev/null && \
    gh pr list --state all --limit 200 \
      --json state,number,headRefName,isDraft,url \
      --template '{{range .}}{{.headRefName}}|{{.state}}|{{.number}}|{{.isDraft}}|{{.url}}{{"\n"}}{{end}}' \
      2>/dev/null)" || _grove_pr_cache=""
}

_pr_lookup() {
  local branch="$1"
  [ -n "$_grove_pr_cache" ] || return 0
  printf '%s' "$_grove_pr_cache" | awk -F'|' -v b="$branch" '$1 == b { print; exit }'
}

_build_children_map() {
  [ "$_grove_children_built" = 1 ] && return 0
  _grove_children_built=1
  _grove_ps_cache="$(ps -A -o pid=,ppid= 2>/dev/null || true)"
  [ -z "$_grove_ps_cache" ] && return 0
  local pid ppid
  while read -r pid ppid; do
    [ -z "$pid" ] && continue
    _grove_children[$ppid]="${_grove_children[$ppid]:-} $pid"
  done <<< "$_grove_ps_cache"
}

_descendant_pids() {
  _build_children_map
  local -a queue=("$@")
  local -a seen=()
  local pid child out=""
  while [ "${#queue[@]}" -gt 0 ]; do
    pid="${queue[0]}"
    queue=("${queue[@]:1}")
    [ -n "${seen[$pid]:-}" ] && continue
    seen[$pid]=1
    out+=" $pid"
    for child in ${_grove_children[$pid]:-}; do
      queue+=("$child")
    done
  done
  printf '%s' "${out# }"
}

_session_listen_ports() {
  local session="$1"
  command -v lsof >/dev/null 2>&1 || return 0
  local pane_pids
  pane_pids="$(tmux list-panes -s -t "$session" -F '#{pane_pid}' 2>/dev/null | tr '\n' ' ')"
  [ -z "${pane_pids// /}" ] && return 0
  local all_pids pids_csv
  # shellcheck disable=SC2086
  all_pids="$(_descendant_pids $pane_pids)"
  [ -z "$all_pids" ] && return 0
  pids_csv="${all_pids// /,}"
  lsof -nP -iTCP -sTCP:LISTEN -a -p "$pids_csv" -F n 2>/dev/null \
    | awk -F: '/^n/ { print $NF }' \
    | sort -nu | paste -sd, -
}

_ports_format() {
  local ports="$1" width="$2"
  if [ -n "$ports" ]; then
    printf '%-*s' "$width" ":$ports"
  else
    printf '%-*s' "$width" ""
  fi
}

_pr_format() {
  local line="$1" state number is_draft url color label plain pad
  if [ -z "$line" ]; then
    printf '%-13s' ""
    return
  fi
  IFS='|' read -r _ state number is_draft url <<< "$line"
  if [ "$state" = "OPEN" ] && [ "$is_draft" = "true" ]; then
    color="$C_DIM"; label="draft"
  else
    case "$state" in
      OPEN)   color="$C_GREEN";  label="open" ;;
      MERGED) color="$C_BLUE";   label="merged" ;;
      CLOSED) color="$C_RED";    label="closed" ;;
      *)      color="$C_DIM";    label="$state" ;;
    esac
  fi
  plain="#${number} ${label}"
  pad=$(( 13 - ${#plain} ))
  [ "$pad" -lt 1 ] && pad=1
  printf '%s\033]8;;%s\033\\#%s\033]8;;\033\\ %s%s%*s' \
    "$color" "$url" "$number" "$label" "$C_RESET" "$pad" ""
}

cmd_list() {
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    _list_repo
  else
    _list_global
  fi
}

_list_repo() {
  local repo path branch session live pr_line ports show_pr=0 max_branch=4 max_ports=0
  local -a lives=() branches=() pr_lines=() paths=() ports_list=()
  repo="$(basename "$(main_root)")"
  _load_pr_cache "$repo" "$(main_root)"
  while read -r path; do
    branch="$(git -C "$path" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
    session="$(session_name "$repo" "$branch")"
    ports=""
    if tmux has-session -t "$session" 2>/dev/null; then
      live="${C_GREEN}● live${C_RESET}"
      ports="$(_session_listen_ports "$session" || true)"
    else
      live='  ----'
    fi
    pr_line="$(_pr_lookup "$branch")"
    [ -n "$pr_line" ] && show_pr=1
    [ "${#branch}" -gt "$max_branch" ] && max_branch="${#branch}"
    [ -n "$ports" ] && [ "$(( ${#ports} + 1 ))" -gt "$max_ports" ] && max_ports="$(( ${#ports} + 1 ))"
    lives+=("$live"); branches+=("$branch"); pr_lines+=("$pr_line")
    paths+=("$path"); ports_list+=("$ports")
  done < <(git worktree list --porcelain | awk '/^worktree /{print $2}')
  local i pr_part ports_part
  for i in "${!paths[@]}"; do
    if [ "$show_pr" = 1 ]; then
      pr_part="$(_pr_format "${pr_lines[$i]}")  "
    else
      pr_part=""
    fi
    if [ "$max_ports" -gt 0 ]; then
      ports_part="$(_ports_format "${ports_list[$i]}" "$max_ports")  "
    else
      ports_part=""
    fi
    printf '%b  %-*s  %s%s%s\n' \
      "${lives[$i]}" "$max_branch" "${branches[$i]}" "$pr_part" "$ports_part" "${paths[$i]}"
  done
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
  local -a g_repos=() g_branches=() g_paths=() g_prs=() g_ports=()
  local _session repo branch path pr_line ports
  while IFS='|' read -r _session repo branch path; do
    _load_pr_cache "$repo" "$path"
    pr_line="$(_pr_lookup "$branch")"
    ports="$(_session_listen_ports "$_session" || true)"
    g_repos+=("$repo"); g_branches+=("$branch"); g_paths+=("$path")
    g_prs+=("$pr_line"); g_ports+=("$ports")
  done <<< "$rows"
  local n="${#g_repos[@]}" i j k group_repo has_pr max_branch max_ports plen pr_part ports_part
  i=0
  while [ "$i" -lt "$n" ]; do
    group_repo="${g_repos[$i]}"
    has_pr=0; max_branch=4; max_ports=0
    j="$i"
    while [ "$j" -lt "$n" ] && [ "${g_repos[$j]}" = "$group_repo" ]; do
      [ -n "${g_prs[$j]}" ] && has_pr=1
      [ "${#g_branches[$j]}" -gt "$max_branch" ] && max_branch="${#g_branches[$j]}"
      if [ -n "${g_ports[$j]}" ]; then
        plen=$(( ${#g_ports[$j]} + 1 ))
        [ "$plen" -gt "$max_ports" ] && max_ports="$plen"
      fi
      j=$((j+1))
    done
    [ "$i" -gt 0 ] && printf '\n'
    printf '%s%s%s\n' "$C_BOLD" "$group_repo" "$C_RESET"
    k="$i"
    while [ "$k" -lt "$j" ]; do
      if [ "$has_pr" = 1 ]; then
        pr_part="$(_pr_format "${g_prs[$k]}")  "
      else
        pr_part=""
      fi
      if [ "$max_ports" -gt 0 ]; then
        ports_part="$(_ports_format "${g_ports[$k]}" "$max_ports")  "
      else
        ports_part=""
      fi
      printf '  %s● live%s  %-*s  %s%s%s\n' \
        "$C_GREEN" "$C_RESET" "$max_branch" "${g_branches[$k]}" "$pr_part" "$ports_part" "${g_paths[$k]}"
      k=$((k+1))
    done
    i="$j"
  done
}
