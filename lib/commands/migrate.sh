#!/usr/bin/env bash
# grove migrate — move (or adopt) a worktree into the canonical .worktrees/<branch> path.

cmd_migrate() {
  [ $# -ge 1 ] || die "usage: grove migrate <branch> [-f|--adopt|--no-session]  |  grove migrate --all [-f]"
  require_repo
  local root; root="$(main_root)"

  if [ "$1" = "--all" ]; then
    shift
    local force_flag=""
    while [ $# -gt 0 ]; do
      case "$1" in
        -f|--force) force_flag="-f" ;;
        *)          die "unknown option for --all: $1" ;;
      esac
      shift
    done
    local any_fail=0 path branch
    while IFS= read -r path; do
      [ -z "$path" ] && continue
      case "$path" in
        "$root"/.worktrees/*) continue ;;
        "$root") continue ;;
      esac
      branch="$(git -C "$path" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')"
      [ -z "$branch" ] || [ "$branch" = "HEAD" ] && continue
      if ! ( cmd_migrate "$branch" $force_flag --no-session ); then
        any_fail=1
      fi
    done < <(git worktree list --porcelain | awk '/^worktree /{print substr($0, 10)}')
    return "$any_fail"
  fi

  local branch="$1" force=0 adopt=0 no_session=0
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      -f|--force)   force=1 ;;
      --adopt)      adopt=1 ;;
      --no-session) no_session=1 ;;
      *)            die "unknown option: $1" ;;
    esac
    shift
  done

  local src dst
  dst="$root/.worktrees/$branch"

  src="$(_worktree_path_for "$branch")"
  [ -n "$src" ] || die "no worktree for branch '$branch' — use: grove attach $branch"

  if [ "$adopt" -eq 1 ]; then
    info "adopted $branch at $src"
    [ "$no_session" -eq 1 ] || _restart_session_at "$branch" "$src"
    return 0
  fi

  [ "$src" = "$dst" ] && { info "already at $dst — nothing to migrate"; return 0; }
  [ -e "$dst" ] && die "destination already exists: $dst"

  if [ "$force" -eq 0 ]; then
    local locked
    locked="$(git worktree list --porcelain \
              | awk -v p="worktree $src" '$0==p {found=1; next} found && /^worktree /{exit} found && /^locked/{print "y"; exit}')"
    [ -z "$locked" ] || die "worktree at $src is locked — unlock it, or re-run with -f"

    local dirty
    dirty="$(git -C "$src" status --porcelain 2>/dev/null)"
    [ -z "$dirty" ] || die "worktree at $src has uncommitted changes — commit/stash first, or re-run with -f"
  fi

  ensure_excluded "$root"
  mkdir -p "$root/.worktrees"
  if [ "$force" -eq 1 ]; then
    git worktree move --force "$src" "$dst"
  else
    git worktree move "$src" "$dst"
  fi
  info "migrated $branch from $src to $dst"
  [ "$no_session" -eq 1 ] || _restart_session_at "$branch" "$dst"
}
