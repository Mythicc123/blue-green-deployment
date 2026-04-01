#!/usr/bin/env bash
# scripts/ec2-lock.sh — EC2-side deployment lock management
# Usage:
#   ./ec2-lock.sh acquire  # Acquire lock (blocks until available or timeout)
#   ./ec2-lock.sh release  # Release lock (only if held by current PID)
#   ./ec2-lock.sh status   # Check lock status (exit 0=free, exit 1=held, exit 2=stale)
#   ./ec2-lock.sh cleanup  # Remove stale locks (TTL expired)

set -euo pipefail

LOCKFILE="/tmp/blue-green-deploy.lock"
LOCK_TIMEOUT="${LOCK_TIMEOUT:-300}"   # 5 minutes — max wait for lock
LOCK_TTL="${LOCK_TTL:-600}"          # 10 minutes — stale after this
HOSTNAME=$(hostname)

CMD="${1:-}"
[[ -z "$CMD" ]] && { echo "Usage: $0 acquire|release|status|cleanup" >&2; exit 1; }

acquire() {
    local run_id="${GITHUB_RUN_ID:-local}"
    local run_url="${GITHUB_RUN_URL:--}"
    local ttl_at now
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    ttl_at=$(date -u -d "+${LOCK_TTL} seconds" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)

    # Atomic acquire using flock. -w TIMEOUT waits TIMEOUT seconds for the lock.
    (
        flock -w "$LOCK_TIMEOUT" 9 || {
            echo "ERROR: Could not acquire lock within ${LOCK_TIMEOUT}s" >&2
            echo "Lock held by:" >&2
            cat "$LOCKFILE" 2>/dev/null | grep -E '^(PID|GITHUB_RUN_ID|TTL_AT)=' >&2 || echo "  (lock file unreadable)" >&2
            exit 1
        }

        # Check if existing lock is stale before overwriting
        if [[ -f "$LOCKFILE" ]]; then
            local existing_ttl
            existing_ttl=$(grep '^TTL_AT=' "$LOCKFILE" | cut -d= -f2 || echo "")
            if [[ -n "$existing_ttl" && "$existing_ttl" > "$now" ]]; then
                echo "ERROR: Lock is actively held (TTL: ${existing_ttl})" >&2
                cat "$LOCKFILE" >&2
                exit 1
            fi
            # Lock is stale — safe to overwrite
        fi

        cat > "$LOCKFILE" <<LOCKEOF
LOCK_HELD=1
PID=$$
HOSTNAME=${HOSTNAME}
ACQUIRED_AT=${now}
GITHUB_RUN_ID=${run_id}
GITHUB_RUN_URL=${run_url}
TTL_AT=${ttl_at}
LOCKEOF
        echo "LOCK ACQUIRED: PID=$$ TTL_AT=${ttl_at}"
    ) 9>"$LOCKFILE"
}

release() {
    if [[ ! -f "$LOCKFILE" ]]; then
        echo "LOCK NOT HELD: no lock file"
        return 0
    fi

    local lock_pid
    lock_pid=$(grep '^PID=' "$LOCKFILE" | cut -d= -f2 || echo "")

    if [[ "$lock_pid" != "$$" ]]; then
        echo "WARNING: Lock held by PID $lock_pid, not $$ — not releasing" >&2
        return 1
    fi

    rm -f "$LOCKFILE"
    echo "LOCK RELEASED"
}

status() {
    if [[ ! -f "$LOCKFILE" ]]; then
        echo "LOCK STATUS: FREE"
        return 0
    fi

    local ttl_at now
    ttl_at=$(grep '^TTL_AT=' "$LOCKFILE" | cut -d= -f2 || echo "")
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    if [[ -n "$ttl_at" && "$ttl_at" < "$now" ]]; then
        echo "LOCK STATUS: STALE (TTL expired at ${ttl_at})"
        return 2   # Distinct exit code for stale
    fi

    echo "LOCK STATUS: HELD"
    grep -E '^(PID|HOSTNAME|ACQUIRED_AT|GITHUB_RUN_ID|TTL_AT)=' "$LOCKFILE"
    return 1
}

cleanup() {
    if [[ ! -f "$LOCKFILE" ]]; then
        echo "CLEANUP: no lock file"
        return 0
    fi

    local ttl_at now
    ttl_at=$(grep '^TTL_AT=' "$LOCKFILE" | cut -d= -f2 || echo "")
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    if [[ -n "$ttl_at" && "$ttl_at" < "$now" ]]; then
        echo "CLEANUP: removing stale lock (TTL expired at ${ttl_at})"
        rm -f "$LOCKFILE"
    else
        echo "CLEANUP: lock is not stale (TTL: ${ttl_at:-unknown}) — skipping"
    fi
}

case "$CMD" in
    acquire) acquire ;;
    release) release ;;
    status)  status ;;
    cleanup) cleanup ;;
    *) echo "Unknown command: $CMD" >&2; exit 1 ;;
esac
