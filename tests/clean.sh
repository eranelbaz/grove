#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GROVE="$ROOT/grove"
TMP="$(mktemp -d -t grove-clean-tests.XXXXXX)"
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

make_worktrees() {
  local repo="$1"; shift
  local b
  for b in "$@"; do
    (cd "$repo" && git branch "$b" && git worktree add -q "$repo/.worktrees/$b" "$b") >/dev/null
  done
}

# tmux is called by _clean_one to kill sessions — stub it so tests don't touch a server.
FAKE="$TMP/fakebin"
mkdir -p "$FAKE"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE/tmux"
chmod +x "$FAKE/tmux"

# === -i resolves indices to the branches shown at those rows, before removal ===
printf '\n\033[1mclean -i (resolve-before-remove)\033[0m\n'

repo="$(new_repo clean-idx)"
make_worktrees "$repo" b1 b2 b3 b4

paths=()
while read -r p; do paths+=("$p"); done < <(cd "$repo" && _repo_worktree_paths)
assert_eq "${#paths[@]}" '5' 'five worktrees (main + b1..b4)'

# rows: 0=main 1=b1 2=b2 3=b3 4=b4 — clean 1 and 3 in one shot.
out="$(cd "$repo" && PATH="$FAKE:$PATH" cmd_clean -i 1 3 -f 2>&1)"
assert_contains "$out" 'removed worktree' 'clean -i removes worktrees'

remaining="$(cd "$repo" && _repo_worktree_paths | sed "s#$repo/.worktrees/##" | grep -v "^$repo\$" | paste -sd, -)"
assert_eq "$remaining" 'b2,b4' 'indices resolved against one snapshot — b1 and b3 gone, b2/b4 kept'

assert_eq "$(test -d "$repo/.worktrees/b1" && echo y || echo n)" 'n' 'b1 (row 1) worktree removed'
assert_eq "$(test -d "$repo/.worktrees/b3" && echo y || echo n)" 'n' 'b3 (row 3) worktree removed'
assert_eq "$(test -d "$repo/.worktrees/b2" && echo y || echo n)" 'y' 'b2 (row 2) worktree kept'

# === mixing a name and an index ===
printf '\n\033[1mclean mixes names and indices\033[0m\n'

repo2="$(new_repo clean-mix)"
make_worktrees "$repo2" m1 m2 m3

# rows: 0=main 1=m1 2=m2 3=m3 — clean name m1 and index 3 (m3), keep m2.
out2="$(cd "$repo2" && PATH="$FAKE:$PATH" cmd_clean m1 -i 3 -f 2>&1)"
remaining2="$(cd "$repo2" && _repo_worktree_paths | sed "s#$repo2/.worktrees/##" | grep -v "^$repo2\$" | paste -sd, -)"
assert_eq "$remaining2" 'm2' 'name m1 and index 3 (m3) removed, m2 kept'

# === out-of-range index is skipped, valid ones still processed ===
printf '\n\033[1mclean -i out-of-range\033[0m\n'

repo3="$(new_repo clean-oor)"
make_worktrees "$repo3" k1 k2

out3="$(cd "$repo3" && PATH="$FAKE:$PATH" cmd_clean -i 1 99 -f 2>&1)"
assert_contains "$out3" 'out of range' 'out-of-range index warns'
remaining3="$(cd "$repo3" && _repo_worktree_paths | sed "s#$repo3/.worktrees/##" | grep -v "^$repo3\$" | paste -sd, -)"
assert_eq "$remaining3" 'k2' 'valid index 1 (k1) removed despite the bad 99'

# === -i with no indices errors ===
printf '\n\033[1mclean -i errors\033[0m\n'

repo4="$(new_repo clean-noidx)"
make_worktrees "$repo4" j1
set +e
out4="$(cd "$repo4" && PATH="$FAKE:$PATH" cmd_clean -i 2>&1)"
rc4=$?
set -e
assert_eq "$rc4" '1' '-i with no index exits non-zero'
assert_contains "$out4" 'requires at least one index' '-i with no index message'
assert_eq "$(test -d "$repo4/.worktrees/j1" && echo y || echo n)" 'y' 'nothing removed on error'

# === no args → usage mentions both forms ===
set +e
out5="$(cd "$repo4" && PATH="$FAKE:$PATH" cmd_clean -f 2>&1)"
set -e
assert_contains "$out5" '-i <index>' 'usage advertises the index form'

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf '\nfailed:\n'
  for t in "${FAILED_TESTS[@]}"; do printf '  - %s\n' "$t"; done
  exit 1
fi
