#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GROVE="$ROOT/grove"
TMP="$(mktemp -d -t grove-attach-tests.XXXXXX)"
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

strip_ansi() { LC_ALL=C sed "s/$(printf '\033')\[[0-9;]*m//g"; }

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

# === repo-local list: index column ===
printf '\n\033[1mlist index column (repo-local)\033[0m\n'

repo="$(new_repo attach-idx)"
(
  cd "$repo"
  git branch feat-a
  git worktree add -q "$repo/.worktrees/feat-a" feat-a
  git branch feat-x
  git worktree add -q "$TMP/ext-x" feat-x
) >/dev/null

# authoritative ordering the resolver and list both consume
paths=()
while read -r p; do paths+=("$p"); done < <(cd "$repo" && _repo_worktree_paths)
assert_eq "${#paths[@]}" '3' '_repo_worktree_paths lists all three worktrees'

list_out="$(cd "$repo" && cmd_list | strip_ansi)"

idx_col="$(printf '%s\n' "$list_out" | awk '{print $1}' | paste -sd, -)"
assert_eq "$idx_col" '0,1,2' 'list shows a 0-based contiguous index column'

first_char="$(printf '%s\n' "$list_out" | head -1 | cut -c1)"
assert_eq "$first_char" '0' 'index column is left-aligned (no leading pad)'

# each printed row's path matches _repo_worktree_paths at the same index
row0_path="$(printf '%s\n' "$list_out" | awk 'NR==1{print $NF}')"
row1_path="$(printf '%s\n' "$list_out" | awk 'NR==2{print $NF}')"
row2_path="$(printf '%s\n' "$list_out" | awk 'NR==3{print $NF}')"
assert_eq "$row0_path" "${paths[0]}" 'row 0 path matches _repo_worktree_paths[0]'
assert_eq "$row1_path" "${paths[1]}" 'row 1 path matches _repo_worktree_paths[1]'
assert_eq "$row2_path" "${paths[2]}" 'row 2 path matches _repo_worktree_paths[2]'

# === attach -i inside a repo resolves to the branch at row N ===
printf '\n\033[1mattach -i (repo-local resolution)\033[0m\n'

ext_idx=""
for i in "${!paths[@]}"; do
  [ "${paths[$i]}" = "$TMP/ext-x" ] && ext_idx="$i"
done
assert_eq "$(test -n "$ext_idx" && echo yes || echo no)" 'yes' 'located the external worktree row'

exp_branch="$(git -C "${paths[$ext_idx]}" rev-parse --abbrev-ref HEAD)"

set +e
out_idx="$(cd "$repo" && cmd_attach -i "$ext_idx" 2>&1)"
rc_idx=$?
set -e
assert_eq "$rc_idx" '1' 'attach -i to elsewhere-checkout exits non-zero'
assert_contains "$out_idx" "already checked out at ${paths[$ext_idx]}" 'attach -i names the row N path'
assert_contains "$out_idx" "grove migrate $exp_branch" 'attach -i resolves row N to its branch'

# long form flag maps identically
set +e
out_long="$(cd "$repo" && cmd_attach --index "$ext_idx" 2>&1)"
set -e
assert_contains "$out_long" "grove migrate $exp_branch" '--index resolves like -i'

# === attach -i error handling ===
printf '\n\033[1mattach -i errors\033[0m\n'

set +e
out_oor="$(cd "$repo" && cmd_attach -i 99 2>&1)"
rc_oor=$?
set -e
assert_eq "$rc_oor" '1' 'out-of-range index exits non-zero'
assert_contains "$out_oor" 'out of range' 'out-of-range index reports range'

set +e
out_nan="$(cd "$repo" && cmd_attach -i abc 2>&1)"
rc_nan=$?
set -e
assert_eq "$rc_nan" '1' 'non-numeric index exits non-zero'
assert_contains "$out_nan" 'non-negative integer' 'non-numeric index message'

set +e
out_missing="$(cd "$repo" && cmd_attach -i 2>&1)"
rc_missing=$?
set -e
assert_eq "$rc_missing" '1' 'missing index value exits non-zero'
assert_contains "$out_missing" 'requires an index' 'missing value message'

# no args → usage mentions both forms
set +e
out_usage="$(cd "$repo" && cmd_attach 2>&1)"
set -e
assert_contains "$out_usage" '-i <index>' 'usage advertises the index form'

# === global mode: continuous index + attach -i (stubbed tmux) ===
printf '\n\033[1mglobal index + attach -i\033[0m\n'

FAKE="$TMP/fakebin"
mkdir -p "$FAKE"
cat > "$FAKE/tmux" <<'EOF'
#!/usr/bin/env bash
cmd="${1:-}"
case "$cmd" in
  list-sessions)
    printf '%s\n' 'sZ|repoA|zeta|/pA2' 'sA|repoA|alpha|/pA1' 'sB|repoB|mid|/pB1' ;;
  *) : ;;
esac
EOF
chmod +x "$FAKE/tmux"

mkdir -p "$TMP/notrepo"

glist="$(cd "$TMP/notrepo" && PATH="$FAKE:$PATH" cmd_list | strip_ansi)"
assert_contains "$glist" 'repoA' 'global list shows repoA group'
assert_contains "$glist" 'repoB' 'global list shows repoB group'

a_idx="$(printf '%s\n' "$glist" | awk '/alpha/{print $1}')"
z_idx="$(printf '%s\n' "$glist" | awk '/zeta/{print $1}')"
m_idx="$(printf '%s\n' "$glist" | awk '/mid/{print $1}')"
assert_eq "$a_idx" '0' 'first global row is index 0'
assert_eq "$z_idx" '1' 'second global row is index 1'
assert_eq "$m_idx" '2' 'index is continuous across repo groups (does not restart)'

set +e
ga0="$(cd "$TMP/notrepo" && PATH="$FAKE:$PATH" TMUX= cmd_attach -i 0 2>&1)"
rc_ga0=$?
set -e
assert_eq "$rc_ga0" '0' 'global attach -i 0 succeeds'
assert_contains "$ga0" 'attaching existing session: sA' 'global attach -i 0 targets the row 0 session'

set +e
ga2="$(cd "$TMP/notrepo" && PATH="$FAKE:$PATH" TMUX= cmd_attach -i 2 2>&1)"
rc_ga2=$?
set -e
assert_eq "$rc_ga2" '0' 'global attach -i 2 succeeds'
assert_contains "$ga2" 'attaching existing session: sB' 'global attach -i 2 targets the row 2 session'

set +e
gaoor="$(cd "$TMP/notrepo" && PATH="$FAKE:$PATH" TMUX= cmd_attach -i 9 2>&1)"
rc_gaoor=$?
set -e
assert_eq "$rc_gaoor" '1' 'global out-of-range index exits non-zero'
assert_contains "$gaoor" 'out of range' 'global out-of-range reports range'

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf '\nfailed:\n'
  for t in "${FAILED_TESTS[@]}"; do printf '  - %s\n' "$t"; done
  exit 1
fi
