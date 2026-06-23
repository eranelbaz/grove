#!/usr/bin/env bash
# grove util — shared helpers, colors, and tunable constants.

C_CYAN=$'\033[36m'
C_RED=$'\033[31m'
C_GREEN=$'\033[32m'
C_YELLOW=$'\033[33m'
C_BLUE=$'\033[34m'
C_DIM=$'\033[2m'
C_BOLD=$'\033[1m'
C_RESET=$'\033[0m'

DIFF_PANE_WIDTH_PCT=20
COMMITS_PANE_LINES=14
STATUS_PANE_LINES=4
PR_PANE_LINES=6
DIFF_PANE_INTERVAL=2
STATUS_PANE_INTERVAL=5
PR_PANE_INTERVAL=60
COMMITS_PANE_INTERVAL=5
COMMITS_PANE_MAX=12

die()  { printf 'grove: %s\n' "$*" >&2; exit 1; }
info() { printf '%s▸%s %s\n' "$C_CYAN" "$C_RESET" "$*" >&2; }

require_repo() {
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || die "not inside a git repository"
}

require_tmux() { command -v tmux >/dev/null 2>&1 || die "tmux is not installed"; }

main_root() { git worktree list --porcelain | awk '/^worktree /{print $2; exit}'; }

sanitize() { printf '%s' "$1" | tr './: ' '----'; }
session_name() { printf '%s-%s' "$(sanitize "$1")" "$(sanitize "$2")"; }
_session_for() { session_name "$(basename "$(main_root)")" "$1"; }

_worktree_path_for() {
  local branch="$1"
  git worktree list --porcelain 2>/dev/null \
    | awk -v b="refs/heads/$branch" '
        /^worktree / { path = substr($0, 10) }
        $0 == "branch " b { print path; exit }
      '
}

_grove_worktree_path() { printf '%s/.worktrees/%s' "$(main_root)" "$1"; }

_default_base() {
  local b=""
  b=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||' || true)
  [ -z "$b" ] && git show-ref --verify --quiet refs/heads/main   && b=main
  [ -z "$b" ] && git show-ref --verify --quiet refs/heads/master && b=master
  printf '%s' "$b"
}

ensure_excluded() {
  local root="$1" exclude="$root/.git/info/exclude"
  if [ -f "$exclude" ] && ! grep -qxF '.worktrees/' "$exclude"; then
    printf '.worktrees/\n' >> "$exclude"
    info "added '.worktrees/' to .git/info/exclude"
  fi
}

_run_hook() {
  local hook_name="$1" branch="$2" wt="$3" from="${4:-}"
  local root repo hook
  root="$(main_root)"; repo="$(basename "$root")"
  hook="$GROVE_HOME/$repo/$hook_name"
  if [ -f "$hook" ]; then
    info "running ${hook_name%.sh}: $hook"
    ( cd "$wt" \
      && GROVE_WORKTREE="$wt" GROVE_BRANCH="$branch" GROVE_FROM="$from" \
         GROVE_REPO_ROOT="$root" GROVE_REPO_NAME="$repo" \
         bash "$hook" )
  fi
}
