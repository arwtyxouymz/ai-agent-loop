#!/usr/bin/env bash
# ==============================================================================
# orchestrator.sh — Hybrid auto-scaler for AI Agent Loop
# ==============================================================================
# Runs on the host machine. Monitors the shared bare repo and scales agent
# containers based on 4 signals: maturity, build health, conflict rate, task supply.
#
# Usage: .ai-agent-loop/orchestrator.sh {run|stop|pause|resume}
# ==============================================================================
set -uo pipefail

# ---------------------------------------------------------------------------
# Path setup
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ---------------------------------------------------------------------------
# Load configuration from .env
# ---------------------------------------------------------------------------
if [ -f "${SCRIPT_DIR}/.env" ]; then
    set -a
    # shellcheck disable=SC1091
    source "${SCRIPT_DIR}/.env"
    set +a
fi

MAX_AGENTS="${MAX_AGENTS:-8}"
CHECK_INTERVAL="${CHECK_INTERVAL:-60}"
SCALE_INCREMENT="${SCALE_INCREMENT:-2}"
CONFLICT_THRESHOLD_HIGH="${CONFLICT_THRESHOLD_HIGH:-40}"
CONFLICT_THRESHOLD_LOW="${CONFLICT_THRESHOLD_LOW:-20}"
MATURITY_COMMIT_THRESHOLD="${MATURITY_COMMIT_THRESHOLD:-10}"
MIN_IDEAS_PER_AGENT="${MIN_IDEAS_PER_AGENT:-2}"
BUILD_CHECK_CMD="${BUILD_CHECK_CMD:-}"
SRC_GLOB="${SRC_GLOB:-}"
LOG_FILE="${SCRIPT_DIR}/orchestrator.log"

# Export host project dir for docker-compose.yml
export HOST_PROJECT_DIR="${HOST_PROJECT_DIR:-${PROJECT_ROOT}}"

# Detect default branch from host repo
if [ -z "${DEFAULT_BRANCH:-}" ]; then
    DEFAULT_BRANCH=$(git -C "${PROJECT_ROOT}" symbolic-ref --short HEAD 2>/dev/null || echo "main")
fi
export DEFAULT_BRANCH

# Dynamic compose project name from project directory name
if [ -z "${COMPOSE_PROJECT_NAME:-}" ]; then
    COMPOSE_PROJECT_NAME="$(basename "${PROJECT_ROOT}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]/-/g')-agents"
fi
export COMPOSE_PROJECT_NAME

VOLUME_NAME="${COMPOSE_PROJECT_NAME}_upstream-repo"

# ---------------------------------------------------------------------------
# Utility: cross-platform date (macOS / Linux)
# ---------------------------------------------------------------------------
epoch_seconds() {
    if date -j >/dev/null 2>&1; then
        # macOS
        date +%s
    else
        # Linux
        date +%s
    fi
}

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "${msg}" | tee -a "${LOG_FILE}"
}

# ---------------------------------------------------------------------------
# Inspector: clone/pull the bare repo into a temp directory for analysis
# ---------------------------------------------------------------------------
INSPECT_DIR=""

setup_inspector() {
    INSPECT_DIR=$(mktemp -d)
    trap 'rm -rf "${INSPECT_DIR}"' EXIT

    # Find the volume mount point
    local volume_path
    volume_path=$(docker volume inspect "${VOLUME_NAME}" --format '{{ .Mountpoint }}' 2>/dev/null)

    if [ -z "${volume_path}" ]; then
        log "ERROR: Docker volume ${VOLUME_NAME} not found. Is the upstream service running?"
        exit 1
    fi

    # Clone from the bare repo via a temporary Docker container
    docker run --rm \
        -v "${VOLUME_NAME}:/upstream:ro" \
        -v "${INSPECT_DIR}:/inspect" \
        alpine/git:latest \
        clone /upstream /inspect/repo 2>/dev/null

    if [ ! -d "${INSPECT_DIR}/repo/.git" ]; then
        log "ERROR: Failed to clone from upstream volume."
        exit 1
    fi
}

refresh_inspector() {
    docker run --rm \
        -v "${VOLUME_NAME}:/upstream:ro" \
        -v "${INSPECT_DIR}:/inspect" \
        alpine/git:latest \
        -C /inspect/repo pull --rebase origin "${DEFAULT_BRANCH}" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Signal 1: Codebase Maturity
# ---------------------------------------------------------------------------
check_maturity() {
    local commit_count
    commit_count=$(docker run --rm \
        -v "${INSPECT_DIR}:/inspect:ro" \
        alpine/git:latest \
        -C /inspect/repo rev-list --count HEAD 2>/dev/null || echo "0")

    if [ "${commit_count}" -ge "${MATURITY_COMMIT_THRESHOLD}" ]; then
        log "  Maturity: PASS (${commit_count} commits >= ${MATURITY_COMMIT_THRESHOLD})"
        return 0
    else
        log "  Maturity: HOLD (${commit_count} commits < ${MATURITY_COMMIT_THRESHOLD})"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Signal 2: Build Health
# ---------------------------------------------------------------------------
check_build_health() {
    if [ -z "${BUILD_CHECK_CMD}" ]; then
        log "  Build health: SKIP (no BUILD_CHECK_CMD configured)"
        return 0
    fi

    if docker run --rm \
        -v "${INSPECT_DIR}:/inspect" \
        -w /inspect/repo \
        node:20-slim \
        sh -c "${BUILD_CHECK_CMD}" 2>/dev/null; then
        log "  Build health: PASS"
        return 0
    else
        log "  Build health: FAIL"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Signal 3: Conflict Rate
# ---------------------------------------------------------------------------
check_conflict_rate() {
    # Analyze recent push attempts by looking at merge commits
    local total_commits merge_commits conflict_rate
    total_commits=$(docker run --rm \
        -v "${INSPECT_DIR}:/inspect:ro" \
        alpine/git:latest \
        -C /inspect/repo rev-list --count --since="1 hour ago" HEAD 2>/dev/null || echo "0")

    merge_commits=$(docker run --rm \
        -v "${INSPECT_DIR}:/inspect:ro" \
        alpine/git:latest \
        -C /inspect/repo rev-list --count --merges --since="1 hour ago" HEAD 2>/dev/null || echo "0")

    if [ "${total_commits}" -eq 0 ]; then
        conflict_rate=0
    else
        conflict_rate=$(( (merge_commits * 100) / total_commits ))
    fi

    if [ "${conflict_rate}" -gt "${CONFLICT_THRESHOLD_HIGH}" ]; then
        log "  Conflict rate: HIGH (${conflict_rate}% > ${CONFLICT_THRESHOLD_HIGH}%) — HOLD"
        return 1
    else
        log "  Conflict rate: OK (${conflict_rate}%)"
        return 0
    fi
}

# ---------------------------------------------------------------------------
# Signal 4: Task Supply → desired agent count
# ---------------------------------------------------------------------------
count_available_tasks() {
    local ideas_count tasks_count available

    ideas_count=$(docker run --rm \
        -v "${INSPECT_DIR}:/inspect:ro" \
        alpine:latest \
        sh -c 'find /inspect/repo/ideas -name "*.txt" -type f 2>/dev/null | wc -l' || echo "0")
    ideas_count=$(echo "${ideas_count}" | tr -d '[:space:]')

    tasks_count=$(docker run --rm \
        -v "${INSPECT_DIR}:/inspect:ro" \
        alpine:latest \
        sh -c 'find /inspect/repo/current_tasks -name "*.txt" -type f 2>/dev/null | wc -l' || echo "0")
    tasks_count=$(echo "${tasks_count}" | tr -d '[:space:]')

    available=$((ideas_count + tasks_count))
    log "  Tasks: ${tasks_count} active, ${ideas_count} ideas (${available} total)"
    echo "${available}"
}

# ---------------------------------------------------------------------------
# Scaling logic
# ---------------------------------------------------------------------------
get_current_agent_count() {
    docker compose -f "${SCRIPT_DIR}/docker-compose.yml" ps --format json 2>/dev/null \
        | jq -r 'select(.Service == "agent" and .State == "running")' \
        | jq -s 'length' || echo "0"
}

scale_agents() {
    local desired=$1
    local current
    current=$(get_current_agent_count)

    if [ "${desired}" -le "${current}" ]; then
        log "  Scale: no change needed (current=${current}, desired=${desired})"
        return
    fi

    # Cap increment per cycle
    local new_count=$((current + SCALE_INCREMENT))
    [ "${new_count}" -gt "${desired}" ] && new_count="${desired}"
    [ "${new_count}" -gt "${MAX_AGENTS}" ] && new_count="${MAX_AGENTS}"

    if [ "${new_count}" -gt "${current}" ]; then
        log "  Scale: ${current} -> ${new_count} agents"
        docker compose -f "${SCRIPT_DIR}/docker-compose.yml" \
            up -d --scale "agent=${new_count}" --no-recreate 2>&1 | tee -a "${LOG_FILE}"
    else
        log "  Scale: at maximum (current=${current}, max=${MAX_AGENTS})"
    fi
}

# ---------------------------------------------------------------------------
# Graceful stop / pause / resume
# ---------------------------------------------------------------------------
stop_all_agents() {
    log "Stopping all agents gracefully..."
    docker compose -f "${SCRIPT_DIR}/docker-compose.yml" ps --format json 2>/dev/null \
        | jq -r 'select(.Service == "agent" and .State == "running") | .Name' \
        | while read -r name; do
            log "  Stopping ${name}..."
            docker stop -t 300 "${name}" &
        done
    wait
    log "All agents stopped."
}

pause_all_agents() {
    log "Pausing all agents..."
    docker compose -f "${SCRIPT_DIR}/docker-compose.yml" ps --format json 2>/dev/null \
        | jq -r 'select(.Service == "agent" and .State == "running") | .Name' \
        | while read -r name; do
            docker exec "${name}" touch /workspace/.pause 2>/dev/null || true
        done
}

resume_all_agents() {
    log "Resuming all agents..."
    docker compose -f "${SCRIPT_DIR}/docker-compose.yml" ps --format json 2>/dev/null \
        | jq -r 'select(.Service == "agent" and .State == "running") | .Name' \
        | while read -r name; do
            docker exec "${name}" rm -f /workspace/.pause 2>/dev/null || true
        done
}

# ===========================================================================
# Main loop
# ===========================================================================
main() {
    case "${1:-}" in
        stop)   stop_all_agents; exit 0 ;;
        pause)  pause_all_agents; exit 0 ;;
        resume) resume_all_agents; exit 0 ;;
        ""|run) ;;
        *)
            echo "Usage: $0 {run|stop|pause|resume}"
            exit 1 ;;
    esac

    log "========================================="
    log "Orchestrator starting (project=$(basename "${PROJECT_ROOT}"), max=${MAX_AGENTS}, interval=${CHECK_INTERVAL}s)"
    log "========================================="

    setup_inspector

    trap 'log "Orchestrator SIGTERM"; stop_all_agents; rm -rf "${INSPECT_DIR}"; exit 0' SIGTERM INT

    while true; do
        log "--- Check cycle ---"

        refresh_inspector

        # Signal 1: Maturity
        if ! check_maturity; then
            log "  Decision: HOLD (codebase not mature)"
            sleep "${CHECK_INTERVAL}"
            continue
        fi

        # Signal 2: Build health
        if ! check_build_health; then
            log "  Decision: HOLD (build unhealthy)"
            sleep "${CHECK_INTERVAL}"
            continue
        fi

        # Signal 3: Conflict rate
        if ! check_conflict_rate; then
            log "  Decision: HOLD (conflict rate too high)"
            sleep "${CHECK_INTERVAL}"
            continue
        fi

        # Signal 4: Task supply -> desired count
        available_tasks=$(count_available_tasks)
        if [ "${available_tasks}" -gt 0 ]; then
            desired=$(( (available_tasks / MIN_IDEAS_PER_AGENT) + 1 ))
            [ "${desired}" -gt "${MAX_AGENTS}" ] && desired="${MAX_AGENTS}"
            log "  Desired agents: ${desired}"
            scale_agents "${desired}"
        else
            log "  No tasks available, maintaining current scale."
        fi

        sleep "${CHECK_INTERVAL}"
    done
}

main "$@"
