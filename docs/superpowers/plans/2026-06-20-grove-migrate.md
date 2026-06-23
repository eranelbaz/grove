# `grove migrate` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `grove migrate` subcommand that relocates an existing worktree for a branch into grove's canonical `.worktrees/<branch>` path under the main repo root, so branches checked out elsewhere (old grove location, hand-rolled `git worktree add`, stale superset/superset-style paths) can be reclaimed without manual git surgery.

**Architecture:** Single bash subcommand `cmd_migrate` added to the existing `grove` script. Pure-git relocation via `git worktree move` (which transparently rewrites gitdir pointers, keeps the index/HEAD/reflog intact). Two flags layered on top: `--adopt` to skip the physical move and just (re)launch the tmux session at the existing path, and `--all` to sweep every out-of-place worktree in the repo. A small `_worktree_path_for` helper parses `git worktree list --porcelain` so it can be reused by `cmd_attach`'s hint path. Tests follow the established pattern from the in-flight `tests/run.sh` on the `diff-pane-sections` branch: source `grove`, call functions in a disposable temp repo, assert on output and filesystem state — no tmux needed for the relocation logic.

**Tech Stack:** Bash 3.2+, `git` 2.5+ (uses `git worktree move` which is 2.17+ — already implicit in grove's use of worktrees). No new dependencies.

## Global Constraints

- POSIX-portable bash 3.2+ (matches grove's `set -euo pipefail` style; no bash-4 features like associative arrays).
- No new external dependencies beyond `git` and `tmux`.
- Match existing code style: 2-space indent, `cmd_*` for subcommand entry points, `_underscore` prefix for private helpers, `info`/`die` for output, lowercase locals declared at the top of each function.
- Never commit any file under `docs/` — the plan itself stays untracked. Code/test/help commits only.
- All git-worktree-touching logic must operate from `main_root` (use the helper) so it works correctly when grove is invoked from inside a sibling worktree.
- Session naming: keep the existing `session_name`/`_session_for`/`sanitize` helpers — `cmd_migrate` must produce the same session name `cmd_attach` would, otherwise `grove ls` will show duplicate ghosts.

---

## File Structure

- `grove` (modified) — add `_worktree_path_for` helper, `cmd_migrate` function, wire it into `main`'s case statement, extend the header docstring (consumed by `usage()`), add the "use: grove migrate <branch>" hint to `cmd_attach`'s error path.
- `tests/migrate.sh` (created) — self-contained test runner that sources `grove`, builds throwaway repos under `mktemp -d`, exercises the helper and `cmd_migrate` in isolation. Mirrors the assert helpers from `tests/run.sh` on the `diff-pane-sections` branch but does not depend on it being merged.
- `README.md` (modified, single small section) — add `grove migrate` to the commands block.

No changes to per-repo hooks, the diff-pane renderer, or `cmd_clean`.

---

## Task 1: `_worktree_path_for` helper

**Files:**
- Modify: `grove` — insert new helper near the other private worktree helpers (after `main_root()` around line 53).
- Test: `tests/migrate.sh` (new file).

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `_worktree_path_for <branch>` — prints the absolute path of the worktree currently checked out at `refs/heads/<branch>`, or empty string if no worktree has that branch checked out. Exit status is always 0 (empty output signals "none").

- [ ] **Step 1: Create the test file skeleton with the failing helper test**

Create `tests/migrate.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GROVE="$ROOT/grove"
TMP="$(mktemp -d -t grove-migrate-tests.XXXXXX)"
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
```

Then make it executable:

```bash
chmod +x tests/migrate.sh
```

- [ ] **Step 2: Run the test and verify it fails**

Run: `tests/migrate.sh`

Expected: fails with `_worktree_path_for: command not found` (function not defined yet — sourcing succeeds, but the call inside `assert_eq` blows up).

- [ ] **Step 3: Implement `_worktree_path_for`**

In `grove`, immediately after the `main_root()` function (line 53 in the current file), add:

```bash
# Print absolute path of the worktree that has <branch> checked out, or empty.
_worktree_path_for() {
  local branch="$1"
  git worktree list --porcelain 2>/dev/null \
    | awk -v b="refs/heads/$branch" '
        /^worktree / { path = substr($0, 10) }
        $0 == "branch " b { print path; exit }
      '
}
```

- [ ] **Step 4: Run the test and verify it passes**

Run: `tests/migrate.sh`

Expected: `3 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add grove tests/migrate.sh
git commit -m "feat(grove): add _worktree_path_for helper

Returns the absolute path of the worktree currently holding a given
branch, or empty if the branch has no worktree. Will back the upcoming
grove migrate subcommand and an improved attach error hint."
```

---

## Task 2: `cmd_migrate <branch>` — happy path relocation

**Files:**
- Modify: `grove` — add `cmd_migrate` after `cmd_attach` (around line 175).
- Modify: `grove` — register `migrate` in the `main` dispatcher's case statement (around line 431).
- Test: `tests/migrate.sh` — extend with a relocation test block.

**Interfaces:**
- Consumes: `_worktree_path_for` (Task 1), `main_root`, `ensure_excluded`, `info`, `die`.
- Produces: `cmd_migrate <branch>` — relocates `<branch>`'s worktree from its current path into `$(main_root)/.worktrees/<branch>` using `git worktree move`. On success prints `▸ migrated <branch> from <src> to <dst>`. Returns 0. Does **not** start a tmux session in this task (Task 6 layers that on). The `main` dispatcher recognizes `migrate` (and `mv` as an alias).

- [ ] **Step 1: Write the failing relocation test**

In `tests/migrate.sh`, append before the final `printf '\n%d passed...` block:

```bash
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
  cmd_migrate feature-a
) > "$TMP/migrate-happy.out" 2>&1

assert_eq "$(test -d "$mv_repo/.worktrees/feature-a" && echo yes || echo no)" 'yes' 'worktree exists at canonical path'
assert_eq "$(test -d "$TMP/feature-a-external" && echo yes || echo no)" 'no' 'old path is gone'
assert_contains "$(cat "$TMP/migrate-happy.out")" 'migrated' 'announces the move'

new_path="$(cd "$mv_repo" && _worktree_path_for feature-a)"
assert_eq "$new_path" "$mv_repo/.worktrees/feature-a" 'git now reports the new path'

# .gitignore-side exclusion is in place
assert_contains "$(cat "$mv_repo/.git/info/exclude")" '.worktrees/' '.worktrees/ is excluded'
```

- [ ] **Step 2: Run and verify it fails**

Run: `tests/migrate.sh`

Expected: `cmd_migrate: command not found` (function and dispatcher entry both missing).

- [ ] **Step 3: Implement `cmd_migrate` (minimal, no flags yet)**

In `grove`, right after `cmd_attach` closes (around line 175), insert:

```bash
cmd_migrate() {
  [ $# -ge 1 ] || die "usage: grove migrate <branch>"
  require_repo
  local branch="$1"
  local root src dst
  root="$(main_root)"; dst="$root/.worktrees/$branch"

  src="$(_worktree_path_for "$branch")"
  [ -n "$src" ] || die "no worktree for branch '$branch' — use: grove attach $branch"
  [ "$src" = "$dst" ] && { info "already at $dst — nothing to migrate"; return 0; }
  [ -e "$dst" ] && die "destination already exists: $dst"

  ensure_excluded "$root"
  mkdir -p "$root/.worktrees"
  git worktree move "$src" "$dst"
  info "migrated $branch from $src to $dst"
}
```

- [ ] **Step 4: Wire `migrate` into the dispatcher**

In `grove`, modify the `case "$cmd" in` block in `main()` (around line 431). Replace:

```bash
    init)           shift; cmd_init "$@" ;;
```

with:

```bash
    init)           shift; cmd_init "$@" ;;
    migrate|mv)     shift; cmd_migrate "$@" ;;
```

- [ ] **Step 5: Run and verify the test passes**

Run: `tests/migrate.sh`

Expected: all previous tests still pass, plus the 4 new assertions in the happy-path block pass. Total `7 passed, 0 failed`.

- [ ] **Step 6: Commit**

```bash
git add grove tests/migrate.sh
git commit -m "feat(grove): add cmd_migrate <branch> relocation

Moves a branch's existing worktree into grove's canonical
.worktrees/<branch> path under the main repo root via git worktree
move. No flag handling yet; bare-minimum guards (missing branch,
destination conflict, already-canonical no-op)."
```

---

## Task 3: Safety guards — locked worktrees, dirty trees, force flag

**Files:**
- Modify: `grove` — extend `cmd_migrate` with safety checks and a `-f`/`--force` flag.
- Test: `tests/migrate.sh` — add a safety block.

**Interfaces:**
- Consumes: same as Task 2 plus `git -C <path> status --porcelain` and `git worktree list --porcelain` `locked` field.
- Produces: `cmd_migrate <branch> [-f|--force]`. Without `-f`, refuses to migrate a locked worktree and refuses (with a useful message) when the source worktree has uncommitted changes. With `-f`, proceeds anyway.

- [ ] **Step 1: Write the failing safety tests**

Append to `tests/migrate.sh` before the final summary block:

```bash
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
out_refused="$(cd "$dirty_repo" && cmd_migrate feature-dirty 2>&1)"
rc_refused=$?
set -e
assert_eq "$rc_refused" '1' 'dirty source exits non-zero'
assert_contains "$out_refused" 'uncommitted' 'mentions uncommitted changes'
assert_eq "$(test -d "$TMP/feature-dirty-external" && echo yes || echo no)" 'yes' 'source still present after refusal'

(
  cd "$dirty_repo"
  cmd_migrate feature-dirty -f
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
out_locked="$(cd "$lock_repo" && cmd_migrate feature-locked 2>&1)"
rc_locked=$?
set -e
assert_eq "$rc_locked" '1' 'locked source exits non-zero'
assert_contains "$out_locked" 'locked' 'mentions the lock'

# Unlock so trap-cleanup of $TMP can remove it
git -C "$lock_repo" worktree unlock "$TMP/feature-locked-external" >/dev/null 2>&1 || true
```

- [ ] **Step 2: Run and verify the four new assertions fail**

Run: `tests/migrate.sh`

Expected: the dirty-refusal and locked-refusal assertions fail (current `cmd_migrate` would silently relocate or fail with a generic git error, not the user-facing strings we asserted on).

- [ ] **Step 3: Replace `cmd_migrate` with the safety-checked version**

In `grove`, replace the body of `cmd_migrate` (the function added in Task 2) with:

```bash
cmd_migrate() {
  [ $# -ge 1 ] || die "usage: grove migrate <branch> [-f]"
  require_repo
  local branch="$1" force=0
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      -f|--force) force=1 ;;
      *)          die "unknown option: $1" ;;
    esac
    shift
  done

  local root src dst
  root="$(main_root)"; dst="$root/.worktrees/$branch"

  src="$(_worktree_path_for "$branch")"
  [ -n "$src" ] || die "no worktree for branch '$branch' — use: grove attach $branch"
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
}
```

- [ ] **Step 4: Run and verify all tests pass**

Run: `tests/migrate.sh`

Expected: `13 passed, 0 failed` (3 from Task 1 + 4 from Task 2 + 6 from Task 3).

- [ ] **Step 5: Commit**

```bash
git add grove tests/migrate.sh
git commit -m "feat(grove): guard cmd_migrate against locked and dirty worktrees

Refuse to migrate a worktree that's locked or has uncommitted changes.
Accept -f/--force to override (passes --force through to git worktree
move so dirty trees survive the relocation)."
```

---

## Task 4: `--adopt` — skip the move, just register

**Files:**
- Modify: `grove` — extend `cmd_migrate` argument parsing for `--adopt`.
- Test: `tests/migrate.sh` — add an adopt block.

**Interfaces:**
- Consumes: everything from Task 3.
- Produces: `cmd_migrate <branch> --adopt` — verifies the worktree exists (any path), prints `▸ adopted <branch> at <path>` (no `.worktrees/` move), and returns 0. Mutually exclusive with `-f` (the source isn't moved, so dirty/locked don't apply). Sets up the path for Task 6's session restart to find.

- [ ] **Step 1: Write the failing adopt test**

Append to `tests/migrate.sh` before the final summary block:

```bash
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
  cmd_migrate feature-adopt --adopt
) > "$TMP/adopt.out" 2>&1

assert_eq "$(test -d "$TMP/feature-adopt-external" && echo yes || echo no)" 'yes' 'adopt leaves source path in place'
assert_eq "$(test -d "$adopt_repo/.worktrees/feature-adopt" && echo yes || echo no)" 'no' 'adopt does not create canonical path'
assert_contains "$(cat "$TMP/adopt.out")" 'adopted' 'adopt announces itself'
```

- [ ] **Step 2: Run and verify it fails**

Run: `tests/migrate.sh`

Expected: the `--adopt` flag is rejected as `unknown option`, so the test exits non-zero and the assertions fail.

- [ ] **Step 3: Add `--adopt` handling to `cmd_migrate`**

In `grove`, modify `cmd_migrate`: add `adopt=0` to the local declarations, add the parsing arm, and short-circuit before the destination-conflict check. Replace the existing function body with:

```bash
cmd_migrate() {
  [ $# -ge 1 ] || die "usage: grove migrate <branch> [-f|--adopt]"
  require_repo
  local branch="$1" force=0 adopt=0
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      -f|--force) force=1 ;;
      --adopt)    adopt=1 ;;
      *)          die "unknown option: $1" ;;
    esac
    shift
  done

  local root src dst
  root="$(main_root)"; dst="$root/.worktrees/$branch"

  src="$(_worktree_path_for "$branch")"
  [ -n "$src" ] || die "no worktree for branch '$branch' — use: grove attach $branch"

  if [ "$adopt" -eq 1 ]; then
    info "adopted $branch at $src"
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
}
```

- [ ] **Step 4: Run and verify all tests pass**

Run: `tests/migrate.sh`

Expected: `16 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add grove tests/migrate.sh
git commit -m "feat(grove): add --adopt to cmd_migrate

When the existing worktree path is fine (different volume, deliberate
location, etc.), --adopt skips the git worktree move and just reports
the registration. Sets up the upcoming session-restart code path to
find the right worktree."
```

---

## Task 5: `--all` — sweep every out-of-place worktree

**Files:**
- Modify: `grove` — add an `--all` branch to `cmd_migrate` that iterates.
- Test: `tests/migrate.sh` — add an `--all` block.

**Interfaces:**
- Consumes: `cmd_migrate <branch>` (single-branch form, Task 4) for the per-branch loop step; the porcelain output of `git worktree list`.
- Produces: `cmd_migrate --all [-f]` — for the current repo, iterates every worktree whose path is not under `$(main_root)/.worktrees/`, skips the main worktree itself, and runs the single-branch migrate path for each. Per-branch failures (locked, dirty without `-f`) print the error and continue with the next; the command's exit status is 0 if every successfully-processed branch migrated, 1 if any failed.

- [ ] **Step 1: Write the failing --all test**

Append to `tests/migrate.sh` before the final summary block:

```bash
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
```

- [ ] **Step 2: Run and verify it fails**

Run: `tests/migrate.sh`

Expected: `--all` is rejected as `unknown option` (and the first positional arg `--all` is being parsed as the branch name in the existing code path), so the assertions fail.

- [ ] **Step 3: Add the `--all` branch**

In `grove`, modify `cmd_migrate` so that an `--all` first positional is handled before single-branch logic. Replace the function with:

```bash
cmd_migrate() {
  [ $# -ge 1 ] || die "usage: grove migrate <branch> [-f|--adopt]  |  grove migrate --all [-f]"
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
      if ! cmd_migrate "$branch" $force_flag; then
        any_fail=1
      fi
    done < <(git worktree list --porcelain | awk '/^worktree /{print substr($0, 10)}')
    return "$any_fail"
  fi

  local branch="$1" force=0 adopt=0
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      -f|--force) force=1 ;;
      --adopt)    adopt=1 ;;
      *)          die "unknown option: $1" ;;
    esac
    shift
  done

  local src dst
  dst="$root/.worktrees/$branch"

  src="$(_worktree_path_for "$branch")"
  [ -n "$src" ] || die "no worktree for branch '$branch' — use: grove attach $branch"

  if [ "$adopt" -eq 1 ]; then
    info "adopted $branch at $src"
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
}
```

Note: `cmd_migrate "$branch" $force_flag` deliberately leaves `$force_flag` unquoted so an empty value disappears rather than passing literal `""` as a second arg. The `die`-on-failure path inside the per-branch call would exit the whole `cmd_migrate --all` because `set -e` propagates; we need the loop to keep going. Wrap each call in a subshell to contain the exit:

Replace the loop body line `if ! cmd_migrate "$branch" $force_flag; then` with:

```bash
if ! ( cmd_migrate "$branch" $force_flag ); then
```

- [ ] **Step 4: Run and verify all tests pass**

Run: `tests/migrate.sh`

Expected: `23 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add grove tests/migrate.sh
git commit -m "feat(grove): add --all to cmd_migrate

Sweep every out-of-place worktree under the current repo and relocate
each into .worktrees/<branch>. Per-branch failures (locked, dirty
without -f) are reported and the loop continues; exit status is
non-zero if any branch failed."
```

---

## Task 6: Session restart after migrate

**Files:**
- Modify: `grove` — extend single-branch `cmd_migrate` to kill any tmux session pointing at the old path and start one at the new path.

**Interfaces:**
- Consumes: `_session_for`, `_start_session`, `_default_base`, `tmux has-session`/`kill-session`/`show-options`.
- Produces: after a successful single-branch migrate (move or adopt), the function calls `_start_session "$branch" "$dst_or_src" "$(_default_base)"`. If a tmux session for that branch already exists and is tagged `@grove-worktree` with the old path, kill it first so it re-spawns at the new location. `--all` does **not** auto-start sessions (avoids attaching to dozens of sessions during a sweep).

- [ ] **Step 1: Decide the test boundary**

The session-restart logic depends on tmux, which is awkward to test inside `tests/migrate.sh` (tmux may not be installed in CI, side effects leak across tests). For this task, do **not** add an automated test — instead add a manual verification recipe to the commit message and rely on the existing assertions to prove the relocation/adopt paths still work end-to-end.

- [ ] **Step 2: Add session restart to `cmd_migrate`**

In `grove`, in `cmd_migrate`, modify the single-branch path. After the `info "adopted $branch at $src"` line, before `return 0`, insert the restart block. Also add an identical block after the `info "migrated $branch ..."` line. To keep things DRY, factor a helper just above `cmd_migrate` and call it from both places. Insert above `cmd_migrate`:

```bash
_restart_session_at() {
  local branch="$1" wt="$2" session base existing_wt
  command -v tmux >/dev/null 2>&1 || return 0
  session="$(_session_for "$branch")"
  if tmux has-session -t "$session" 2>/dev/null; then
    existing_wt="$(tmux show-options -t "$session" -v @grove-worktree 2>/dev/null || true)"
    if [ -n "$existing_wt" ] && [ "$existing_wt" != "$wt" ]; then
      tmux kill-session -t "$session" 2>/dev/null && info "killed stale session $session ($existing_wt)" || true
    fi
  fi
  base="$(_default_base)"
  _start_session "$branch" "$wt" "$base"
}
```

Then in `cmd_migrate`'s `--adopt` arm, change:

```bash
  if [ "$adopt" -eq 1 ]; then
    info "adopted $branch at $src"
    return 0
  fi
```

to:

```bash
  if [ "$adopt" -eq 1 ]; then
    info "adopted $branch at $src"
    _restart_session_at "$branch" "$src"
    return 0
  fi
```

And at the very end of the function, after the `info "migrated $branch from $src to $dst"` line, add:

```bash
  _restart_session_at "$branch" "$dst"
```

Also make sure the `--all` branch does **not** call `_restart_session_at` — it already shells out to `cmd_migrate` per branch, which would start a tmux session per migrated branch. Guard against that by accepting a `--no-session` flag inside `cmd_migrate` and passing it from the `--all` loop. Add to the option-parsing arm:

```bash
      --no-session) no_session=1 ;;
```

declare `local no_session=0` next to `force`/`adopt`, and wrap both `_restart_session_at` calls:

```bash
  [ "$no_session" -eq 1 ] || _restart_session_at "$branch" "$src"   # in the adopt path
  [ "$no_session" -eq 1 ] || _restart_session_at "$branch" "$dst"   # at the end
```

Update the `--all` loop's call:

```bash
      if ! ( cmd_migrate "$branch" $force_flag --no-session ); then
```

Update the usage string at the top of `cmd_migrate`:

```bash
  [ $# -ge 1 ] || die "usage: grove migrate <branch> [-f|--adopt|--no-session]  |  grove migrate --all [-f]"
```

- [ ] **Step 3: Run the existing tests with `--no-session` plumbing**

Run: `tests/migrate.sh`

The existing tests don't pass `--no-session`, so they would start tmux sessions during the test run. To avoid that, update the `cmd_migrate` calls in each existing test block to add `--no-session`. In `tests/migrate.sh`, replace these lines:

- `cmd_migrate feature-a` → `cmd_migrate feature-a --no-session`
- `cmd_migrate feature-dirty 2>&1` → `cmd_migrate feature-dirty --no-session 2>&1`
- `cmd_migrate feature-dirty -f` → `cmd_migrate feature-dirty -f --no-session`
- `cmd_migrate feature-locked 2>&1` → `cmd_migrate feature-locked --no-session 2>&1`
- `cmd_migrate feature-adopt --adopt` → `cmd_migrate feature-adopt --adopt --no-session`

`cmd_migrate --all` doesn't need updating — it already passes `--no-session` internally.

Run: `tests/migrate.sh`

Expected: `23 passed, 0 failed`, no stray tmux sessions left behind (verify with `tmux ls 2>/dev/null | grep -F migrate- || echo none`).

- [ ] **Step 4: Manual verification**

In a real repo with tmux available:

```bash
# Set up: a branch checked out at a non-canonical path
git worktree add /tmp/scratch-wt -b scratch-migrate
cd <repo>
grove migrate scratch-migrate
# Expect: ▸ migrated scratch-migrate from /tmp/scratch-wt to <repo>/.worktrees/scratch-migrate
# Expect: ▸ starting session: <repo>-scratch-migrate
# Expect: dropped into a tmux session with the diff pane on the right
# Cleanup:
grove clean scratch-migrate -f
```

- [ ] **Step 5: Commit**

```bash
git add grove tests/migrate.sh
git commit -m "feat(grove): restart tmux session after migrate/adopt

Single-branch migrate (and --adopt) now restart the tmux session at
the new worktree path, killing any session still tagged with the old
path so the diff pane respawns correctly. --all skips the restart
(passes --no-session through) to avoid spawning a session per branch
during a sweep."
```

---

## Task 7: Hint from `cmd_attach` when the branch is already used elsewhere

**Files:**
- Modify: `grove` — in `cmd_attach`, detect the "branch already used by worktree" condition before calling `git worktree add` and short-circuit with a helpful pointer.
- Test: `tests/migrate.sh` — assert on the hint.

**Interfaces:**
- Consumes: `_worktree_path_for` (Task 1), `cmd_attach` itself.
- Produces: `cmd_attach <branch>` now, before calling `git worktree add`, checks `_worktree_path_for "$branch"`. If non-empty and not equal to `$root/.worktrees/$branch`, it dies with `branch '<branch>' is already checked out at <path> — use: grove migrate <branch>`. No `git worktree add` invocation in that case (avoids the cryptic raw git error the user originally hit).

- [ ] **Step 1: Write the failing hint test**

Append to `tests/migrate.sh` before the final summary block:

```bash
# === cmd_attach hint when branch is checked out elsewhere ===
printf '\n\033[1mcmd_attach hint\033[0m\n'

hint_repo="$(new_repo attach-hint)"
(
  cd "$hint_repo"
  git branch feature-hint
  git worktree add -q "$TMP/feature-hint-external" feature-hint
) >/dev/null

# avoid real tmux invocation in cmd_attach by stubbing tmux to be absent.
# easier: temporarily shadow PATH so tmux isn't found, which makes cmd_attach
# die early with "tmux is not installed" UNLESS we hit our new short-circuit first.
# instead, just call the worktree-add path directly by setting up the conditions
# and trapping the exit.
set +e
out_hint="$( cd "$hint_repo" && PATH=/usr/bin:/bin cmd_attach feature-hint 2>&1 )"
rc_hint=$?
set -e

assert_eq "$rc_hint" '1' 'attach with elsewhere-checkout exits non-zero'
assert_contains "$out_hint" 'grove migrate feature-hint' 'attach hints at grove migrate'
assert_contains "$out_hint" "$TMP/feature-hint-external" 'attach names the conflicting path'
```

- [ ] **Step 2: Run and verify the hint test fails**

Run: `tests/migrate.sh`

Expected: the assertions on `out_hint` fail because `cmd_attach` currently either dies on "tmux is not installed" (path stripped) or falls through to `git worktree add` and emits git's raw `fatal: '<branch>' is already used by worktree at ...` message.

- [ ] **Step 3: Add the early hint to `cmd_attach`**

In `grove`, in `cmd_attach`, after the `base="$(_default_base)"` line and **before** the `if tmux has-session -t "$session"` block, insert:

```bash
  local existing_path
  existing_path="$(_worktree_path_for "$branch")"
  if [ -n "$existing_path" ] && [ "$existing_path" != "$wt" ]; then
    die "branch '$branch' is already checked out at $existing_path — use: grove migrate $branch"
  fi
```

This runs the check independent of tmux availability and before any session attach, so the test path (no tmux on PATH) still surfaces the hint.

- [ ] **Step 4: Run and verify the tests pass**

Run: `tests/migrate.sh`

Expected: `26 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add grove tests/migrate.sh
git commit -m "feat(grove): hint at grove migrate from cmd_attach

When the requested branch is already checked out at a non-canonical
path, surface a useful pointer (grove migrate <branch>) instead of
letting git emit its raw 'already used by worktree at' fatal."
```

---

## Task 8: Edge-case coverage

**Files:**
- Test: `tests/migrate.sh` — extend with an edge-case block.

**Interfaces:**
- Consumes: everything from Tasks 1–7. No new public surface.
- Produces: assertions for every error and no-op path that previous tasks didn't already exercise: no-args usage error, unknown option, already-canonical no-op, destination-dir conflict, `--all` skipping the main worktree, `--all` on a repo with nothing to do.

- [ ] **Step 1: Write the failing edge-case block**

Append to `tests/migrate.sh` before the final summary block:

```bash
# === cmd_migrate edge cases ===
printf '\n\033[1mcmd_migrate edge cases\033[0m\n'

edge_repo="$(new_repo migrate-edges)"

# 1. no args → usage error
set +e
out_no_args="$(cd "$edge_repo" && cmd_migrate 2>&1)"
rc_no_args=$?
set -e
assert_eq "$rc_no_args" '1' 'no args exits non-zero'
assert_contains "$out_no_args" 'usage:' 'no args prints usage'

# 2. unknown option → die
(
  cd "$edge_repo"
  git branch edge-known
  git worktree add -q "$TMP/edge-external" edge-known
) >/dev/null
set +e
out_unknown="$(cd "$edge_repo" && cmd_migrate edge-known --bogus --no-session 2>&1)"
rc_unknown=$?
set -e
assert_eq "$rc_unknown" '1' 'unknown option exits non-zero'
assert_contains "$out_unknown" 'unknown option' 'unknown option names itself'
assert_eq "$(test -d "$TMP/edge-external" && echo yes || echo no)" 'yes' 'unknown option does not move'

# 3. already-canonical → no-op success
(
  cd "$edge_repo"
  git branch edge-canon
  git worktree add -q "$edge_repo/.worktrees/edge-canon" edge-canon
) >/dev/null
out_canon="$(cd "$edge_repo" && cmd_migrate edge-canon --no-session 2>&1)"
assert_contains "$out_canon" 'already at' 'canonical path reports already-at'
assert_eq "$(test -d "$edge_repo/.worktrees/edge-canon" && echo yes || echo no)" 'yes' 'canonical path still present'

# 4. destination directory exists as a stray (not a registered worktree) → die
(
  cd "$edge_repo"
  git branch edge-blocked
  git worktree add -q "$TMP/edge-blocked-src" edge-blocked
  mkdir -p "$edge_repo/.worktrees/edge-blocked"
  echo squatter > "$edge_repo/.worktrees/edge-blocked/file.txt"
) >/dev/null
set +e
out_blocked="$(cd "$edge_repo" && cmd_migrate edge-blocked --no-session 2>&1)"
rc_blocked=$?
set -e
assert_eq "$rc_blocked" '1' 'stray destination exits non-zero'
assert_contains "$out_blocked" 'destination already exists' 'stray dest message'
assert_eq "$(test -d "$TMP/edge-blocked-src" && echo yes || echo no)" 'yes' 'source untouched on dest conflict'
rm -rf "$edge_repo/.worktrees/edge-blocked"

# 5. --all skips the main worktree (never tries to migrate `main`)
(
  cd "$edge_repo"
  git branch edge-sweep
  git worktree add -q "$TMP/edge-sweep-external" edge-sweep
) >/dev/null
out_all="$(cd "$edge_repo" && cmd_migrate --all 2>&1)"
assert_eq "$(echo "$out_all" | grep -c 'migrated main')" '0' '--all does not migrate main'
assert_contains "$out_all" 'edge-sweep' '--all does migrate other branches'

# 6. --all with nothing to do exits 0 silently
clean_repo="$(new_repo migrate-nothing)"
set +e
out_nothing="$(cd "$clean_repo" && cmd_migrate --all 2>&1)"
rc_nothing=$?
set -e
assert_eq "$rc_nothing" '0' '--all with nothing to do exits 0'
assert_eq "$(echo "$out_nothing" | grep -c 'migrated')" '0' '--all with nothing prints no migrated lines'
```

- [ ] **Step 2: Run and verify each new assertion either passes immediately or fails for the documented reason**

Run: `tests/migrate.sh`

Expected: most assertions pass on the existing implementation. If any fail, the failure points to a real gap — fix the implementation in `grove` (not the test) until all pass. Specifically:
- If "unknown option does not move" fails, it means option parsing happens *after* the move — reorder the parser to run first.
- If "stray destination exits non-zero" fails, confirm the `[ -e "$dst" ] && die` line was preserved in the function body when later tasks rewrote it.

- [ ] **Step 3: Run the full suite**

Run: `tests/migrate.sh`

Expected: `40 passed, 0 failed` (26 from Tasks 1–7 + 14 new assertions here).

- [ ] **Step 4: Commit**

```bash
git add grove tests/migrate.sh
git commit -m "test(grove): cover cmd_migrate edge cases

Add explicit assertions for no-args usage, unknown option, already
canonical no-op, stray destination conflict, --all skipping main, and
--all on a repo with nothing to migrate. Any implementation fixes
caught while landing these tests are folded into this commit."
```

---

## Task 9: Help text and README

**Files:**
- Modify: `grove` — the header comment block (lines 9-27) is what `usage()` reads.
- Modify: `README.md` — the `## Commands` section's code block.

**Interfaces:**
- Consumes: nothing.
- Produces: `grove help` and the project README both list and describe `grove migrate`.

- [ ] **Step 1: Update the in-script usage docstring**

In `grove`, in the header comment block, immediately after the `grove init` line (currently around line 26), insert these lines (preserve the leading `# ` and column alignment used by neighbours):

```text
#   grove migrate <branch> [-f]          Move <branch>'s existing worktree into
#                                        .worktrees/<branch> via git worktree move.
#                                        -f passes --force through (allows dirty trees,
#                                        skips lock check).
#   grove migrate <branch> --adopt       Don't move — register the existing path with
#                                        grove and (re)launch the tmux session there.
#   grove migrate --all [-f]             Sweep every out-of-place worktree in this repo.
```

- [ ] **Step 2: Update README's commands block**

In `README.md`, in the ```` ``` ```` code block under `## Commands`, after the `grove init` line, insert:

```text
grove migrate <branch> [-f]           Relocate <branch>'s worktree into
                                      .worktrees/<branch>. -f allows dirty trees.
grove migrate <branch> --adopt        Adopt the existing path without moving.
grove migrate --all [-f]              Sweep every out-of-place worktree in the repo.
```

- [ ] **Step 3: Sanity-check both renders**

```bash
./grove help | head -40
```

Expected: `grove migrate` lines visible in the help output.

Read `README.md` and confirm the new lines sit inside the code fence and align with their neighbours.

- [ ] **Step 4: Commit**

```bash
git add grove README.md
git commit -m "docs(grove): document grove migrate

Add migrate, --adopt, --all to the in-script usage docstring and the
README commands block."
```

Note: the plan file at `docs/superpowers/plans/2026-06-20-grove-migrate.md` is **deliberately not staged** — per project convention, planning docs stay untracked.

---

## Self-Review

**Spec coverage** — every behavior in the suggested shape is covered:
- `grove migrate <branch>` happy path → Task 2.
- Safety (locked, dirty, `-f`) → Task 3.
- `--adopt` → Task 4.
- `--all` → Task 5.
- Session restart at the new path + killing the stale session → Task 6.
- `cmd_attach` hint → Task 7.
- Edge cases (no-args, unknown option, no-op, stray dest, `--all` skips main, `--all` no-op) → Task 8.
- Help / README → Task 9.

**Test coverage** — automated assertions per task: 3 + 4 + 6 + 3 + 7 + 0 (manual tmux verification) + 3 + 14 = **40 total**. Every public branch of `cmd_migrate` (happy, dirty, locked, force, adopt, all, no-session, unknown-option, no-arg, already-canonical, stray-destination, all-skips-main, all-noop) has an explicit assertion. The session-restart behavior is the only path left to manual verification (in Task 6) because it requires a live tmux server.

**Placeholder scan** — no `TBD`/`later`/`similar to Task N`. Every code change shows the actual code; every test shows the actual assertions; every commit shows the message.

**Type / name consistency** — `_worktree_path_for` is defined in Task 1 and used by Tasks 2-7 with the same signature. `cmd_migrate` keeps the same single-branch arg order across Tasks 2-7. `_restart_session_at` (Task 6) is called by name consistently. The `--no-session` flag introduced in Task 6 is back-propagated into the test calls in the same task, so subsequent tasks don't see test failures from it. The dispatcher entry uses `migrate|mv` from Task 2 onward; no later task renames it.

**Carved-out scope** — no changes to `cmd_clean`, the diff renderer, the per-repo hooks, or `setup.sh`/`teardown.sh` execution. Migrate explicitly does **not** re-run `setup.sh` because the worktree is already provisioned.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-06-20-grove-migrate.md`. Two execution options:

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?
