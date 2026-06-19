# Grove CLI Setup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Install the `grove` CLI (a git-worktree + tmux orchestrator, replacement for `superset.sh`) on the user's machine, ensure it's on PATH, verify dependencies, scaffold per-repo hooks for the active repo, and confirm the install works end-to-end.

**Architecture:** Single bash script at `~/.local/bin/grove`. Per-repo hooks live at `~/.grove/<repo-name>/setup.sh` and `teardown.sh` and are invoked with CWD set to the worktree. Tmux sessions are named `<repo>-<branch>` (with `./: ` flattened to `-`). Worktrees live at `<repo-root>/.worktrees/<branch>` and are excluded via `.git/info/exclude` (not the tracked `.gitignore`).

**Tech Stack:** bash 3.2+ (macOS default), `git` (>= 2.5 for worktrees), `tmux`, zsh login shell.

## Global Constraints

- Script file content must match the user's pasted block **verbatim**, byte-for-byte. Do not rewrite, reflow, or "improve" it.
- Shell is **zsh** (confirmed: `$SHELL=/bin/zsh`, `~/.zshrc` exists, `~/.bashrc` exists but is not the login rc). Any PATH edit goes into `~/.zshrc`.
- `~/.local/bin` is **already on PATH** (confirmed at plan time). Do not append a duplicate `export PATH=...` line.
- `tmux` (`/opt/homebrew/bin/tmux`) and `git` (`/usr/bin/git`) are **already installed**. No `brew install` should run.
- `~/.local/bin/grove` does **not** currently exist — no overwrite-confirm prompt is needed.
- Current working directory `/Users/eranelbaz/projects/grove` is **not** a git repository. `grove init` (Task 3) must be run from a real git repo; if no repo is available, ask the user which one to init against before proceeding.
- Do **not** fill in project-specific commands inside the generated `setup.sh` / `teardown.sh` templates. Leave the commented-out examples exactly as written by `grove init`.
- Do **not** commit anything. This setup touches files outside any repo (`~/.local/bin`, `~/.grove/...`), and the cwd isn't a repo anyway.

---

## File Structure

| Path | Role | Action |
|---|---|---|
| `~/.local/bin/grove` | The CLI itself — single bash script, all commands dispatched from `main()` | **Create** |
| `~/.grove/<repo-name>/setup.sh` | Per-repo setup hook, run with CWD = new worktree | **Create** (via `grove init`) |
| `~/.grove/<repo-name>/teardown.sh` | Per-repo teardown hook, run during `grove clean` | **Create** (via `grove init`) |
| `~/.zshrc` | Login shell rc | **No change** (PATH already includes `~/.local/bin`) |

---

### Task 1: Install the `grove` script

**Files:**
- Create: `/Users/eranelbaz/.local/bin/grove`

**Interfaces:**
- Consumes: nothing
- Produces: an executable `grove` command exposing subcommands `create | attach | list | clean | init | help` (and aliases `new | open | ls | rm`). Reads `$GROVE_HOME` (default `~/.grove`). Honors `$TMUX` to switch-client when already inside tmux.

- [ ] **Step 1: Confirm `~/.local/bin` exists and `grove` is not already there**

Run:
```bash
ls -ld ~/.local/bin && ls -la ~/.local/bin/grove 2>&1
```
Expected: directory listing for `~/.local/bin`, then `ls: /Users/eranelbaz/.local/bin/grove: No such file or directory`. If `grove` **does** exist, stop and show a diff against the script body below, then ask the user before overwriting.

- [ ] **Step 2: Write the script verbatim**

Write the following content to `/Users/eranelbaz/.local/bin/grove`. **Do not modify any line.** This is the source of truth:

```bash
#!/usr/bin/env bash
#
# grove — git worktree + tmux session orchestrator (a tiny superset.sh replacement)
#
# Each branch gets its own isolated worktree under ./.worktrees/<branch> and its
# own persistent tmux session. Closing your laptop won't kill running agents;
# windows ("tabs") are yours to add inside the session.
#
# Usage:
#   grove create <branch> [from-branch]  New branch + worktree + tmux session.
#                                        from-branch defaults to the current branch.
#   grove attach <branch>                Worktree + session for a branch that already
#                                        exists (or reattach if the session is live).
#   grove list                           List worktrees and which have a live session.
#   grove clean <branch> [-f]            Run teardown, kill session, remove worktree,
#                                        offer to delete the branch.
#   grove init                           Scaffold setup.sh + teardown.sh hooks for this repo.
#   grove help
#
# Per-repo hooks (replace your old setup script):
#   $GROVE_HOME/<repo-name>/setup.sh      runs on create/attach, inside the new worktree
#   $GROVE_HOME/<repo-name>/teardown.sh   runs on clean, inside the worktree before removal
#   (default GROVE_HOME=~/.grove)
#   Both run with CWD = the worktree and these vars:
#     GROVE_WORKTREE  GROVE_BRANCH  GROVE_FROM  GROVE_REPO_ROOT  GROVE_REPO_NAME
#
set -euo pipefail

GROVE_HOME="${GROVE_HOME:-$HOME/.grove}"

die()  { printf 'grove: %s\n' "$*" >&2; exit 1; }
info() { printf '\033[36m▸\033[0m %s\n' "$*" >&2; }

require_repo() {
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || die "not inside a git repository"
}

# The MAIN working tree, even if grove is invoked from inside a worktree.
main_root() { git worktree list --porcelain | awk '/^worktree /{print $2; exit}'; }

# tmux session names cannot contain . or : — also flatten / and spaces.
sanitize() { printf '%s' "$1" | tr './: ' '----'; }
session_name() { printf '%s-%s' "$(sanitize "$1")" "$(sanitize "$2")"; }
_session_for() { session_name "$(basename "$(main_root)")" "$1"; }

attach() {
  local session="$1"
  if [ -n "${TMUX:-}" ]; then tmux switch-client -t "$session"
  else tmux attach-session -t "$session"; fi
}

# Keep ./.worktrees out of git's sight without touching the tracked .gitignore.
ensure_excluded() {
  local root="$1" exclude="$root/.git/info/exclude"
  if [ -f "$exclude" ] && ! grep -qxF '.worktrees/' "$exclude"; then
    printf '.worktrees/\n' >> "$exclude"
    info "added '.worktrees/' to .git/info/exclude"
  fi
}

# Run a per-repo hook (setup.sh/teardown.sh) inside the worktree, if it exists.
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

_start_session() {
  local branch="$1" wt="$2" session
  session="$(_session_for "$branch")"
  if tmux has-session -t "$session" 2>/dev/null; then
    info "attaching existing session: $session"; attach "$session"; return
  fi
  info "starting session: $session"
  tmux new-session -d -s "$session" -c "$wt"
  attach "$session"
}

cmd_create() {
  [ $# -ge 1 ] || die "usage: grove create <branch> [from-branch]"
  command -v tmux >/dev/null 2>&1 || die "tmux is not installed"
  require_repo
  local branch="$1" from="${2:-}"
  local root wt
  root="$(main_root)"; wt="$root/.worktrees/$branch"

  git show-ref --verify --quiet "refs/heads/$branch" \
    && die "branch '$branch' already exists — use: grove attach $branch"

  if [ ! -d "$wt" ]; then
    ensure_excluded "$root"
    local base="${from:-$(git rev-parse --abbrev-ref HEAD)}"
    info "new branch '$branch' from '$base'"
    git worktree add -b "$branch" "$wt" "$base"
    _run_hook setup.sh "$branch" "$wt" "$from"
  fi
  _start_session "$branch" "$wt"
}

cmd_attach() {
  [ $# -ge 1 ] || die "usage: grove attach <branch>"
  command -v tmux >/dev/null 2>&1 || die "tmux is not installed"
  require_repo
  local branch="$1"
  local root wt session
  root="$(main_root)"; wt="$root/.worktrees/$branch"
  session="$(_session_for "$branch")"

  if tmux has-session -t "$session" 2>/dev/null; then
    info "attaching existing session: $session"; attach "$session"; return
  fi
  git show-ref --verify --quiet "refs/heads/$branch" \
    || die "no branch '$branch' — use: grove create $branch [from-branch]"

  if [ ! -d "$wt" ]; then
    ensure_excluded "$root"
    info "worktree for existing branch '$branch'"
    git worktree add "$wt" "$branch"
    _run_hook setup.sh "$branch" "$wt" ""
  fi
  _start_session "$branch" "$wt"
}

cmd_list() {
  require_repo
  local repo; repo="$(basename "$(main_root)")"
  git worktree list --porcelain | awk '/^worktree /{print $2}' | while read -r path; do
    branch="$(git -C "$path" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
    session="$(session_name "$repo" "$branch")"
    if tmux has-session -t "$session" 2>/dev/null; then live='\033[32m● live\033[0m'; else live='  ----'; fi
    printf "$live  %-24s  %s\n" "$branch" "$path"
  done
}

cmd_clean() {
  [ $# -ge 1 ] || die "usage: grove clean <branch> [-f]"
  require_repo
  local branch="$1" force=""
  case "${2:-}" in -f|--force) force="--force" ;; esac
  local root wt session
  root="$(main_root)"; wt="$root/.worktrees/$branch"
  session="$(_session_for "$branch")"

  [ -d "$wt" ] && _run_hook teardown.sh "$branch" "$wt" ""
  tmux kill-session -t "$session" 2>/dev/null && info "killed session $session" || true

  if [ -d "$wt" ]; then
    if git worktree remove $force "$wt" 2>/dev/null; then
      info "removed worktree $wt"
    else
      die "worktree has uncommitted changes — re-run with -f to force, or commit/stash first"
    fi
  fi
  git worktree prune

  if [ -t 0 ] && git show-ref --verify --quiet "refs/heads/$branch"; then
    read -r -p "delete branch '$branch'? [y/N] " ans
    case "$ans" in
      y|Y) git branch -D "$branch" && info "deleted branch $branch" ;;
      *)   info "kept branch $branch" ;;
    esac
  fi
}

cmd_init() {
  require_repo
  local repo dir
  repo="$(basename "$(main_root)")"; dir="$GROVE_HOME/$repo"
  mkdir -p "$dir"

  if [ -e "$dir/setup.sh" ]; then
    info "already exists: $dir/setup.sh"
  else
    cat > "$dir/setup.sh" <<'EOF'
#!/usr/bin/env bash
# grove setup hook — runs once, inside a freshly created worktree (CWD = the worktree).
# Move whatever your old setup script did into here: copy env files, install deps, etc.
#
# Available env vars:
#   GROVE_WORKTREE  GROVE_BRANCH  GROVE_FROM  GROVE_REPO_ROOT  GROVE_REPO_NAME
set -euo pipefail

# --- bring over gitignored files the worktree didn't inherit ---
# cp "$GROVE_REPO_ROOT/.env" .env 2>/dev/null || true
# cp "$GROVE_REPO_ROOT/.env.local" .env.local 2>/dev/null || true

# --- install dependencies ---
# npm install
# pnpm install
# uv sync

# --- give this worktree its own dev port (avoids collisions) ---
# echo "PORT=$((3000 + RANDOM % 1000))" >> .env.local
EOF
    chmod +x "$dir/setup.sh"; info "created $dir/setup.sh"
  fi

  if [ -e "$dir/teardown.sh" ]; then
    info "already exists: $dir/teardown.sh"
  else
    cat > "$dir/teardown.sh" <<'EOF'
#!/usr/bin/env bash
# grove teardown hook — runs during `grove clean`, inside the worktree (CWD = worktree),
# before the tmux session is killed and the worktree is removed.
# Release anything setup.sh created: stop containers, drop a scratch DB, free ports.
#
# Available env vars:
#   GROVE_WORKTREE  GROVE_BRANCH  GROVE_FROM  GROVE_REPO_ROOT  GROVE_REPO_NAME
set -euo pipefail

# docker compose down 2>/dev/null || true
# dropdb "myapp_${GROVE_BRANCH//\//_}" 2>/dev/null || true
EOF
    chmod +x "$dir/teardown.sh"; info "created $dir/teardown.sh"
  fi
  printf '%s\n' "$dir"
}

usage() { sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; }

main() {
  local cmd="${1:-help}"
  case "$cmd" in
    create|new)     shift; cmd_create "$@" ;;
    attach|open)    shift; cmd_attach "$@" ;;
    list|ls)        shift; cmd_list "$@" ;;
    clean|rm)       shift; cmd_clean "$@" ;;
    init)           shift; cmd_init "$@" ;;
    help|-h|--help) usage ;;
    *)              die "unknown command '$cmd' — try: grove help" ;;
  esac
}

main "$@"
```

- [ ] **Step 3: Make the script executable**

Run:
```bash
chmod +x ~/.local/bin/grove
```
Expected: no output, exit code 0.

- [ ] **Step 4: Syntax-check the script (the "test")**

Run:
```bash
bash -n ~/.local/bin/grove && echo OK
```
Expected: `OK`. Any syntax error means Step 2 didn't write the file verbatim — re-write it.

- [ ] **Step 5: Smoke-test `grove help`**

Run (use the absolute path so this works even before a shell reload):
```bash
~/.local/bin/grove help
```
Expected: usage text starting with `grove — git worktree + tmux session orchestrator` and listing the `create / attach / list / clean / init / help` subcommands.

---

### Task 2: Verify PATH and dependencies

**Files:**
- Modify (conditional, almost certainly skipped): `~/.zshrc`

**Interfaces:**
- Consumes: the `grove` binary from Task 1.
- Produces: confirmation that the user can invoke `grove` by bare name in a fresh shell, and that the binaries `grove` depends on (`tmux`, `git`) are present.

- [ ] **Step 1: Confirm shell and rc-file**

Run:
```bash
echo "$SHELL"; ls ~/.zshrc ~/.bashrc ~/.bash_profile ~/.config/fish/config.fish 2>&1
```
Expected: `/bin/zsh` and `~/.zshrc` present. (Confirmed at plan time.) The active rc file is **`~/.zshrc`**. Do not touch `~/.bashrc` — it's not the login rc.

- [ ] **Step 2: Confirm `~/.local/bin` is already on PATH**

Run:
```bash
echo "$PATH" | tr ':' '\n' | grep -Fx "$HOME/.local/bin" && echo ALREADY_ON_PATH || echo NEEDS_APPEND
```
Expected: `ALREADY_ON_PATH` (confirmed at plan time). Tell the user: "`~/.local/bin` is already on PATH — no rc changes needed."

- [ ] **Step 3 (conditional, only if Step 2 printed `NEEDS_APPEND`): Append to `~/.zshrc`**

Append this single line to `~/.zshrc`:
```bash
export PATH="$HOME/.local/bin:$PATH"
```
Then tell the user to run `source ~/.zshrc` (or open a new terminal). For the current Bash-tool session, calling grove as `~/.local/bin/grove` works regardless.

- [ ] **Step 4: Confirm `tmux` and `git` are installed**

Run:
```bash
command -v tmux git
```
Expected (confirmed at plan time):
```
/opt/homebrew/bin/tmux
/usr/bin/git
```
If `tmux` is missing, stop the plan and tell the user: `brew install tmux`. Do not proceed to Task 3 until tmux is on PATH.

---

### Task 3: Scaffold per-repo hooks via `grove init`

**Files:**
- Create (via `grove init`): `~/.grove/<repo-name>/setup.sh`
- Create (via `grove init`): `~/.grove/<repo-name>/teardown.sh`

**Interfaces:**
- Consumes: `grove` binary from Task 1; presence of a real git repo as cwd.
- Produces: two executable shell scripts at `~/.grove/<repo-name>/`. Leave their bodies as the commented-out templates generated by `cmd_init`.

- [ ] **Step 1: Find a git repo to init against**

Run:
```bash
git -C "$PWD" rev-parse --show-toplevel 2>&1
```
Current cwd (`/Users/eranelbaz/projects/grove`) is **not** a git repo — this will print `fatal: not a git repository`. Stop and ask the user: "Which existing repo should I run `grove init` from?" Wait for an answer before continuing. Do not invent a path. Do not `git init` anything.

- [ ] **Step 2: Run `grove init` from the chosen repo**

Once the user names a repo (call its absolute path `$REPO`):
```bash
( cd "$REPO" && ~/.local/bin/grove init )
```
Expected output:
```
▸ created /Users/eranelbaz/.grove/<repo-name>/setup.sh
▸ created /Users/eranelbaz/.grove/<repo-name>/teardown.sh
/Users/eranelbaz/.grove/<repo-name>
```
(If the hook files already exist, `grove init` prints `▸ already exists: …` instead — that's fine, leave them alone.)

- [ ] **Step 3: Print both hook paths**

Run:
```bash
ls -la ~/.grove/<repo-name>/setup.sh ~/.grove/<repo-name>/teardown.sh
```
Substitute the real `<repo-name>` from Step 2's output. Expected: both files exist, executable (`-rwxr-xr-x`).

- [ ] **Step 4: Show the contents of both hooks to the user**

Read each file and display its full contents to the user. Both should match the heredoc templates embedded in `cmd_init` (commented examples for `cp .env`, `npm install`, `docker compose down`, etc.). **Do not edit them.** Tell the user: "These are commented-out examples. Move your existing setup script's commands into `setup.sh`, and matching cleanup into `teardown.sh`. They run with `CWD = the worktree` and have `$GROVE_WORKTREE / $GROVE_BRANCH / $GROVE_FROM / $GROVE_REPO_ROOT / $GROVE_REPO_NAME` available."

---

### Task 4: Final verification and cheat sheet

**Files:** none modified

**Interfaces:**
- Consumes: everything from Tasks 1–3.
- Produces: a final report to the user confirming the install works.

- [ ] **Step 1: Re-run the syntax check**

Run:
```bash
bash -n ~/.local/bin/grove && echo SYNTAX_OK
```
Expected: `SYNTAX_OK`.

- [ ] **Step 2: Run `grove help` one more time**

Run:
```bash
~/.local/bin/grove help
```
Expected: the full usage block (same as Task 1 Step 5). If, by Task 4, the shell has reloaded, bare `grove help` should also work — try it as a bonus but don't fail the task if PATH hasn't refreshed in the Bash-tool environment (each Bash call is a fresh shell sourcing the rc, so PATH should in fact include `~/.local/bin` from the existing line).

- [ ] **Step 3: Print the 4-line cheat sheet to the user**

Output exactly this, no more:
```
grove create <branch> [from]   # new branch + worktree + tmux session
grove attach <branch>          # reattach (or create worktree for an existing branch)
grove list                     # show worktrees and which sessions are live
grove clean <branch> [-f]      # teardown hook → kill session → remove worktree
```

- [ ] **Step 4: Report what was done**

Single message to the user. Include:
- Where the script was installed (`~/.local/bin/grove`)
- That PATH already contained `~/.local/bin` (so no rc edit was made)
- That tmux + git were already present
- Which repo was used for `grove init` and the two hook paths it created
- The 4-line cheat sheet from Step 3

Do **not** commit anything (cwd isn't a repo; the script lives in `$HOME`).
