# Task 1 Brief: Install the `grove` script

Your full task text lives in the implementation plan. Read it once:

**Plan file:** `/Users/eranelbaz/projects/grove/docs/superpowers/plans/2026-06-19-grove-cli-setup.md`

**Your scope:** the entire section starting at the heading `### Task 1: Install the \`grove\` script` through the `---` separator before Task 2. Steps 1–5.

## Environment facts already verified by the controller — do not re-check

- `~/.local/bin` exists.
- `~/.local/bin/grove` does NOT yet exist (so there is no overwrite-confirm prompt to handle — proceed straight to writing the file).
- Shell is zsh; rc files: `~/.zshrc` and `~/.bashrc` exist. (Relevant for Task 2, not Task 1.)
- `tmux` (`/opt/homebrew/bin/tmux`) and `git` (`/usr/bin/git`) are installed.

## Exact deliverable

After Step 5 you should have:

- `~/.local/bin/grove` present, **byte-for-byte identical** to the bash block embedded in the plan's Task 1 Step 2. **Do not** reflow, "improve," strip the unicode characters (`▸`, `—`, `●`), or add a trailing modification. The script's `usage()` function depends on the header comment block being intact, so the comments are load-bearing — keep them.
- File mode `-rwxr-xr-x` (executable).
- `bash -n ~/.local/bin/grove` exits 0 (no output expected; print `OK` after).
- `~/.local/bin/grove help` prints the usage block starting `grove — git worktree + tmux session orchestrator`.

## Reporting

Write your full report to: `/Users/eranelbaz/projects/grove/docs/superpowers/plans/task-1-report.md`

It must include:
1. The exact command/tool you used to write the file (e.g. `Write tool to /Users/eranelbaz/.local/bin/grove`).
2. The output of `wc -l ~/.local/bin/grove` (line count — should be around 200).
3. The output of `ls -la ~/.local/bin/grove` (verify the `-rwxr-xr-x` mode).
4. The output of `bash -n ~/.local/bin/grove && echo OK` (must be `OK`).
5. The first 5 lines and last 5 lines of `~/.local/bin/grove` (so the reviewer can confirm the header and trailing `main "$@"` line are intact without re-reading the whole file).
6. The output of `~/.local/bin/grove help` (the usage block).
7. Any deviations from the plan, or `None`.

## Special note on the "TDD" wording in the plan

There is no failing-test phase here — the deliverable is a single static file. Step 4 (`bash -n`) is the test; Step 5 (`grove help`) is the smoke-test. Don't try to invent a failing test first; that would be over-engineering for a transcription task.

## Reporting status

Status options per the implementer contract:

- **DONE** — file written, `bash -n` passes, `grove help` prints usage.
- **DONE_WITH_CONCERNS** — completed but noticed something (e.g. plan-text typo).
- **NEEDS_CONTEXT** — something in the plan is ambiguous; describe what.
- **BLOCKED** — cannot complete; describe why.

No git commit. The file lives in `$HOME`, not any repo. Do **not** run `git add` / `git commit`.
