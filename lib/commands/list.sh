#!/usr/bin/env bash
# grove list — per-repo or global session listing.

_grove_pr_cache=""
_grove_pr_cache_key=""

_load_pr_cache() {
  local key="$1" path="$2"
  [ "$_grove_pr_cache_key" = "$key" ] && return 0
  _grove_pr_cache_key="$key"
  _grove_pr_cache=""
  command -v gh >/dev/null 2>&1 || return 0
  _grove_pr_cache="$(cd "$path" 2>/dev/null && \
    gh pr list --state all --limit 200 \
      --json state,number,headRefName,isDraft \
      --template '{{range .}}{{.headRefName}}|{{.state}}|{{.number}}|{{.isDraft}}{{"\n"}}{{end}}' \
      2>/dev/null)" || _grove_pr_cache=""
}

_pr_lookup() {
  local branch="$1"
  [ -n "$_grove_pr_cache" ] || return 0
  printf '%s' "$_grove_pr_cache" | awk -F'|' -v b="$branch" '$1 == b { print; exit }'
}

_pr_format() {
  local line="$1" state number is_draft color label plain pad
  if [ -z "$line" ]; then
    printf '%-13s' ""
    return
  fi
  IFS='|' read -r _ state number is_draft <<< "$line"
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
  printf '%s%s%s%*s' "$color" "$plain" "$C_RESET" "$pad" ""
}

cmd_list() {
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    _list_repo
  else
    _list_global
  fi
}

_list_repo() {
  local repo path branch session live pr_line show_pr=0 max_branch=4
  local -a lives=() branches=() pr_lines=() paths=()
  repo="$(basename "$(main_root)")"
  _load_pr_cache "$repo" "$(main_root)"
  while read -r path; do
    branch="$(git -C "$path" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
    session="$(session_name "$repo" "$branch")"
    if tmux has-session -t "$session" 2>/dev/null; then
      live="${C_GREEN}● live${C_RESET}"
    else
      live='  ----'
    fi
    pr_line="$(_pr_lookup "$branch")"
    [ -n "$pr_line" ] && show_pr=1
    [ "${#branch}" -gt "$max_branch" ] && max_branch="${#branch}"
    lives+=("$live"); branches+=("$branch"); pr_lines+=("$pr_line"); paths+=("$path")
  done < <(git worktree list --porcelain | awk '/^worktree /{print $2}')
  local i
  for i in "${!paths[@]}"; do
    if [ "$show_pr" = 1 ]; then
      printf '%b  %-*s  %s  %s\n' "${lives[$i]}" "$max_branch" "${branches[$i]}" "$(_pr_format "${pr_lines[$i]}")" "${paths[$i]}"
    else
      printf '%b  %-*s  %s\n' "${lives[$i]}" "$max_branch" "${branches[$i]}" "${paths[$i]}"
    fi
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
  local -a g_repos=() g_branches=() g_paths=() g_prs=()
  local -A g_repo_has_pr=() g_repo_max_branch=()
  local _session repo branch path pr_line cur_max
  while IFS='|' read -r _session repo branch path; do
    _load_pr_cache "$repo" "$path"
    pr_line="$(_pr_lookup "$branch")"
    [ -n "$pr_line" ] && g_repo_has_pr[$repo]=1
    cur_max="${g_repo_max_branch[$repo]:-4}"
    [ "${#branch}" -gt "$cur_max" ] && g_repo_max_branch[$repo]="${#branch}" || g_repo_max_branch[$repo]="$cur_max"
    g_repos+=("$repo"); g_branches+=("$branch"); g_paths+=("$path"); g_prs+=("$pr_line")
  done <<< "$rows"
  local last="" i width
  for i in "${!g_repos[@]}"; do
    repo="${g_repos[$i]}"
    width="${g_repo_max_branch[$repo]}"
    if [ "$repo" != "$last" ]; then
      [ -n "$last" ] && printf '\n'
      printf '%s%s%s\n' "$C_BOLD" "$repo" "$C_RESET"
      last="$repo"
    fi
    if [ "${g_repo_has_pr[$repo]:-0}" = 1 ]; then
      printf '  %s● live%s  %-*s  %s  %s\n' \
        "$C_GREEN" "$C_RESET" "$width" "${g_branches[$i]}" "$(_pr_format "${g_prs[$i]}")" "${g_paths[$i]}"
    else
      printf '  %s● live%s  %-*s  %s\n' \
        "$C_GREEN" "$C_RESET" "$width" "${g_branches[$i]}" "${g_paths[$i]}"
    fi
  done
}
