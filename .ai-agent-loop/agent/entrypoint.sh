#!/usr/bin/env bash
# ==============================================================================
# entrypoint.sh — Agent infinite loop (the heartbeat)
# ==============================================================================
# Each container runs this loop: pull -> think (Claude) -> push -> sleep
set -uo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
AGENT_ID="${HOSTNAME}"
AGENT_MODEL="${CLAUDE_MODEL:-claude-opus-4-6}"
AGENT_SLEEP="${AGENT_SLEEP:-5}"
MAX_CONSECUTIVE_FAILURES="${MAX_CONSECUTIVE_FAILURES:-5}"
UPSTREAM_DIR="${UPSTREAM_DIR:-/upstream}"
DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"
REPO_DIR="/workspace/repo"

export AGENT_ID AGENT_MODEL

# ---------------------------------------------------------------------------
# Graceful shutdown support
# ---------------------------------------------------------------------------
STOP_FILE="/workspace/.stop"
PAUSE_FILE="/workspace/.pause"
SHUTDOWN_REQUESTED=0

handle_sigterm() {
    echo "[${AGENT_ID}] SIGTERM received — will exit after current iteration"
    SHUTDOWN_REQUESTED=1
}
trap handle_sigterm SIGTERM SIGINT

# ---------------------------------------------------------------------------
# Onboarding skip for headless/container environments
# ---------------------------------------------------------------------------
if [ ! -f "${HOME}/.claude.json" ]; then
    echo '{"hasCompletedOnboarding": true}' > "${HOME}/.claude.json"
fi

echo "[${AGENT_ID}] Agent starting (model=${AGENT_MODEL})"

# ---------------------------------------------------------------------------
# Git identity — unique per container
# ---------------------------------------------------------------------------
git config --global user.email "${AGENT_ID}@ai-agent-loop"
git config --global user.name "Claude Agent (${AGENT_ID})"
git config --global --add safe.directory "${UPSTREAM_DIR}"
git config --global --add safe.directory "${REPO_DIR}"

# ---------------------------------------------------------------------------
# Initial clone
# ---------------------------------------------------------------------------
if [ ! -d "${REPO_DIR}/.git" ]; then
    echo "[${AGENT_ID}] Cloning from ${UPSTREAM_DIR}..."
    git clone "${UPSTREAM_DIR}" "${REPO_DIR}"
fi

cd "${REPO_DIR}"

# ---------------------------------------------------------------------------
# push_with_retry — push with pull-retry loop
# ---------------------------------------------------------------------------
push_with_retry() {
    local max_retries=5
    local attempt=0

    while [ $attempt -lt $max_retries ]; do
        if git push origin "${DEFAULT_BRANCH}" 2>&1; then
            return 0
        fi
        attempt=$((attempt + 1))
        echo "[${AGENT_ID}] Push failed (attempt ${attempt}/${max_retries}), pulling and retrying..."

        # Try rebase first, fall back to merge
        if ! git pull --rebase origin "${DEFAULT_BRANCH}" 2>&1; then
            echo "[${AGENT_ID}] Rebase failed, trying merge..."
            git rebase --abort 2>/dev/null || true
            git pull --no-rebase origin "${DEFAULT_BRANCH}" 2>&1 || true
        fi
        sleep 1
    done

    echo "[${AGENT_ID}] Push failed after ${max_retries} attempts"
    return 1
}

# ---------------------------------------------------------------------------
# Stale lock cleanup on startup
# ---------------------------------------------------------------------------
if ls current_tasks/*.txt 1>/dev/null 2>&1; then
    own_locks=$(grep -rl "Claimed by: ${AGENT_ID}" current_tasks/*.txt 2>/dev/null || true)
    if [ -n "${own_locks}" ]; then
        echo "[${AGENT_ID}] Clearing own stale locks..."
        echo "${own_locks}" | xargs git rm -f 2>/dev/null || true
        if ! git diff --cached --quiet; then
            git commit -m "chore: clear stale locks for ${AGENT_ID}"
            push_with_retry || true
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------
consecutive_failures=0

while true; do
    # --- Shutdown check ---
    if [ "${SHUTDOWN_REQUESTED}" -eq 1 ] || [ -f "${STOP_FILE}" ]; then
        echo "[${AGENT_ID}] Stop signal detected, pushing uncommitted work..."
        if ! git diff --quiet || ! git diff --cached --quiet \
           || [ -n "$(git ls-files --others --exclude-standard)" ]; then
            git add -A
            git commit -m "agent(${AGENT_ID}): WIP before shutdown" || true
            push_with_retry || true
        fi
        # Release own locks
        if ls current_tasks/*.txt 1>/dev/null 2>&1; then
            own_locks=$(grep -rl "Claimed by: ${AGENT_ID}" current_tasks/*.txt 2>/dev/null || true)
            if [ -n "${own_locks}" ]; then
                echo "${own_locks}" | xargs git rm -f 2>/dev/null || true
                if ! git diff --cached --quiet; then
                    git commit -m "chore: release locks on ${AGENT_ID} shutdown"
                    push_with_retry || true
                fi
            fi
        fi
        echo "[${AGENT_ID}] Graceful shutdown complete."
        exit 0
    fi

    # --- Pause check ---
    if [ -f "${PAUSE_FILE}" ]; then
        echo "[${AGENT_ID}] Paused. Waiting..."
        sleep "${AGENT_SLEEP}" &
        wait $! 2>/dev/null || true
        continue
    fi

    loop_start=$(date +%s)

    echo "[${AGENT_ID}] === Loop iteration start ==="

    # Pull latest changes
    echo "[${AGENT_ID}] Pulling latest..."
    if ! git pull --rebase origin "${DEFAULT_BRANCH}" 2>&1; then
        echo "[${AGENT_ID}] Rebase pull failed, trying merge..."
        git rebase --abort 2>/dev/null || true
        git pull --no-rebase origin "${DEFAULT_BRANCH}" 2>&1 || true
    fi

    # Render the prompt template
    prompt_file="/config/AGENT_PROMPT.md"
    if [ -f "${prompt_file}" ]; then
        rendered_prompt=$(envsubst '${AGENT_ID} ${AGENT_MODEL}' < "${prompt_file}")
    else
        rendered_prompt="You are agent ${AGENT_ID}. Check current_tasks/ and ideas/ for work. Read CLAUDE.md for project context."
    fi

    # Run Claude
    echo "[${AGENT_ID}] Running Claude..."
    if claude -p "${rendered_prompt}" \
        --dangerously-skip-permissions \
        --model "${AGENT_MODEL}"; then

        consecutive_failures=0

        # Push any changes Claude made
        if ! git diff --quiet || ! git diff --cached --quiet || [ -n "$(git ls-files --others --exclude-standard)" ]; then
            echo "[${AGENT_ID}] Changes detected, pushing..."
            git add -A
            git commit -m "agent(${AGENT_ID}): automated changes" --allow-empty-message 2>&1 || true
            push_with_retry 2>&1 || true
        else
            echo "[${AGENT_ID}] No changes to push."
        fi
    else
        consecutive_failures=$((consecutive_failures + 1))
        echo "[${AGENT_ID}] Claude failed (consecutive: ${consecutive_failures})"

        # Exponential backoff on consecutive failures
        if [ $consecutive_failures -ge $MAX_CONSECUTIVE_FAILURES ]; then
            backoff=$((consecutive_failures * 60))
            [ $backoff -gt 300 ] && backoff=300
            echo "[${AGENT_ID}] Backing off for ${backoff}s..."
            sleep $backoff &
            wait $! 2>/dev/null || true
        fi
    fi

    # Sleep before next iteration
    loop_end=$(date +%s)
    elapsed=$((loop_end - loop_start))
    echo "[${AGENT_ID}] Loop took ${elapsed}s, sleeping ${AGENT_SLEEP}s..."
    sleep "${AGENT_SLEEP}" &
    wait $! 2>/dev/null || true
done
