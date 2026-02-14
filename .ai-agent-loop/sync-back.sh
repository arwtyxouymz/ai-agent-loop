#!/usr/bin/env bash
# ==============================================================================
# sync-back.sh — Pull agent work back into the host repo
# ==============================================================================
# Modes:
#   --log-only  (default) Show agent commits not yet in host. Read-only.
#   --merge     Merge agent work into host with a merge commit.
#   --rebase    Rebase host onto agent work for clean history.
#
# Usage: .ai-agent-loop/sync-back.sh [--log-only|--merge|--rebase]
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Load .env if present
if [ -f "${SCRIPT_DIR}/.env" ]; then
    set -a
    # shellcheck disable=SC1091
    source "${SCRIPT_DIR}/.env"
    set +a
fi

# Detect default branch
if [ -z "${DEFAULT_BRANCH:-}" ]; then
    DEFAULT_BRANCH=$(git -C "${PROJECT_ROOT}" symbolic-ref --short HEAD 2>/dev/null || echo "main")
fi

# Dynamic compose project name (must match orchestrator.sh)
if [ -z "${COMPOSE_PROJECT_NAME:-}" ]; then
    COMPOSE_PROJECT_NAME="$(basename "${PROJECT_ROOT}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]/-/g')-agents"
fi

VOLUME_NAME="${COMPOSE_PROJECT_NAME}_upstream-repo"
MODE="${1:---log-only}"
REMOTE_NAME="agent-upstream"

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
if [ "${MODE}" != "--log-only" ] && [ "${MODE}" != "--merge" ] && [ "${MODE}" != "--rebase" ]; then
    echo "Usage: $0 [--log-only|--merge|--rebase]"
    echo ""
    echo "Modes:"
    echo "  --log-only  (default) Show agent commits not in host. Safe, read-only."
    echo "  --merge     Merge agent work into host with a merge commit."
    echo "  --rebase    Rebase host onto agent work for clean history."
    exit 1
fi

# Check host repo is clean (for merge/rebase modes)
if [ "${MODE}" != "--log-only" ]; then
    if ! git -C "${PROJECT_ROOT}" diff --quiet 2>/dev/null || \
       ! git -C "${PROJECT_ROOT}" diff --cached --quiet 2>/dev/null; then
        echo "ERROR: Host repo has uncommitted changes. Commit or stash them first."
        exit 1
    fi
fi

# Check Docker volume exists
if ! docker volume inspect "${VOLUME_NAME}" >/dev/null 2>&1; then
    echo "ERROR: Docker volume ${VOLUME_NAME} not found."
    echo "Have agents been started at least once?"
    exit 1
fi

# ---------------------------------------------------------------------------
# Clone from Docker volume to a temp dir, then add as remote
# ---------------------------------------------------------------------------
TMPDIR=$(mktemp -d)
trap 'rm -rf "${TMPDIR}"; git -C "${PROJECT_ROOT}" remote remove "${REMOTE_NAME}" 2>/dev/null || true' EXIT

echo "Cloning agent bare repo from Docker volume..."
docker run --rm \
    -v "${VOLUME_NAME}:/upstream:ro" \
    -v "${TMPDIR}:/clone" \
    alpine/git:latest \
    clone --bare /upstream /clone/repo 2>/dev/null

if [ ! -f "${TMPDIR}/repo/HEAD" ]; then
    echo "ERROR: Failed to clone from Docker volume."
    exit 1
fi

# Add as temporary remote
cd "${PROJECT_ROOT}"
git remote remove "${REMOTE_NAME}" 2>/dev/null || true
git remote add "${REMOTE_NAME}" "${TMPDIR}/repo"
git fetch "${REMOTE_NAME}" 2>/dev/null

# ---------------------------------------------------------------------------
# Determine what agents have done
# ---------------------------------------------------------------------------
HOST_HEAD=$(git rev-parse HEAD)
AGENT_HEAD=$(git rev-parse "${REMOTE_NAME}/${DEFAULT_BRANCH}" 2>/dev/null || true)

if [ -z "${AGENT_HEAD}" ]; then
    echo "ERROR: Could not find ${DEFAULT_BRANCH} branch in agent repo."
    exit 1
fi

if [ "${HOST_HEAD}" = "${AGENT_HEAD}" ]; then
    echo "Agent repo is identical to host. Nothing to sync."
    exit 0
fi

# Count agent-only commits
AGENT_ONLY_COUNT=$(git rev-list --count "${HOST_HEAD}..${AGENT_HEAD}" 2>/dev/null || echo "0")

if [ "${AGENT_ONLY_COUNT}" -eq 0 ]; then
    echo "No new agent commits to sync (host is ahead or identical)."
    exit 0
fi

echo ""
echo "Found ${AGENT_ONLY_COUNT} agent commit(s) not in host:"
echo "---"
git log --oneline "${HOST_HEAD}..${AGENT_HEAD}"
echo "---"
echo ""

# ---------------------------------------------------------------------------
# Execute mode
# ---------------------------------------------------------------------------
case "${MODE}" in
    --log-only)
        echo "Run with --merge or --rebase to incorporate these changes."
        ;;
    --merge)
        echo "Merging agent work into host..."
        git merge "${REMOTE_NAME}/${DEFAULT_BRANCH}" \
            -m "chore: merge agent work into host (${AGENT_ONLY_COUNT} commits)"
        echo "Merge complete. Review with: git log --oneline --graph -20"
        ;;
    --rebase)
        echo "Rebasing host onto agent work..."
        git rebase "${REMOTE_NAME}/${DEFAULT_BRANCH}"
        echo "Rebase complete. Review with: git log --oneline -20"
        ;;
esac
