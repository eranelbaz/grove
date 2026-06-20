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

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf '\nfailed:\n'
  for t in "${FAILED_TESTS[@]}"; do printf '  - %s\n' "$t"; done
  exit 1
fi
