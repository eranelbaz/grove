#!/usr/bin/env bash
# grove init — scaffold setup.sh + teardown.sh hooks under $GROVE_HOME/<repo>/.

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
