#!/usr/bin/env bash
# ==============================================================================
# init-upstream.sh — Initialize the bare Git repository from the host repo
# ==============================================================================
# First run:  git clone --bare from host repo, ensure task directories exist
# Resume:     update bare repo to match host's current HEAD
set -euo pipefail

UPSTREAM_DIR="${UPSTREAM_DIR:-/upstream}"
HOST_REPO="${HOST_REPO:-/host-repo}"
DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"

# ---------------------------------------------------------------------------
# Validate host repo
# ---------------------------------------------------------------------------
if [ ! -d "${HOST_REPO}/.git" ]; then
    echo "[init-upstream] ERROR: No git repo found at ${HOST_REPO}/.git"
    echo "[init-upstream] Mount your project root as /host-repo"
    exit 1
fi

HOST_HEAD=$(git -C "${HOST_REPO}" rev-parse HEAD 2>/dev/null || true)
if [ -z "${HOST_HEAD}" ]; then
    echo "[init-upstream] ERROR: Host repo has no commits"
    exit 1
fi

# Warn about uncommitted changes (non-fatal)
if ! git -C "${HOST_REPO}" diff --quiet 2>/dev/null || \
   ! git -C "${HOST_REPO}" diff --cached --quiet 2>/dev/null; then
    echo "[init-upstream] WARNING: Host repo has uncommitted changes (will not be included)"
fi

# ---------------------------------------------------------------------------
# Resume mode: bare repo already exists
# ---------------------------------------------------------------------------
if [ -f "${UPSTREAM_DIR}/HEAD" ] && git --git-dir="${UPSTREAM_DIR}" rev-parse HEAD >/dev/null 2>&1; then
    UPSTREAM_HEAD=$(git --git-dir="${UPSTREAM_DIR}" rev-parse "refs/heads/${DEFAULT_BRANCH}" 2>/dev/null || true)

    if [ "${HOST_HEAD}" = "${UPSTREAM_HEAD}" ]; then
        echo "[init-upstream] Bare repo already in sync with host (${HOST_HEAD:0:8}), skipping."
        exit 0
    fi

    echo "[init-upstream] Resume mode: comparing host (${HOST_HEAD:0:8}) vs upstream (${UPSTREAM_HEAD:0:8})..."

    # Check if host HEAD is an ancestor of upstream HEAD
    # i.e. agents added commits on top of host, but host hasn't diverged
    if [ -n "${UPSTREAM_HEAD}" ] && \
       git --git-dir="${UPSTREAM_DIR}" merge-base --is-ancestor "${HOST_HEAD}" "${UPSTREAM_HEAD}" 2>/dev/null; then
        AGENT_ONLY_COUNT=$(git --git-dir="${UPSTREAM_DIR}" rev-list --count "${HOST_HEAD}..${UPSTREAM_HEAD}" 2>/dev/null || echo "0")
        echo "[init-upstream] Host is ancestor of upstream — ${AGENT_ONLY_COUNT} agent commit(s) ahead."
        echo "[init-upstream] Keeping agent work, skipping update."
        exit 0
    fi

    # Host has diverged from upstream — need to force-update
    # Warn about agent commits that will be lost
    if [ -n "${UPSTREAM_HEAD}" ]; then
        AGENT_ONLY=$(git --git-dir="${UPSTREAM_DIR}" log --oneline "${HOST_HEAD}..${UPSTREAM_HEAD}" 2>/dev/null || true)
        if [ -n "${AGENT_ONLY}" ]; then
            echo "[init-upstream] WARNING: Host has diverged. The following agent commits will be OVERWRITTEN:"
            echo "${AGENT_ONLY}"
            echo "[init-upstream] Use sync-back.sh to merge them first if needed."
        fi
    fi

    git -C "${HOST_REPO}" push "${UPSTREAM_DIR}" "HEAD:refs/heads/${DEFAULT_BRANCH}" --force
    echo "[init-upstream] Bare repo updated to host HEAD (${HOST_HEAD:0:8})."
    exit 0
fi

# ---------------------------------------------------------------------------
# First run: clone host repo as bare
# ---------------------------------------------------------------------------
echo "[init-upstream] Cloning host repo as bare into ${UPSTREAM_DIR}..."
git clone --bare "${HOST_REPO}" "${UPSTREAM_DIR}"

echo "[init-upstream] Bare repo created from host (HEAD=${HOST_HEAD:0:8})."

# ---------------------------------------------------------------------------
# Ensure current_tasks/ and ideas/ directories exist
# ---------------------------------------------------------------------------
TMPDIR=$(mktemp -d)
trap 'rm -rf "${TMPDIR}"' EXIT

git clone "${UPSTREAM_DIR}" "${TMPDIR}/repo"
cd "${TMPDIR}/repo"

git config user.email "init@ai-agent-loop"
git config user.name "AI Agent Loop Init"

NEEDS_PUSH=0

if [ ! -d "current_tasks" ]; then
    mkdir -p current_tasks
    touch current_tasks/.keep
    git add current_tasks/.keep
    NEEDS_PUSH=1
fi

if [ ! -d "ideas" ]; then
    mkdir -p ideas
    touch ideas/.keep
    git add ideas/.keep
    NEEDS_PUSH=1
fi

if [ ! -d "knowledge" ]; then
    mkdir -p knowledge
    touch knowledge/.keep
    git add knowledge/.keep
    NEEDS_PUSH=1
fi

if [ "${NEEDS_PUSH}" -eq 1 ]; then
    git commit -m "chore: add task directories for agent coordination"
    git push origin "${DEFAULT_BRANCH}"
    echo "[init-upstream] Added current_tasks/ and ideas/ directories."
fi

echo "[init-upstream] Initialization complete."
