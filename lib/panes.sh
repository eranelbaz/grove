#!/usr/bin/env bash
# grove panes — diff/status/commits pane rendering and refresh loop.

# Reads three independent git streams (name-status, numstat, untracked) and
# merges them into one record per file: "status\tadds\tdels\tpath", sorted
# by path. Renamed/copied files are folded into their new name only.
_collate_diff_streams() {
  local base="$1"
  {
    git --no-pager diff --no-renames --name-status "$base" 2>/dev/null \
      | awk -F'\t' 'NF==2 { printf "S\t%s\t%s\n", $1, $2 }'
    git --no-pager diff --no-renames --numstat "$base" 2>/dev/null \
      | awk -F'\t' 'NF==3 { printf "N\t%s\t%s\t%s\n", $1, $2, $3 }'
    git ls-files --others --exclude-standard 2>/dev/null \
      | awk 'NF>0 { printf "U\t%s\n", $0 }'
  } | awk -F'\t' '
      $1 == "S" { stat[$3] = substr($2, 1, 1) }
      $1 == "N" { add[$4] = $2; del[$4] = $3; paths[$4] = 1 }
      $1 == "U" { stat[$2] = "?"; add[$2] = "-"; del[$2] = "-"; paths[$2] = 1 }
      END {
        for (p in paths) {
          s = (p in stat) ? stat[p] : "M"
          a = (p in add)  ? add[p]  : "0"
          d = (p in del)  ? del[p]  : "0"
          printf "%s\t%s\t%s\t%s\n", s, a, d, p
        }
      }' | sort -t$'\t' -k4
}

_render_diff_tree() {
  local anchor="$1" label="$2" merged
  merged="$(_collate_diff_streams "$anchor")"
  if [ -z "$merged" ]; then
    printf '%s(clean — no changes vs %s)%s\n' "$C_DIM" "$label" "$C_RESET"
    return
  fi
  printf '%s\n' "$merged" | awk -F'\t' '
    BEGIN { prev_n = 0 }
    {
      status = $1; add = $2; del = $3; path = $4
      n = split(path, parts, "/")
      common = 0
      while (common < n - 1 && common < prev_n - 1 && parts[common + 1] == prev[common + 1]) common++
      for (i = common + 1; i <= n - 1; i++) {
        indent = ""
        for (j = 1; j < i; j++) indent = indent "  "
        printf "%s\033[34m%s/\033[0m\n", indent, parts[i]
      }
      indent = ""
      for (j = 1; j < n; j++) indent = indent "  "
      if      (status == "?") badge_col = "36"
      else if (status == "A") badge_col = "32"
      else if (status == "D") badge_col = "31"
      else if (status == "M") badge_col = "33"
      else                    badge_col = "37"
      if (add == "-" && del == "-") {
        stat_disp = (status == "?") ? "" : "  \033[2m[bin]\033[0m"
      } else if (add == "0" && del == "0") {
        stat_disp = "  \033[2m[bin]\033[0m"
      } else {
        add_disp = (add == "0") ? "       " : sprintf("  \033[32m+%s\033[0m", add)
        del_disp = (del == "0") ? ""        : sprintf(" \033[31m-%s\033[0m", del)
        stat_disp = add_disp del_disp
      }
      printf "%s\033[%sm%s\033[0m %s%s\n", indent, badge_col, status, parts[n], stat_disp
      for (i = 1; i <= n; i++) prev[i] = parts[i]
      prev_n = n
    }'
}

_render_branch_status() {
  local base="$1" ref ahead behind branch
  ref="$(_resolve_base "$base")"
  ahead="$(git rev-list --count "$ref"..HEAD 2>/dev/null || echo 0)"
  behind="$(git rev-list --count HEAD.."$ref" 2>/dev/null || echo 0)"
  branch="$(git symbolic-ref --short HEAD 2>/dev/null || git rev-parse --short HEAD 2>/dev/null)"
  printf '%s── branch status ── %s%s%s%s ──%s\n' \
    "$C_DIM" "$C_RESET" "$C_YELLOW" "$branch" "$C_DIM" "$C_RESET"
  printf '  %s↑ %s ahead%s  %s↓ %s behind%s\n' \
    "$C_GREEN" "$ahead" "$C_RESET" "$C_RED" "$behind" "$C_RESET"
}

_render_recent_commits() {
  local base="$1" ref ahead
  ref="$(_resolve_base "$base")"
  ahead="$(git rev-list --count "$ref"..HEAD 2>/dev/null || echo 0)"
  [ "$ahead" -gt 0 ] || return 0
  printf '%s── recent commits ──%s\n' "$C_DIM" "$C_RESET"
  git --no-pager log --oneline --no-decorate -n "$COMMITS_PANE_MAX" "$ref"..HEAD 2>/dev/null \
    | awk -v c="$C_YELLOW" -v r="$C_RESET" '
        { hash = substr($1, 1, 7); $1 = ""; msg = substr($0, 2);
          printf "  %s%s%s %s\n", c, hash, r, msg }'
  if [ "$ahead" -gt "$COMMITS_PANE_MAX" ]; then
    printf '  %s… and %d more%s\n' "$C_DIM" "$((ahead - COMMITS_PANE_MAX))" "$C_RESET"
  fi
}

_is_valid_base() {
  [ -n "$1" ] && git rev-parse --verify --quiet "$1" >/dev/null 2>&1
}

# Prefer origin/<base> when the remote-tracking branch exists, so a stale
# local main doesn't hide commits that have landed upstream. Refs that
# already contain a slash (e.g. origin/main, upstream/dev) are used as-is.
_resolve_base() {
  local base="$1"
  [ -n "$base" ] || return 0
  case "$base" in
    */*) printf '%s' "$base"; return 0 ;;
  esac
  if git show-ref --verify --quiet "refs/remotes/origin/$base"; then
    printf 'origin/%s' "$base"
  else
    printf '%s' "$base"
  fi
}

_diff_pane_render() {
  local base="$1" ref
  if [ -z "$base" ]; then
    printf 'no base set\n\nrun: grove base <branch>\n'
    return
  fi
  ref="$(_resolve_base "$base")"
  if ! _is_valid_base "$ref"; then
    printf '%sinvalid base: %s%s\n\nrun: grove base <branch>\n' "$C_RED" "$base" "$C_RESET"
    return
  fi
  local anchor ahead behind counts=""
  anchor="$(git merge-base "$ref" HEAD 2>/dev/null)"
  [ -n "$anchor" ] || anchor="$ref"
  ahead="$(git rev-list --count "$ref"..HEAD 2>/dev/null || echo 0)"
  behind="$(git rev-list --count HEAD.."$ref" 2>/dev/null || echo 0)"
  [ "$ahead"  -gt 0 ] && counts="${counts} ${C_GREEN}↑ ${ahead} ahead${C_DIM}"
  [ "$behind" -gt 0 ] && counts="${counts} ${C_RED}↓ ${behind} behind${C_DIM}"
  [ -n "$counts" ] && counts="${counts# } ── "
  printf '%s── diff vs %s ── %b%s ──%s\n\n' \
    "$C_DIM" "$base" "$counts" "$(date +%H:%M:%S)" "$C_RESET"
  _render_diff_tree "$anchor" "$base"
  printf '\n'
  git --no-pager diff --no-renames --shortstat "$anchor" 2>/dev/null
}

_status_pane_render()  { _is_valid_base "$1" && _render_branch_status  "$1"; }
_commits_pane_render() { _is_valid_base "$1" && _render_recent_commits "$1"; }

_pane_loop() {
  local interval="$1" renderer="$2"
  set +e
  set +o pipefail
  trap 'exit 0' INT TERM
  local prev='' output base
  while :; do
    base="$(tmux show-options -v @grove-base 2>/dev/null)"
    output="$("$renderer" "$base")"
    if [ "$output" != "$prev" ]; then
      {
        printf '\033[H'
        printf '%s\n' "$output" | awk '{ printf "%s\033[K\n", $0 }'
        printf '\033[J'
      }
      prev="$output"
    fi
    sleep "$interval"
  done
}

_cmd_pane() {
  case "${1:-}" in
    diff)    _pane_loop "$DIFF_PANE_INTERVAL"    _diff_pane_render ;;
    status)  _pane_loop "$STATUS_PANE_INTERVAL"  _status_pane_render ;;
    commits) _pane_loop "$COMMITS_PANE_INTERVAL" _commits_pane_render ;;
    *)       die "unknown pane: ${1:-<empty>}" ;;
  esac
}
