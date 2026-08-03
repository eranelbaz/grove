# Attach by index — design

## Goal

Let `grove list` show a numeric index as its first column (starting at `0`), and
let `grove attach` accept that index via an explicit flag so you don't have to
retype a branch name.

```
$ grove list
0  ● live  feat-a   .../.worktrees/feat-a
1    ----  feat-b   .../.worktrees/feat-b
2  ● live  feat-c   .../.worktrees/feat-c

$ grove attach -i 2      # or --index 2  → attaches feat-c
```

## Decisions

- **Stateless recompute.** No snapshot / state file. `attach -i N` re-derives the
  same ordering `list` prints and selects the Nth row. Correct as long as the set
  of worktrees/sessions is unchanged between the two commands — an acceptable and
  self-evident constraint.
- **Both list modes.** Works inside a repo (repo-local list) and outside any repo
  (global list, grouped by repo). Index attach outside a repo is the only path
  where `attach` does not require a repo.
- **Explicit flag only.** `-i N` / `--index N`. A bare integer is *not* treated as
  an index, so branch names are never shadowed. No ambiguity.
- **Left-aligned index column.**

## Correctness keystone: shared ordering helpers

Because the index is recomputed rather than stored, `list` and `attach` MUST
iterate in identical order. Extract each ordering into one helper that both call:

- `_repo_worktree_paths()` — `git worktree list --porcelain | awk '/^worktree /{print $2}'`.
  This is exactly the iteration `_list_repo` already uses; extracting it makes the
  shared source explicit.
- `_global_session_rows()` — the existing `_list_global` pipeline:
  `tmux list-sessions -F '#{session_name}|#{@grove-repo}|#{@grove-branch}|#{@grove-worktree}'
  | awk -F'|' '$2 != ""' | sort -t'|' -k2,2 -k3,3`.

`_list_repo`, `_list_global`, and the index resolver all consume these helpers, so
the Nth row cannot differ between what you saw and what gets attached.

## Component changes

### `lib/commands/list.sh`

- Add `_repo_worktree_paths` and `_global_session_rows` helpers (move the inline
  pipelines into them; call sites use them).
- `_list_repo`: prepend a left-aligned index (`0`,`1`,…) as the first column.
  Width = digits of the largest index. Index tracks the `paths` array order.
- `_list_global`: prepend a **continuous** left-aligned counter that increments
  across every row of every repo group (so it matches the flat index space used by
  `attach -i`). Group headers remain unindexed.

### `lib/commands/attach.sh`

- Parse `-i <n>` / `--index <n>` from args. A missing value, a non-numeric value,
  or an out-of-range index → `die` with a clear message.
- When an index is given:
  - **Inside a repo:** map `N` → `_repo_worktree_paths` Nth path → its branch, then
    run the existing attach flow unchanged (adds the worktree / starts the session
    if that branch's session isn't live — identical to attaching by name).
  - **Outside a repo:** map `N` → `_global_session_rows` Nth row → session name.
    That session is always live (global list only enumerates live sessions), so
    `require_tmux` then `attach "$session"` directly. No repo required.
- Without an index, behavior is unchanged (branch name / prefix via `resolve_branch`).

### Usage header (`grove` script comment)

- `grove attach <branch> | -i <index>` with a one-line note that `list`'s first
  column is the index consumed by `-i`.

## Out of scope (YAGNI)

- No state/snapshot files.
- No bare-integer shorthand.
- No changes to `create`, `clean`, `reset`, `base`, or `migrate`.
- No config/env knobs.

## Testing

Extend `tests/` to cover:
- `list` prints a `0`-based left-aligned index column (repo-local).
- `_repo_worktree_paths` order matches the printed index order.
- `attach -i <N>` inside a repo resolves to the same branch shown at row N.
- `attach -i <out-of-range>` and `attach -i <non-numeric>` fail with a clear error.
- Global: continuous index across repo groups; `attach -i N` outside a repo
  switches to the Nth live session.
