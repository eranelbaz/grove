#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GROVE="$ROOT/grove"
TMP="$(mktemp -d -t grove-migrate-tests.XXXXXX)"
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
. "$GROVE"

PASS=0
FAIL=0
FAILED_TESTS=()

assert_eq() {
  local got="$1" want="$2" name="$3"
  if [ "$got" = "$want" ]; then
    printf '  \033[32m✓\033[0m %s\n' "$name"; PASS=$((PASS+1))
  else
    printf '  \033[31m✗\033[0m %s\n' "$name"
    printf '    want: %q\n' "$want"
    printf '    got:  %q\n' "$got"
    FAIL=$((FAIL+1)); FAILED_TESTS+=("$name")
  fi
}

assert_contains() {
  local got="$1" want="$2" name="$3"
  if printf '%s' "$got" | grep -qF -- "$want"; then
    printf '  \033[32m✓\033[0m %s\n' "$name"; PASS=$((PASS+1))
  else
    printf '  \033[31m✗\033[0m %s\n' "$name"
    printf '    expected to contain: %q\n' "$want"
    printf '    got: %q\n' "$got"
    FAIL=$((FAIL+1)); FAILED_TESTS+=("$name")
  fi
}

assert_empty() {
  local got="$1" name="$2"
  if [ -z "$got" ]; then
    printf '  \033[32m✓\033[0m %s\n' "$name"; PASS=$((PASS+1))
  else
    printf '  \033[31m✗\033[0m %s\n' "$name"
    printf '    expected empty, got: %q\n' "$got"
    FAIL=$((FAIL+1)); FAILED_TESTS+=("$name")
  fi
}

new_repo() {
  local name="$1" dir="$TMP/$1"
  mkdir -p "$dir"
  (
    cd "$dir"
    git init -q -b main
    git config user.email "t@t"
    git config user.name "t"
    git config commit.gpgsign false
    echo r > README.md
    git add README.md
    git commit -q -m "initial"
  )
  printf '%s' "$dir"
}

# === _worktree_path_for ===
printf '\n\033[1m_worktree_path_for\033[0m\n'

wt_repo="$(new_repo wt-lookup)"
(
  cd "$wt_repo"
  git branch elsewhere
  git worktree add -q "$TMP/external-elsewhere" elsewhere
) >/dev/null

# branch with a worktree at a non-canonical path
out_present="$(cd "$wt_repo" && _worktree_path_for elsewhere)"
assert_eq "$out_present" "$TMP/external-elsewhere" 'returns path of existing worktree'

# branch that exists but has no worktree
(
  cd "$wt_repo"
  git branch dangling
)
out_dangling="$(cd "$wt_repo" && _worktree_path_for dangling)"
assert_empty "$out_dangling" 'branch with no worktree returns empty'

# branch that doesn't exist at all
out_missing="$(cd "$wt_repo" && _worktree_path_for never-existed)"
assert_empty "$out_missing" 'unknown branch returns empty'

# === cmd_migrate: relocate to canonical .worktrees/<branch> ===
printf '\n\033[1mcmd_migrate happy path\033[0m\n'

mv_repo="$(new_repo migrate-happy)"
(
  cd "$mv_repo"
  git branch feature-a
  git worktree add -q "$TMP/feature-a-external" feature-a
) >/dev/null

(
  cd "$mv_repo"
  cmd_migrate feature-a --no-session
) > "$TMP/migrate-happy.out" 2>&1

assert_eq "$(test -d "$mv_repo/.worktrees/feature-a" && echo yes || echo no)" 'yes' 'worktree exists at canonical path'
assert_eq "$(test -d "$TMP/feature-a-external" && echo yes || echo no)" 'no' 'old path is gone'
assert_contains "$(cat "$TMP/migrate-happy.out")" 'migrated' 'announces the move'

new_path="$(cd "$mv_repo" && _worktree_path_for feature-a)"
assert_eq "$new_path" "$mv_repo/.worktrees/feature-a" 'git now reports the new path'

# .gitignore-side exclusion is in place
assert_contains "$(cat "$mv_repo/.git/info/exclude")" '.worktrees/' '.worktrees/ is excluded'

# === cmd_migrate: dirty tree refusal & --force override ===
printf '\n\033[1mcmd_migrate safety\033[0m\n'

dirty_repo="$(new_repo migrate-dirty)"
(
  cd "$dirty_repo"
  git branch feature-dirty
  git worktree add -q "$TMP/feature-dirty-external" feature-dirty
  echo unstaged > "$TMP/feature-dirty-external/scratch.txt"
) >/dev/null

set +e
out_refused="$(cd "$dirty_repo" && cmd_migrate feature-dirty --no-session 2>&1)"
rc_refused=$?
set -e
assert_eq "$rc_refused" '1' 'dirty source exits non-zero'
assert_contains "$out_refused" 'uncommitted' 'mentions uncommitted changes'
assert_eq "$(test -d "$TMP/feature-dirty-external" && echo yes || echo no)" 'yes' 'source still present after refusal'

(
  cd "$dirty_repo"
  cmd_migrate feature-dirty -f --no-session
) >/dev/null 2>&1
assert_eq "$(test -d "$dirty_repo/.worktrees/feature-dirty" && echo yes || echo no)" 'yes' '--force migrates dirty tree'
assert_eq "$(cat "$dirty_repo/.worktrees/feature-dirty/scratch.txt")" 'unstaged' 'dirty file preserved through move'

# === cmd_migrate: locked worktree refusal ===
lock_repo="$(new_repo migrate-locked)"
(
  cd "$lock_repo"
  git branch feature-locked
  git worktree add -q "$TMP/feature-locked-external" feature-locked
  git worktree lock --reason "ci-pinned" "$TMP/feature-locked-external"
) >/dev/null

set +e
out_locked="$(cd "$lock_repo" && cmd_migrate feature-locked --no-session 2>&1)"
rc_locked=$?
set -e
assert_eq "$rc_locked" '1' 'locked source exits non-zero'
assert_contains "$out_locked" 'locked' 'mentions the lock'

# Unlock so trap-cleanup of $TMP can remove it
git -C "$lock_repo" worktree unlock "$TMP/feature-locked-external" >/dev/null 2>&1 || true

# === cmd_migrate --adopt: register without moving ===
printf '\n\033[1mcmd_migrate --adopt\033[0m\n'

adopt_repo="$(new_repo migrate-adopt)"
(
  cd "$adopt_repo"
  git branch feature-adopt
  git worktree add -q "$TMP/feature-adopt-external" feature-adopt
) >/dev/null

(
  cd "$adopt_repo"
  cmd_migrate feature-adopt --adopt --no-session
) > "$TMP/adopt.out" 2>&1

assert_eq "$(test -d "$TMP/feature-adopt-external" && echo yes || echo no)" 'yes' 'adopt leaves source path in place'
assert_eq "$(test -d "$adopt_repo/.worktrees/feature-adopt" && echo yes || echo no)" 'no' 'adopt does not create canonical path'
assert_contains "$(cat "$TMP/adopt.out")" 'adopted' 'adopt announces itself'

# === cmd_migrate --all: sweep every out-of-place worktree ===
printf '\n\033[1mcmd_migrate --all\033[0m\n'

all_repo="$(new_repo migrate-all)"
(
  cd "$all_repo"
  git branch one; git branch two; git branch three
  git worktree add -q "$TMP/external-one"   one
  git worktree add -q "$TMP/external-two"   two
  git worktree add -q "$all_repo/.worktrees/three" three
) >/dev/null

(
  cd "$all_repo"
  cmd_migrate --all
) > "$TMP/all.out" 2>&1

assert_eq "$(test -d "$all_repo/.worktrees/one" && echo yes || echo no)" 'yes' '--all migrated branch one'
assert_eq "$(test -d "$all_repo/.worktrees/two" && echo yes || echo no)" 'yes' '--all migrated branch two'
assert_eq "$(test -d "$TMP/external-one" && echo yes || echo no)" 'no' 'external-one removed'
assert_eq "$(test -d "$TMP/external-two" && echo yes || echo no)" 'no' 'external-two removed'
assert_contains "$(cat "$TMP/all.out")" 'one' 'output names branch one'
assert_contains "$(cat "$TMP/all.out")" 'two' 'output names branch two'

# branch three was already canonical — should be skipped silently
n_already="$(grep -c 'already at' "$TMP/all.out" || true)"
assert_eq "$n_already" '0' 'canonical branch not listed as already-at'

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf '\nfailed:\n'
  for t in "${FAILED_TESTS[@]}"; do printf '  - %s\n' "$t"; done
  exit 1
fi
