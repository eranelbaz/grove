### Grove Diff Pane Sections Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the grove diff pane with four new sections — commits-on-branch with ahead/behind counts vs the base branch, branch/commit age, GitHub PR status, and CI check rollup — all toggleable via env vars or a per-repo config file.

**Architecture:** Add four pure render helpers (`_render_commits`, `_render_age`, `_render_pr`, `_render_ci`) to the existing `grove` bash script and compose them inside `_cmd_diff_pane`. Wrap `gh`-dependent helpers in a cache governed by `GROVE_GH_REFRESH` (default 30s) so the 2s outer loop never spawns 30 `gh` calls/minute. Configuration loads from `~/.grove/config` then `~/.grove/<repo>/config`; environment variables take precedence via the `: "${VAR:=default}"` idiom.

**Tech Stack:** Bash 3.2+, git 2.5+, tmux, optional `gh` CLI. Tests use a vanilla bash test runner (no `bats` dep) — matches grove's "no extra runtime deps" philosophy and lets us source the script directly.

## Global Constraints

- All script changes land in `/Users/eranelbaz/projects/grove/grove`. Grove remains a single bash file.
- The `gh` CLI is the only new runtime dependency, and it is **optional**. Every path that calls `gh` must short-circuit cleanly when `command -v gh` returns non-zero or when `gh` exits non-zero (no PR, not in a GitHub repo, network failure).
- Follow grove's existing style: `info()` for status output, `\033[…]` ANSI for color, `local` inside functions, no comments unless the *why* is non-obvious (per user CLAUDE.md).
- Every render helper must be testable by sourcing `grove` from a test script. The bottom-of-file `main "$@"` must be gated so sourcing does not execute it.
- Commits use Conventional-Commits prefixes (`feat:`, `test:`, `refactor:`, `docs:`) for clarity. No special signing required.
- Tests live under `tests/`. The runner is `tests/run.sh`. Run it with `bash tests/run.sh` from the repo root.

---

### Task 1: Make grove sourceable and scaffold the test runner

**Files:**
- Modify: `/Users/eranelbaz/projects/grove/grove` (last few lines — gate `main`)
- Create: `/Users/eranelbaz/projects/grove/tests/run.sh`

**Interfaces:**
- Consumes: nothing (this is the foundation task).
- Produces: a sourceable `grove` script and `tests/run.sh` exposing `assert_eq`, `assert_contains`, `assert_empty`, and `new_repo` to every later task.

- [ ] **Step 1: Write the failing test**

Create `/Users/eranelbaz/projects/grove/tests/run.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GROVE="$ROOT/grove"
TMP="$(mktemp -d -t grove-tests.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
. "$GROVE"

PASS=0
FAIL=0
FAILED_TESTS=()

assert_eq() {
  local got="$1" want="$2" name="$3"
  if [ "$got" = "$want" ]; then
    printf '  \033[32m✓\033[0m %s\n' "$name"
    PASS=$((PASS+1))
  else
    printf '  \033[31m✗\033[0m %s\n' "$name"
    printf '    want: %q\n' "$want"
    printf '    got:  %q\n' "$got"
    FAIL=$((FAIL+1))
    FAILED_TESTS+=("$name")
  fi
}

assert_contains() {
  local got="$1" want="$2" name="$3"
  if printf '%s' "$got" | grep -qF -- "$want"; then
    printf '  \033[32m✓\033[0m %s\n' "$name"
    PASS=$((PASS+1))
  else
    printf '  \033[31m✗\033[0m %s\n' "$name"
    printf '    expected to contain: %q\n' "$want"
    printf '    got: %q\n' "$got"
    FAIL=$((FAIL+1))
    FAILED_TESTS+=("$name")
  fi
}

assert_empty() {
  local got="$1" name="$2"
  if [ -z "$got" ]; then
    printf '  \033[32m✓\033[0m %s\n' "$name"
    PASS=$((PASS+1))
  else
    printf '  \033[31m✗\033[0m %s\n' "$name"
    printf '    expected empty, got: %q\n' "$got"
    FAIL=$((FAIL+1))
    FAILED_TESTS+=("$name")
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

# === sanitize (smoke test — verifies sourcing works) ===
printf '\n\033[1msanitize\033[0m\n'
assert_eq "$(sanitize 'foo/bar:baz qux.zap')" 'foo-bar-baz-qux-zap' 'sanitize replaces / : space .'

# === MARKER: tests appended by later tasks ===

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf '\nfailed:\n'
  for t in "${FAILED_TESTS[@]}"; do printf '  - %s\n' "$t"; done
  exit 1
fi
```

Then make it executable:

```bash
chmod +x /Users/eranelbaz/projects/grove/tests/run.sh
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd /Users/eranelbaz/projects/grove
bash tests/run.sh
```

Expected: the run hangs or exits via `main` being invoked when grove is sourced, because the current grove script ends with an unconditional `main "$@"`. Specifically you will see grove printing its usage banner and the `sanitize` assertion never running — that is the failure we are about to fix.

- [ ] **Step 3: Gate `main "$@"` in grove**

Open `/Users/eranelbaz/projects/grove/grove` and find the final two lines:

```bash
main "$@"
```

Replace with:

```bash
if [ "${BASH_SOURCE[0]}" = "${0:-}" ]; then
  main "$@"
fi
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd /Users/eranelbaz/projects/grove
bash tests/run.sh
```

Expected output:

```
sanitize
  ✓ sanitize replaces / : space .

1 passed, 0 failed
```

- [ ] **Step 5: Commit**

```bash
cd /Users/eranelbaz/projects/grove
git add grove tests/run.sh
git commit -m "test: add sourceable test harness for grove"
```

---

### Task 2: Config loading + `grove init` scaffolds a config template

**Files:**
- Modify: `/Users/eranelbaz/projects/grove/grove` (add `_load_config` helper; extend `cmd_init`)
- Modify: `/Users/eranelbaz/projects/grove/tests/run.sh` (append tests)

**Interfaces:**
- Consumes: `GROVE_HOME` (already defined in grove), repo root via `main_root()`.
- Produces:
  - `_load_config` — sources `$GROVE_HOME/config` then `$GROVE_HOME/<repo>/config` if present and sets defaults: `GROVE_DIFF_REFRESH=2`, `GROVE_GH_REFRESH=30`, `GROVE_MAX_COMMITS=10`, `GROVE_SHOW_COMMITS=1`, `GROVE_SHOW_AGE=1`, `GROVE_SHOW_PR=1`, `GROVE_SHOW_CI=1`. Env vars set before `_load_config` runs always win.
  - `cmd_init` additionally writes a `config` template alongside `setup.sh` and `teardown.sh`.

- [ ] **Step 1: Write the failing tests**

Open `/Users/eranelbaz/projects/grove/tests/run.sh` and replace the line:

```bash
# === MARKER: tests appended by later tasks ===
```

with:

```bash
# === _load_config ===
printf '\n\033[1m_load_config\033[0m\n'

cfg_dir="$TMP/cfg"
mkdir -p "$cfg_dir/myrepo"
cat > "$cfg_dir/myrepo/config" <<'EOF'
: "${GROVE_GH_REFRESH:=99}"
: "${GROVE_MAX_COMMITS:=7}"
EOF

(
  unset GROVE_GH_REFRESH GROVE_DIFF_REFRESH GROVE_MAX_COMMITS \
        GROVE_SHOW_COMMITS GROVE_SHOW_AGE GROVE_SHOW_PR GROVE_SHOW_CI
  GROVE_HOME="$cfg_dir"
  _load_config "myrepo"
  printf '%s|%s|%s\n' "$GROVE_GH_REFRESH" "$GROVE_DIFF_REFRESH" "$GROVE_MAX_COMMITS"
) > "$TMP/cfg-no-env.out"

assert_eq "$(cat "$TMP/cfg-no-env.out")" '99|2|7' 'config file sets values, defaults fill the rest'

(
  unset GROVE_DIFF_REFRESH GROVE_MAX_COMMITS \
        GROVE_SHOW_COMMITS GROVE_SHOW_AGE GROVE_SHOW_PR GROVE_SHOW_CI
  export GROVE_GH_REFRESH=15
  GROVE_HOME="$cfg_dir"
  _load_config "myrepo"
  printf '%s\n' "$GROVE_GH_REFRESH"
) > "$TMP/cfg-env-wins.out"

assert_eq "$(cat "$TMP/cfg-env-wins.out")" '15' 'env var beats config file value'

# === cmd_init scaffolds config template ===
printf '\n\033[1mcmd_init scaffolds config\033[0m\n'

init_repo="$(new_repo init-test)"
(
  cd "$init_repo"
  GROVE_HOME="$TMP/grove-home" cmd_init >/dev/null
)
assert_eq "$(test -f "$TMP/grove-home/init-test/config" && echo yes || echo no)" 'yes' 'cmd_init writes config'
assert_contains "$(cat "$TMP/grove-home/init-test/config")" ': "${GROVE_GH_REFRESH:=' 'config uses env-wins idiom'
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /Users/eranelbaz/projects/grove
bash tests/run.sh
```

Expected: failures because `_load_config` does not exist and `cmd_init` does not write a `config` file. You will see "_load_config: command not found" or similar shell errors.

- [ ] **Step 3: Implement `_load_config`**

In `/Users/eranelbaz/projects/grove/grove`, find this block near the top of the file:

```bash
GROVE_HOME="${GROVE_HOME:-$HOME/.grove}"
GROVE_BIN="$(cd "$(dirname "$0")" && pwd -P)/$(basename "$0")"
```

Add immediately below:

```bash
_load_config() {
  local repo="${1:-}"
  [ -f "$GROVE_HOME/config" ] && . "$GROVE_HOME/config"
  [ -n "$repo" ] && [ -f "$GROVE_HOME/$repo/config" ] && . "$GROVE_HOME/$repo/config"
  : "${GROVE_DIFF_REFRESH:=2}"
  : "${GROVE_GH_REFRESH:=30}"
  : "${GROVE_MAX_COMMITS:=10}"
  : "${GROVE_SHOW_COMMITS:=1}"
  : "${GROVE_SHOW_AGE:=1}"
  : "${GROVE_SHOW_PR:=1}"
  : "${GROVE_SHOW_CI:=1}"
}
```

- [ ] **Step 4: Extend `cmd_init` to scaffold a `config` template**

In `/Users/eranelbaz/projects/grove/grove`, find the closing of `cmd_init`:

```bash
  if [ -e "$dir/teardown.sh" ]; then
    info "already exists: $dir/teardown.sh"
  else
    cat > "$dir/teardown.sh" <<'EOF'
```

…then scroll down to the end of that heredoc and find the final lines of `cmd_init`:

```bash
    chmod +x "$dir/teardown.sh"; info "created $dir/teardown.sh"
  fi
  printf '%s\n' "$dir"
}
```

Insert a new block just before `printf '%s\n' "$dir"`:

```bash
  if [ -e "$dir/config" ]; then
    info "already exists: $dir/config"
  else
    cat > "$dir/config" <<'EOF'
# grove per-repo config. Sourced by the diff pane on every spawn.
# Use ': "${VAR:=value}"' so environment variables override these.
#
# How often the diff pane redraws (seconds).
: "${GROVE_DIFF_REFRESH:=2}"
# How often gh-backed sections (PR, CI) refresh (seconds).
: "${GROVE_GH_REFRESH:=30}"
# Max commits to list under the ahead/behind line.
: "${GROVE_MAX_COMMITS:=10}"
# Section toggles (1 = on, 0 = off).
: "${GROVE_SHOW_COMMITS:=1}"
: "${GROVE_SHOW_AGE:=1}"
: "${GROVE_SHOW_PR:=1}"
: "${GROVE_SHOW_CI:=1}"
EOF
    info "created $dir/config"
  fi
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
cd /Users/eranelbaz/projects/grove
bash tests/run.sh
```

Expected: 5 passed, 0 failed.

- [ ] **Step 6: Commit**

```bash
cd /Users/eranelbaz/projects/grove
git add grove tests/run.sh
git commit -m "feat: per-repo config file with env-var override"
```

---

### Task 3: `_render_commits` — ahead/behind from base + commit log

**Files:**
- Modify: `/Users/eranelbaz/projects/grove/grove` (add helper)
- Modify: `/Users/eranelbaz/projects/grove/tests/run.sh` (append tests)

**Interfaces:**
- Consumes: a base ref name as `$1`. Reads `GROVE_MAX_COMMITS` from env (set by `_load_config`).
- Produces: `_render_commits BASE` prints one ANSI-dim header line `── N ahead · M behind BASE ──` followed by up to `GROVE_MAX_COMMITS` `git log --oneline` entries when ahead > 0. Returns 0 always.

- [ ] **Step 1: Write the failing tests**

Append to `/Users/eranelbaz/projects/grove/tests/run.sh` (after the existing tests, before the `printf '\n%d passed' …` summary line):

```bash
# === _render_commits ===
printf '\n\033[1m_render_commits\033[0m\n'

commit_repo="$(new_repo commits-test)"
(
  cd "$commit_repo"
  git checkout -q -b feature
  for i in 1 2 3; do
    echo "$i" > "f$i.txt"
    git add "f$i.txt"
    git commit -q -m "feat: add f$i"
  done
)

out_three="$(cd "$commit_repo" && GROVE_MAX_COMMITS=10 _render_commits main)"
assert_contains "$out_three" '3 ahead · 0 behind main' '3 ahead summary'
assert_contains "$out_three" 'feat: add f1' 'oldest commit listed'
assert_contains "$out_three" 'feat: add f3' 'newest commit listed'

(
  cd "$commit_repo"
  git checkout -q main
  echo extra > base.txt
  git add base.txt
  git commit -q -m "feat: advance main"
  git checkout -q feature
)
out_behind="$(cd "$commit_repo" && GROVE_MAX_COMMITS=10 _render_commits main)"
assert_contains "$out_behind" '3 ahead · 1 behind main' 'behind count surfaces'

(
  cd "$commit_repo"
  git checkout -q main
)
out_synced="$(cd "$commit_repo" && GROVE_MAX_COMMITS=10 _render_commits main)"
assert_contains "$out_synced" '0 ahead · 0 behind main' 'in-sync shows zeros'

out_capped="$(cd "$commit_repo" && git checkout -q feature && GROVE_MAX_COMMITS=2 _render_commits main)"
n_lines="$(printf '%s\n' "$out_capped" | grep -c 'feat: add f')"
assert_eq "$n_lines" '2' 'GROVE_MAX_COMMITS caps the log'
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /Users/eranelbaz/projects/grove
bash tests/run.sh
```

Expected: failures with "_render_commits: command not found".

- [ ] **Step 3: Implement `_render_commits`**

In `/Users/eranelbaz/projects/grove/grove`, find the existing `_render_diff_tree() {` declaration. Immediately **before** it, insert:

```bash
_render_commits() {
  local base="$1"
  local max="${GROVE_MAX_COMMITS:-10}"
  local counts behind ahead
  counts="$(git rev-list --left-right --count "$base"...HEAD 2>/dev/null || printf '0\t0')"
  behind="$(printf '%s' "$counts" | awk '{print $1}')"
  ahead="$(printf '%s' "$counts" | awk '{print $2}')"
  : "${behind:=0}"
  : "${ahead:=0}"
  printf '\033[2m── %s ahead · %s behind %s ──\033[0m\n' "$ahead" "$behind" "$base"
  if [ "$ahead" -gt 0 ] 2>/dev/null; then
    git --no-pager log --oneline --no-decorate "$base"..HEAD 2>/dev/null | head -n "$max"
  fi
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd /Users/eranelbaz/projects/grove
bash tests/run.sh
```

Expected: 11 passed, 0 failed.

- [ ] **Step 5: Commit**

```bash
cd /Users/eranelbaz/projects/grove
git add grove tests/run.sh
git commit -m "feat: render commit log with ahead/behind counts vs base"
```

---

### Task 4: `_render_age` — branched / last-commit age

**Files:**
- Modify: `/Users/eranelbaz/projects/grove/grove` (add helper)
- Modify: `/Users/eranelbaz/projects/grove/tests/run.sh` (append tests)

**Interfaces:**
- Consumes: a base ref name as `$1`.
- Produces: `_render_age BASE` prints one ANSI-dim line. When commits exist on the branch: `── branched <reltime> · last commit <reltime> ──`. When the worktree's HEAD equals the base or has no commits ahead: `── no commits on this branch yet · base last touched <reltime> ──`. Returns 0 always.

- [ ] **Step 1: Write the failing tests**

Append to `tests/run.sh` (before the summary line):

```bash
# === _render_age ===
printf '\n\033[1m_render_age\033[0m\n'

age_repo="$(new_repo age-test)"
(
  cd "$age_repo"
  git checkout -q -b feature
  echo x > x.txt
  git add x.txt
  git commit -q -m "feat: add x"
)

out_branch="$(cd "$age_repo" && _render_age main)"
assert_contains "$out_branch" 'branched' 'branched line present'
assert_contains "$out_branch" 'last commit' 'last commit time present'

(
  cd "$age_repo"
  git checkout -q main
)
out_main="$(cd "$age_repo" && _render_age main)"
assert_contains "$out_main" 'no commits on this branch yet' 'in-sync branch reports no commits'
assert_contains "$out_main" 'base last touched' 'fallback shows base timestamp'
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /Users/eranelbaz/projects/grove
bash tests/run.sh
```

Expected: failures with "_render_age: command not found".

- [ ] **Step 3: Implement `_render_age`**

In `/Users/eranelbaz/projects/grove/grove`, immediately after the closing `}` of `_render_commits` (which you just added), insert:

```bash
_render_age() {
  local base="$1"
  local first last
  first="$(git --no-pager log --reverse --format=%cr "$base"..HEAD 2>/dev/null | head -1)"
  last="$(git --no-pager log -1 --format=%cr 2>/dev/null)"
  if [ -n "$first" ]; then
    printf '\033[2m── branched %s · last commit %s ──\033[0m\n' "$first" "$last"
  elif [ -n "$last" ]; then
    printf '\033[2m── no commits on this branch yet · base last touched %s ──\033[0m\n' "$last"
  fi
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd /Users/eranelbaz/projects/grove
bash tests/run.sh
```

Expected: 15 passed, 0 failed.

- [ ] **Step 5: Commit**

```bash
cd /Users/eranelbaz/projects/grove
git add grove tests/run.sh
git commit -m "feat: render branch age and last-commit time"
```

---

### Task 5: Fake-`gh` harness + `_render_pr`

**Files:**
- Create: `/Users/eranelbaz/projects/grove/tests/helpers/fake-gh`
- Create: `/Users/eranelbaz/projects/grove/tests/fixtures/pr-open.txt`
- Create: `/Users/eranelbaz/projects/grove/tests/fixtures/pr-draft.txt`
- Modify: `/Users/eranelbaz/projects/grove/grove` (add helper)
- Modify: `/Users/eranelbaz/projects/grove/tests/run.sh` (append tests)

**Interfaces:**
- Consumes: the `gh` CLI on `$PATH`. Reads no args.
- Produces: `_render_pr` prints one ANSI-dim line `── PR #N · <state> · <review-decision> ──` when `gh pr view` succeeds. Prints nothing (and returns 0) when `gh` is missing, exits non-zero, or returns an empty JSON object.

- [ ] **Step 1: Create fixtures and the fake gh**

```bash
mkdir -p /Users/eranelbaz/projects/grove/tests/helpers /Users/eranelbaz/projects/grove/tests/fixtures
```

Create `/Users/eranelbaz/projects/grove/tests/fixtures/pr-open.txt`:

```
PR #42 · open · approved
```

Create `/Users/eranelbaz/projects/grove/tests/fixtures/pr-draft.txt`:

```
PR #43 · draft · no reviews
```

Create `/Users/eranelbaz/projects/grove/tests/helpers/fake-gh`:

```bash
#!/usr/bin/env bash
case "$*" in
  *statusCheckRollup*)
    if [ -n "${FAKE_GH_CI:-}" ] && [ -f "$FAKE_GH_CI" ]; then
      cat "$FAKE_GH_CI"
    else
      exit 1
    fi
    ;;
  *number*state*)
    if [ -n "${FAKE_GH_PR:-}" ] && [ -f "$FAKE_GH_PR" ]; then
      cat "$FAKE_GH_PR"
    else
      exit 1
    fi
    ;;
  *)
    exit 2
    ;;
esac
```

Make it executable:

```bash
chmod +x /Users/eranelbaz/projects/grove/tests/helpers/fake-gh
```

- [ ] **Step 2: Write the failing tests**

Append to `tests/run.sh` (before the summary line):

```bash
# === _render_pr ===
printf '\n\033[1m_render_pr\033[0m\n'

PATH_BAK="$PATH"
PATH="$ROOT/tests/helpers:$PATH_BAK"
ln -sf "$ROOT/tests/helpers/fake-gh" "$ROOT/tests/helpers/gh"

FAKE_GH_PR="$ROOT/tests/fixtures/pr-open.txt"
out_pr_open="$(_render_pr)"
assert_contains "$out_pr_open" 'PR #42 · open · approved' 'open PR rendered'
assert_contains "$out_pr_open" '──' 'PR section uses divider'

FAKE_GH_PR="$ROOT/tests/fixtures/pr-draft.txt"
out_pr_draft="$(_render_pr)"
assert_contains "$out_pr_draft" 'PR #43 · draft · no reviews' 'draft PR rendered'

unset FAKE_GH_PR
out_pr_none="$(_render_pr)"
assert_empty "$out_pr_none" 'missing PR returns empty string'

rm -f "$ROOT/tests/helpers/gh"
PATH="$PATH_BAK"
```

- [ ] **Step 3: Run tests to verify they fail**

```bash
cd /Users/eranelbaz/projects/grove
bash tests/run.sh
```

Expected: failures with "_render_pr: command not found".

- [ ] **Step 4: Implement `_render_pr`**

In `/Users/eranelbaz/projects/grove/grove`, immediately after the closing `}` of `_render_age`, insert:

```bash
_render_pr() {
  command -v gh >/dev/null 2>&1 || return 0
  local out
  out="$(gh pr view --json number,state,isDraft,reviewDecision --jq \
    '"PR #\(.number) · \(if .isDraft then "draft" else (.state | ascii_downcase) end) · \(if .reviewDecision == null or .reviewDecision == "" then "no reviews" else (.reviewDecision | ascii_downcase | gsub("_"; " ")) end)"' \
    2>/dev/null)" || return 0
  [ -n "$out" ] || return 0
  printf '\033[2m── \033[0m%s\033[2m ──\033[0m\n' "$out"
}
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
cd /Users/eranelbaz/projects/grove
bash tests/run.sh
```

Expected: 19 passed, 0 failed.

- [ ] **Step 6: Commit**

```bash
cd /Users/eranelbaz/projects/grove
git add grove tests/run.sh tests/helpers/fake-gh tests/fixtures/pr-open.txt tests/fixtures/pr-draft.txt
git commit -m "feat: render GitHub PR status via gh"
```

---

### Task 6: `_render_ci` — CI check rollup

**Files:**
- Create: `/Users/eranelbaz/projects/grove/tests/fixtures/ci-mixed.txt`
- Create: `/Users/eranelbaz/projects/grove/tests/fixtures/ci-green.txt`
- Modify: `/Users/eranelbaz/projects/grove/grove` (add helper)
- Modify: `/Users/eranelbaz/projects/grove/tests/run.sh` (append tests)

**Interfaces:**
- Consumes: the `gh` CLI on `$PATH`. Reads no args.
- Produces: `_render_ci` prints one ANSI-dim line. With mixed checks: `── CI · ✓ 3 · ✗ 1 · ⏳ 2 ──`. With all green: `── CI · ✓ all green (6) ──`. Prints nothing when `gh` is missing, exits non-zero, or the PR has no checks.

- [ ] **Step 1: Create fixtures**

Create `/Users/eranelbaz/projects/grove/tests/fixtures/ci-mixed.txt`:

```
CI · ✓ 3 · ✗ 1 · ⏳ 2
```

Create `/Users/eranelbaz/projects/grove/tests/fixtures/ci-green.txt`:

```
CI · ✓ all green (6)
```

- [ ] **Step 2: Write the failing tests**

Append to `tests/run.sh` (before the summary line):

```bash
# === _render_ci ===
printf '\n\033[1m_render_ci\033[0m\n'

PATH_BAK="$PATH"
PATH="$ROOT/tests/helpers:$PATH_BAK"
ln -sf "$ROOT/tests/helpers/fake-gh" "$ROOT/tests/helpers/gh"

FAKE_GH_CI="$ROOT/tests/fixtures/ci-mixed.txt"
out_ci_mixed="$(_render_ci)"
assert_contains "$out_ci_mixed" 'CI · ✓ 3 · ✗ 1 · ⏳ 2' 'mixed CI rollup rendered'

FAKE_GH_CI="$ROOT/tests/fixtures/ci-green.txt"
out_ci_green="$(_render_ci)"
assert_contains "$out_ci_green" 'CI · ✓ all green (6)' 'all-green CI rendered'

unset FAKE_GH_CI
out_ci_none="$(_render_ci)"
assert_empty "$out_ci_none" 'missing CI returns empty string'

rm -f "$ROOT/tests/helpers/gh"
PATH="$PATH_BAK"
```

- [ ] **Step 3: Run tests to verify they fail**

```bash
cd /Users/eranelbaz/projects/grove
bash tests/run.sh
```

Expected: failures with "_render_ci: command not found".

- [ ] **Step 4: Implement `_render_ci`**

In `/Users/eranelbaz/projects/grove/grove`, immediately after the closing `}` of `_render_pr`, insert:

```bash
_render_ci() {
  command -v gh >/dev/null 2>&1 || return 0
  local out
  out="$(gh pr view --json statusCheckRollup --jq '
    [.statusCheckRollup[]? | (.conclusion // .status // "PENDING")] as $all |
    if ($all | length) == 0 then ""
    else
      ($all | map(select(. == "SUCCESS")) | length) as $pass |
      ($all | map(select(. == "FAILURE" or . == "CANCELLED" or . == "TIMED_OUT" or . == "ACTION_REQUIRED")) | length) as $fail |
      ($all | map(select(. != "SUCCESS" and . != "FAILURE" and . != "CANCELLED" and . != "TIMED_OUT" and . != "ACTION_REQUIRED")) | length) as $pend |
      if $fail == 0 and $pend == 0 then "CI · ✓ all green (\($pass))"
      else "CI · ✓ \($pass) · ✗ \($fail) · ⏳ \($pend)"
      end
    end' 2>/dev/null)" || return 0
  [ -n "$out" ] || return 0
  printf '\033[2m── \033[0m%s\033[2m ──\033[0m\n' "$out"
}
```

> Note on the fake-gh path: the fixture files already contain the *post-jq* string. The real `gh --jq` will produce the same shape from the live GitHub response. We verify shape compatibility in Task 8's manual smoke test.

- [ ] **Step 5: Run tests to verify they pass**

```bash
cd /Users/eranelbaz/projects/grove
bash tests/run.sh
```

Expected: 22 passed, 0 failed.

- [ ] **Step 6: Commit**

```bash
cd /Users/eranelbaz/projects/grove
git add grove tests/run.sh tests/fixtures/ci-mixed.txt tests/fixtures/ci-green.txt
git commit -m "feat: render CI check rollup via gh"
```

---

### Task 7: Wire helpers into `_cmd_diff_pane` with gh caching

**Files:**
- Modify: `/Users/eranelbaz/projects/grove/grove` (rewrite the `_cmd_diff_pane` loop)

**Interfaces:**
- Consumes: every helper from Tasks 2–6 (`_load_config`, `_render_commits`, `_render_age`, `_render_pr`, `_render_ci`), plus the existing `_render_diff_tree`.
- Produces: a `_cmd_diff_pane` that loads config once, caches `gh` outputs in shell variables, and refreshes them only every `GROVE_GH_REFRESH` seconds while the outer redraw runs every `GROVE_DIFF_REFRESH` seconds. All sections are gated on `GROVE_SHOW_*`.

This task changes the orchestration loop. Automated testing of the loop itself is impractical (it runs forever and depends on tmux). The Step 4 smoke test below is the deliverable check.

- [ ] **Step 1: Replace `_cmd_diff_pane`**

In `/Users/eranelbaz/projects/grove/grove`, locate the current `_cmd_diff_pane()` function:

```bash
_cmd_diff_pane() {
  set +e
  set +o pipefail
  trap 'exit 0' INT TERM
  while :; do
    clear
    local base
    base="$(tmux show-options -v @grove-base 2>/dev/null)"
    if [ -z "$base" ]; then
      printf 'no base set\n\nrun: grove base <branch>\n'
    elif ! git rev-parse --verify --quiet "$base" >/dev/null 2>&1; then
      printf '\033[31minvalid base: %s\033[0m\n\nrun: grove base <branch>\n' "$base"
    else
      printf '\033[2m── diff vs %s ── %s ──\033[0m\n\n' "$base" "$(date +%H:%M:%S)"
      _render_diff_tree "$base"
      printf '\n'
      git --no-pager diff --no-renames --shortstat "$base" 2>/dev/null
    fi
    sleep 2
  done
}
```

Replace it entirely with:

```bash
_cmd_diff_pane() {
  set +e
  set +o pipefail
  trap 'exit 0' INT TERM

  local repo
  repo="$(tmux show-options -v @grove-repo 2>/dev/null || printf '')"
  _load_config "$repo"

  local gh_pr_cache="" gh_ci_cache="" last_gh_ts=0

  while :; do
    local now base
    now="$(date +%s)"
    base="$(tmux show-options -v @grove-base 2>/dev/null)"

    if [ "$GROVE_SHOW_PR" = "1" ] || [ "$GROVE_SHOW_CI" = "1" ]; then
      if [ $((now - last_gh_ts)) -ge "$GROVE_GH_REFRESH" ]; then
        [ "$GROVE_SHOW_PR" = "1" ] && gh_pr_cache="$(_render_pr)"
        [ "$GROVE_SHOW_CI" = "1" ] && gh_ci_cache="$(_render_ci)"
        last_gh_ts="$now"
      fi
    fi

    clear
    if [ -z "$base" ]; then
      printf 'no base set\n\nrun: grove base <branch>\n'
    elif ! git rev-parse --verify --quiet "$base" >/dev/null 2>&1; then
      printf '\033[31minvalid base: %s\033[0m\n\nrun: grove base <branch>\n' "$base"
    else
      printf '\033[2m── diff vs %s ── %s ──\033[0m\n\n' "$base" "$(date +%H:%M:%S)"
      _render_diff_tree "$base"
      printf '\n'
      git --no-pager diff --no-renames --shortstat "$base" 2>/dev/null

      if [ "$GROVE_SHOW_COMMITS" = "1" ]; then
        printf '\n'
        _render_commits "$base"
      fi
      if [ "$GROVE_SHOW_AGE" = "1" ]; then
        printf '\n'
        _render_age "$base"
      fi
      if [ -n "$gh_pr_cache" ]; then
        printf '\n%s' "$gh_pr_cache"
      fi
      if [ -n "$gh_ci_cache" ]; then
        printf '%s' "$gh_ci_cache"
      fi
    fi
    sleep "$GROVE_DIFF_REFRESH"
  done
}
```

- [ ] **Step 2: Confirm existing tests still pass**

```bash
cd /Users/eranelbaz/projects/grove
bash tests/run.sh
```

Expected: 22 passed, 0 failed (no regression in the helper-level tests).

- [ ] **Step 3: Smoke-test in a real grove session**

Make sure grove on `$PATH` points at this repo's copy:

```bash
which grove
# If it is not this repo's grove:
ln -sf /Users/eranelbaz/projects/grove/grove ~/.local/bin/grove
hash -r
```

Create a worktree to exercise the pane (choose any test branch name not already in use):

```bash
cd /Users/eranelbaz/projects/grove
grove create grove-pane-smoke main
```

You should now be inside a tmux session. Inside it:

```bash
echo demo > demo.txt
git add demo.txt
git commit -m "feat: demo for smoke test"
grove reset
```

The right-side pane should now show, top to bottom:

1. `── diff vs main ── HH:MM:SS ──`
2. (no file changes — clean state line, since you committed)
3. `── 1 ahead · 0 behind main ──` followed by the demo commit hash + subject
4. `── branched <X> ago · last commit <Y> ago ──`
5. If a PR exists for this branch on origin: `── PR #N · open · … ──`. Otherwise nothing.
6. If checks exist: `── CI · ✓ … ──`. Otherwise nothing.

Now verify the toggle and refresh-rate plumbing:

```bash
tmux kill-pane -t "$(tmux list-panes -F '#{pane_id} #{@grove-pane}' | awk '$2=="diff"{print $1; exit}')"
GROVE_SHOW_COMMITS=0 GROVE_GH_REFRESH=5 grove reset
```

The pane should respawn without the commits section, and `gh` (if applicable) should refresh on the 5-second cadence rather than 30.

Detach with `Ctrl-b d` (default tmux prefix). Tear down:

```bash
grove clean grove-pane-smoke -f
```

- [ ] **Step 4: Commit**

```bash
cd /Users/eranelbaz/projects/grove
git add grove
git commit -m "feat: wire commits/age/PR/CI sections into diff pane with caching"
```

---

### Task 8: Document configuration in the README

**Files:**
- Modify: `/Users/eranelbaz/projects/grove/README.md`

**Interfaces:**
- Consumes: nothing.
- Produces: a new "Configuration" section in the README listing every `GROVE_*` env var, the config-file locations, the precedence rule, and a short example of the new pane sections.

- [ ] **Step 1: Add a Configuration section**

In `/Users/eranelbaz/projects/grove/README.md`, find the section heading:

```markdown
## Per-repo hooks
```

Immediately **before** that heading, insert:

```markdown
## Configuration

The diff pane reads configuration from (highest precedence first):

1. Environment variables in the shell that spawned the grove session.
2. `~/.grove/<repo-name>/config` (per-repo).
3. `~/.grove/config` (global).
4. Built-in defaults.

Config files are bash scripts sourced by the pane. Use `: "${VAR:=value}"` so an env-var override in the shell still wins.

| Variable | Default | Meaning |
| --- | --- | --- |
| `GROVE_DIFF_REFRESH` | `2` | Seconds between pane redraws. |
| `GROVE_GH_REFRESH` | `30` | Seconds between `gh`-backed refreshes (PR + CI). |
| `GROVE_MAX_COMMITS` | `10` | Max commits listed under the ahead/behind line. |
| `GROVE_SHOW_COMMITS` | `1` | Show commits-on-branch + ahead/behind. `0` to hide. |
| `GROVE_SHOW_AGE` | `1` | Show branched / last-commit relative times. `0` to hide. |
| `GROVE_SHOW_PR` | `1` | Show GitHub PR status (requires `gh`). `0` to hide. |
| `GROVE_SHOW_CI` | `1` | Show GitHub CI check rollup (requires `gh`). `0` to hide. |

`grove init` scaffolds a `config` template alongside `setup.sh` and `teardown.sh` at `~/.grove/<repo-name>/config`.

Sections that depend on `gh` silently disappear when `gh` is not on `PATH` or the branch has no PR / no checks. Network calls are cached for `GROVE_GH_REFRESH` seconds so the 2-second outer redraw never floods the API.

Example pane:

```
── diff vs main ── 17:42:31 ──

src/
  M  cache.ts        +47 -12

1 file changed, 47 insertions(+), 12 deletions(-)

── 3 ahead · 0 behind main ──
a1b2c3d feat: add cache layer
b2c3d4e refactor: extract helper
c3d4e5f test: cover edge cases

── branched 4 hours ago · last commit 12 minutes ago ──

── PR #842 · open · approved ──

── CI · ✓ 4 · ✗ 0 · ⏳ 2 ──
```

```

- [ ] **Step 2: Verify the README renders cleanly**

```bash
cd /Users/eranelbaz/projects/grove
grep -n '^##' README.md
```

Expected: `## Configuration` appears between `## Commands` and `## Per-repo hooks`. Skim the section visually for any markdown breakage.

- [ ] **Step 3: Run tests once more for safety**

```bash
cd /Users/eranelbaz/projects/grove
bash tests/run.sh
```

Expected: 22 passed, 0 failed.

- [ ] **Step 4: Commit**

```bash
cd /Users/eranelbaz/projects/grove
git add README.md
git commit -m "docs: document diff-pane configuration and new sections"
```

---

## Done

After Task 8, the diff pane shows commits with ahead/behind, branch age, PR status, and CI rollup — each individually toggleable, with `gh` calls capped at one round per `GROVE_GH_REFRESH` seconds. Configuration is layered (env > per-repo > global > defaults) and `grove init` ships a working template.
