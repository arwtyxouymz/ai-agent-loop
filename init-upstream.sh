#!/usr/bin/env bash
# ==============================================================================
# init-upstream.sh — Initialize the bare Git repository used for agent sync
# ==============================================================================
# Idempotent: skips initialization if the repo already has commits.
set -euo pipefail

UPSTREAM_DIR="${UPSTREAM_DIR:-/upstream}"

# Check if already initialized (HEAD exists and has commits)
if [ -f "${UPSTREAM_DIR}/HEAD" ] && git --git-dir="${UPSTREAM_DIR}" rev-parse HEAD >/dev/null 2>&1; then
    echo "[init-upstream] Bare repo already initialized at ${UPSTREAM_DIR}, skipping."
    exit 0
fi

echo "[init-upstream] Initializing bare repo at ${UPSTREAM_DIR}..."
git init --bare "${UPSTREAM_DIR}"

# Create a temporary working directory to make the initial commit
TMPDIR=$(mktemp -d)
trap 'rm -rf "${TMPDIR}"' EXIT

git clone "${UPSTREAM_DIR}" "${TMPDIR}/repo"
cd "${TMPDIR}/repo"

git config user.email "init@ai-agent-loop"
git config user.name "AI Agent Loop Init"

# Seed directory structure
mkdir -p current_tasks ideas

# Create .keep files so directories are tracked
touch current_tasks/.keep
touch ideas/.keep

# Copy CLAUDE.md if mounted, otherwise create a minimal one
if [ -f /config/CLAUDE.md ]; then
    cp /config/CLAUDE.md ./CLAUDE.md
else
    cat > CLAUDE.md << 'SEED_EOF'
# Project Configuration
See the main CLAUDE.md for details on directory structure and workflow.
SEED_EOF
fi

# Create .gitignore
cat > .gitignore << 'GI_EOF'
.DS_Store
*.swp
*.swo
*~
GI_EOF

git add -A
git commit -m "chore: initial repo structure with task directories"
git push origin main

echo "[init-upstream] Bare repo initialized successfully."
