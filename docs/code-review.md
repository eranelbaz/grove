# Code review — `grove`

Scope: the single `grove` bash script at repo root (~640 lines). Focus: code reuse, readability, bash conventions, latent bugs. Recommendations are written so they can be applied later without re-reading the whole file.

---

## 1. Bugs / correctness

### 1.1 Duplicated variable assignment in `cmd_clean` (lines 363-367)
```bash
local root wt session
root="$(main_root)"; wt="$root/.worktrees/$branch"
session="$(_session_for "$branch")"
root="$(main_root)"; wt="$root/.worktrees/$branch"   # ← repeated
session="$(_session_for "$branch")"                  # ← repeated
```
Lines 366-367 are an exact duplicate of 364-365. Delete them. Likely a bad merge / model artifact.

### 1.2 `root` declared/computed twice in `cmd_clean` (lines 356-364)
The earlier guard already does `root="$(main_root)"` (line 357) before the second `local root wt session` block. Re-declaring `local root` later shadows nothing here (same function scope), so it works, but it's noise. Compute `root` and `wt` once at the top of the function, reuse below.

### 1.3 `info` used for errors (lines 351, 359)
```bash
info "Error: Branch '$branch' does not exist. ..." >&2
die "Usage: grove clean <existing-branch> [-f]"
```
Two problems:
- `info` already writes to stderr (line 52 — `>&2` at the end of the `printf`). The extra `>&2` is a no-op.
- Using `info` for an error message that's immediately followed by `die` produces two stderr lines per failure. `die` already prefixes `grove: `; just fold the message into the `die` call:
  ```bash
  die "branch '$branch' does not exist — run 'grove list' to see tracked branches"
  ```

### 1.4 Capitalization drift in error messages (lines 351, 352, 359, 360)
Rest of the file uses lowercase, terse messages: `"no branch '...'"`, `"tmux is not installed"`, `"branch '...' already exists"`. `cmd_clean` introduces `"Error: ..."` and `"Usage: ..."`. Match the existing style — lowercase, no `Error:` prefix (the `grove:` prefix from `die` does that job).

### 1.5 `cmd_clean` hook + remove sequence is fragile (lines 369-377)
```bash
[ -d "$wt" ] && _run_hook teardown.sh "$branch" "$wt" ""
tmux kill-session -t "$session" 2>/dev/null && info "killed session $session" || true
if [ -d "$wt" ]; then
  git worktree remove $force "$wt" 2>/dev/null || true
  info "cleaned up worktree $wt (if it existed)"
fi
git worktree prune
```
- `$force` is unquoted on purpose (it's `""` or `"--force"`), but a comment or `${force:-}` would make that explicit and quiet shellcheck.
- `2>/dev/null || true` swallows the *reason* `git worktree remove` failed — common case is a dirty tree, which the user needs to know about. Either let it fail loudly, or print the captured stderr.
- The `"(if it existed)"` parenthetical reads like an apology; just say `"removed worktree $wt"` or print nothing on failure.

### 1.6 `cmd_clean` confirms branch deletion even when worktree removal failed (lines 379-385)
If `git worktree remove` silently fails (dirty tree), the worktree still exists but we proceed to ask "delete branch?". Saying yes then leaves the branch gone and a stale checkout dangling. Either:
- only offer to delete the branch if the worktree was actually removed, OR
- explicitly check `git worktree list` again before the prompt.

### 1.7 `_render_branch_status` divides by zero / `arith on empty` risk (lines 495-498, also _render_recent_commits 503)
```bash
ahead="$(git rev-list --count "$base"..HEAD 2>/dev/null || echo 0)"
```
If `$base` is empty (which `_pane_loop` does pass through — see 2.3), `git rev-list --count ..HEAD` becomes `git rev-list --count ..HEAD` — that *does* parse and gives count of HEAD's reachable history (not zero). The `2>/dev/null || echo 0` only catches errors; a successful command with garbage range returns a non-zero number. The callers (`_status_pane_render`, `_commits_pane_render`) guard with `[ -n "$base" ] && git rev-parse --verify`, so this is currently fine — but the helper itself trusts inputs it shouldn't. Add a guard inside the renderer or document the precondition.

### 1.8 `_spawn_diff_pane` (lines 140-154): silent failure on small terminals
Three nested splits at fixed sizes (`-p 30`, `-l 8`, `-l 4`). On a narrow terminal, the first split may fit but subsequent ones can fail. Every split has `|| true`, so a partial layout is produced with no warning. Either:
- attempt and warn (`tmux split-window … || info "diff pane skipped (terminal too small)"`), or
- check `tmux display -p '#{window_width}'` before splitting.

### 1.9 `usage()` (line 619) is brittle
```bash
awk 'NR==1 && /^#!/ {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"
```
Stops at the first non-comment line. Works today because the doc block runs uninterrupted from line 2 to line 45, with `set -euo pipefail` immediately after. If anyone ever adds a blank comment-less line inside the doc block (or moves `set -e` lower), `usage` truncates silently. Consider extracting help into a heredoc constant.

---

## 2. Code reuse / duplication

### 2.1 Repeated `command -v tmux >/dev/null 2>&1 || die "tmux is not installed"`
Appears at lines 158, 190, 322, 389, 415. Extract:
```bash
require_tmux() { command -v tmux >/dev/null 2>&1 || die "tmux is not installed"; }
```
Mirrors `require_repo`.

### 2.2 Repeated worktree path computation
Pattern `root="$(main_root)"; wt="$root/.worktrees/$branch"` appears 4× (lines 162, 182, 358, 364). Introduce:
```bash
_grove_worktree_path() { printf '%s/.worktrees/%s' "$(main_root)" "$1"; }
```

### 2.3 Three near-identical pane renderers
`_diff_pane_render`, `_status_pane_render`, `_commits_pane_render` (lines 535-559) all share:
- read `base` from caller (passed in)
- short-circuit if `base` is empty or invalid

`_status_pane_render` and `_commits_pane_render` are nearly identical:
```bash
_status_pane_render() {
  local base="$1"
  [ -n "$base" ] && git rev-parse --verify --quiet "$base" >/dev/null 2>&1 \
    && _render_branch_status "$base"
}
```
Collapse to one helper:
```bash
_render_if_valid_base() {
  local base="$1" renderer="$2"
  [ -n "$base" ] && git rev-parse --verify --quiet "$base" >/dev/null 2>&1 \
    && "$renderer" "$base"
}
```
Or inline the validity check inside `_pane_loop` once.

### 2.4 Three pane entry points are one-liners (lines 561-563)
```bash
_cmd_diff_pane()    { _pane_loop 2 _diff_pane_render; }
_cmd_status_pane()  { _pane_loop 5 _status_pane_render; }
_cmd_commits_pane() { _pane_loop 5 _commits_pane_render; }
```
These could be a single `_cmd_pane <kind>` dispatch driven by a small lookup table, removing three sub-commands from `main()` (lines 632-634).

### 2.5 Argument-parsing styles diverge across commands
- `cmd_clean` uses `case "${2:-}" in -f|--force) force="--force" ;; esac` (one shot).
- `cmd_migrate` uses a `while [ $# -gt 0 ]` loop.
- `cmd_create` / `cmd_attach` do positional only.

Pick one pattern (the `while`/`case` loop is the most flexible) and standardize when subcommands accept flags.

### 2.6 `_session_for` / `session_name` / `sanitize` chain (lines 82-84)
Three functions for what's effectively one operation. Consider folding `sanitize` into `session_name` (it's only ever called from there).

### 2.7 Hook running could surface stderr cleanly
`_run_hook` (lines 102-114) runs the script in a subshell with `set -e` inherited. If a hook fails, the failure surfaces but the user sees the raw bash error, not a grove-prefixed line. Wrap with a clearer diagnostic.

---

## 3. Readability / structure

### 3.1 Split into files — recommendation
640 lines in one script is navigable, but the responsibilities are clearly separable. Suggested layout:

```
grove                          # entrypoint: arg dispatch + sourcing
lib/
  util.sh                      # die, info, sanitize, require_repo, require_tmux,
                               # main_root, _worktree_path_for, _default_base,
                               # ensure_excluded, _run_hook, _grove_worktree_path
  session.sh                   # session_name, _session_for, attach, _tag_session,
                               # _start_session, _spawn_diff_pane, _restart_session_at
  panes.sh                     # _render_diff_tree, _render_branch_status,
                               # _render_recent_commits, _pane_loop,
                               # *_pane_render, _cmd_*_pane
  commands/
    create.sh                  # cmd_create
    attach.sh                  # cmd_attach
    list.sh                    # cmd_list, _list_repo, _list_global
    clean.sh                   # cmd_clean
    base.sh                    # cmd_base
    reset.sh                   # cmd_reset
    init.sh                    # cmd_init
    migrate.sh                 # cmd_migrate
```

Tradeoff: grove is currently a single-file executable that can be `curl | bash`-installed or symlinked into `~/bin`. Splitting forces a "grove home" layout. Mitigation:
- the entrypoint sources via a path resolved from `$GROVE_BIN`'s directory: `source "$(dirname "$GROVE_BIN")/lib/util.sh"`.
- distribution becomes "clone the repo and symlink `grove`" rather than "copy one file." Acceptable given the project already lives as a repo.

Alternative if single-file install is sacred: keep one file but add section banners (`# ───── pane renderers ─────`) and reorder so callers precede callees consistently (currently mixed).

### 3.2 Function ordering is inconsistent
- Most helpers come before their callers (good).
- `_session_for` (line 84) is defined after `sanitize`/`session_name` but used inside `_start_session` (line 127) which is defined later — fine.
- `_render_diff_tree` (line 432) is far from `_diff_pane_render` (line 535) which uses it — readable today, but if you keep one file, group renderers with their consumers.

### 3.3 `_render_diff_tree`'s embedded awk is the hardest part of the file to read (lines 432-491)
Two awks piped together (collator + tree renderer) with no comments. Worth:
- naming the two stages (e.g., `_collate_diff_streams`, `_render_tree_from_collated`),
- moving each into its own function with a short docstring describing input format (`status\tadds\tdels\tpath`).

That alone would let a future reader edit one stage without re-deriving the data flow.

### 3.4 Magic numbers
- `30` (pane width %) at line 142
- `8`, `4` (pane line sizes) at lines 146, 149
- `2`, `5`, `5` (refresh intervals) at lines 561-563
- `max=5` (commit count) at line 502

Hoist to named constants at the top of `panes.sh` (or near the top of `grove`).

### 3.5 ANSI escapes scattered everywhere
`\033[36m`, `\033[31m`, etc. appear throughout. A tiny color helper / constant block would be a readability win:
```bash
C_CYAN=$'\033[36m'; C_RED=$'\033[31m'; C_GREEN=$'\033[32m'
C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'; C_DIM=$'\033[2m'; C_RESET=$'\033[0m'
```
Then `printf '%s▸%s %s\n' "$C_CYAN" "$C_RESET" "$*"`.

### 3.6 Help/usage drift
The doc-comment block (lines 9-45) lists usage; individual commands also `die "usage: …"`. These can diverge. Two options:
- generate the per-command usage from the doc block (overkill), or
- add a `cmd_help <subcommand>` that prints the matching slice of the doc, and have `die` calls reference it.

### 3.7 Naming
- `_diff_pane` / `_spawn_diff_pane` actually spawns three panes (diff + commits + status). Rename to `_spawn_grove_panes`.
- `_cmd_diff_pane` / `_cmd_status_pane` / `_cmd_commits_pane` are internal sub-commands prefixed with `_` — good. But they're routed in `main()` without the `_` prefix on the case label (`_diff-pane`, `_status-pane`, `_commits-pane`). Consistent — fine.
- `_default_base` returns the *fallback* base; the doc-comment says "best-effort default." OK.

---

## 4. Bash conventions

### 4.1 `set -euo pipefail` is on — good.
But several command substitutions use `|| true` / `2>/dev/null` to defuse it. Audit them: each should be justified (e.g., "tmux may not be running"). Most are reasonable. A few that look defensive without need:
- line 313: `git -C "$path" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?'` — if a worktree exists but HEAD can't be resolved, hiding it as `?` is OK.
- line 374: `git worktree remove ... 2>/dev/null || true` — see 1.5; this swallows the real error.

### 4.2 Quoting
Most variables are properly quoted. A few unquoted expansions worth checking:
- line 295: `git worktree move --force "$src" "$dst"` — fine.
- line 247: `cmd_migrate "$branch" $force_flag --no-session` — `$force_flag` is intentionally unquoted (it's `""` or `"-f"`). OK but document with a comment.
- line 374: `git worktree remove $force "$wt"` — same pattern. OK.

### 4.3 `local` declarations
The script consistently uses `local` (good). But `cmd_clean` (lines 357 and 363) declares `local root` twice in the same function — legal but redundant.

### 4.4 `read -r -p` (line 380) is bash-only — fine since shebang is `bash`.

### 4.5 `[ ... ]` vs `[[ ... ]]`
Script uses POSIX `[ ]` throughout — consistent. No `[[ ]]` mixed in.

### 4.6 Process substitution `< <(...)` used at line 250 — bash-only. Fine.

### 4.7 The trap in `_pane_loop` (line 518): `trap 'exit 0' INT TERM`
Good — clean exit when tmux kills the pane.

### 4.8 No shellcheck pragmas; no `# shellcheck disable=…` comments
Running shellcheck on this file will produce some noise (SC2086 on the intentional unquoted `$force`, SC2155 on some `local x="$(…)"`). Worth running shellcheck once and either fixing or annotating.

---

## 5. Tests

Only `tests/migrate.sh` exists. Worth adding:
- `tests/clean.sh` covering the duplicate-line regression (1.1) and the "remove failed but branch deleted" path (1.6),
- `tests/help.sh` to lock the `usage()` output so refactors don't silently truncate it.

---

## 6. Suggested fix order

When picking this up later:

1. **Quick wins** (line-level, ~30 min total):
   - Delete duplicate lines in `cmd_clean` (1.1).
   - Replace `info "Error: …" >&2 ; die "Usage: …"` pairs with one `die` (1.3, 1.4).
   - Extract `require_tmux` helper (2.1).
   - Hoist magic numbers to constants (3.4).

2. **Medium** (~1-2 hr):
   - Fix clean-then-prompt-delete sequencing (1.6).
   - Surface `git worktree remove` failures instead of swallowing them (1.5).
   - Collapse the three near-identical pane renderers (2.3, 2.4).
   - Unify flag parsing across commands (2.5).

3. **Larger refactor** (decide first):
   - Split into `lib/` files (3.1). Discuss whether single-file install is a constraint before doing this.
   - Refactor `_render_diff_tree`'s awk into named stages (3.3).
   - Add shellcheck to CI (4.8).

---

End of review.
