# grove

A small git-worktree + tmux orchestrator. One bash script, one config dir, no dependencies beyond `git` and `tmux`.

Each branch gets:

- Its own isolated worktree under `.worktrees/<branch>` (auto-excluded from git).
- Its own persistent tmux session named `<repo>-<branch>` — survives closing your laptop.
- A small right-side pane that shows the changed files vs your base branch as a tree, refreshed every 2s. Untracked, modified, added, and deleted files all appear with status badges (`?`, `M`, `A`, `D`).

## Install

```bash
mkdir -p ~/.local/bin
curl -fsSL https://raw.githubusercontent.com/eranelbaz/grove/main/grove -o ~/.local/bin/grove
chmod +x ~/.local/bin/grove
# make sure ~/.local/bin is on PATH (e.g. add to ~/.zshrc):
#   export PATH="$HOME/.local/bin:$PATH"
```

Requires `bash` 3.2+, `git` 2.5+, and `tmux`.

## Commands

```
grove create <branch> [from-branch]   New branch + worktree + tmux session.
                                      from-branch defaults to the current branch
                                      and becomes the session's diff-pane base.
grove attach <branch>                 Worktree + session for an existing branch
                                      (or reattach if the session is live).
grove list                            In a repo: its worktrees + which are live.
                                      Outside any repo: a tree of every running
                                      grove session grouped by repo.
grove clean <branch> [-f]             Run teardown hook → kill session → remove
                                      worktree → offer to delete the branch.
grove base [<branch>]                 Show or set the diff-pane base for the
                                      current session.
grove reset [<branch>]                Kill and respawn the right-side diff pane.
                                      With a branch arg: target that session.
                                      Custom panes you added are left alone.
grove init                            Scaffold setup.sh / teardown.sh hooks for
                                      the current repo.
grove migrate <branch> [-f]           Relocate <branch>'s worktree into
                                      .worktrees/<branch>. -f allows dirty trees.
grove migrate <branch> --adopt        Adopt the existing path without moving.
grove migrate --all [-f]              Sweep every out-of-place worktree in the repo.
grove help
```

## Per-repo hooks

`grove init` scaffolds two scripts at `~/.grove/<repo-name>/`:

- `setup.sh` — runs once after `grove create` (or first `grove attach`), inside the new worktree. Use it to copy gitignored files, install deps, pick a unique dev port, etc.
- `teardown.sh` — runs during `grove clean`, before the session is killed and the worktree is removed. Use it to stop containers, drop scratch databases, free ports.

Both run with `CWD = the worktree` and these env vars exported:

```
GROVE_WORKTREE  GROVE_BRANCH  GROVE_FROM  GROVE_REPO_ROOT  GROVE_REPO_NAME
```

The scaffolded templates ship with commented-out examples — fill in whatever ritual your old "new clone" script did.

## License

MIT — see [LICENSE](LICENSE).
