---
phase: 02
plan: 02
subsystem: deployment-automation
tags:
  - rollback
  - logs
  - scripts
  - operations
dependency_graph:
  requires: []
  provides:
    - scripts/rollback.sh
    - scripts/logs.sh
  affects: []
tech_stack:
  added:
    - bash
  patterns:
    - SSH heredoc for remote execution
    - Slot state file pattern (/var/run/blue-green-state)
    - Nginx symlink switching
key_files:
  created:
    - scripts/rollback.sh
    - scripts/logs.sh
decisions: []
metrics:
  duration_seconds: 68
  completed_date: "2026-04-01T05:26:00Z"
  tasks_completed: 2
  files_created: 2
requirements:
  - BG-10
  - BG-13
  - BG-14
---

# Phase 02 Plan 02 Summary: Rollback and Log Scripts

## Objective

Create rollback.sh for instant rollback to the previous slot (no container rebuild), and logs.sh for accessing container and Nginx logs. These complete the Phase 2 requirements: BG-10 (rollback), BG-13 (container log access), BG-14 (Nginx log monitoring).

## One-Liner

Two bash scripts for zero-downtime rollback and log retrieval via SSH: rollback.sh flips the Nginx symlink to the inactive slot in one command, logs.sh streams container and Nginx logs with line limits and follow mode.

## Tasks Completed

### Task 1: Create scripts/rollback.sh

**Commit:** 5fd3480

Created scripts/rollback.sh that reads the active slot from /var/run/blue-green-state, computes the rollback target (blue->green or green->blue), and executes the Nginx switch via SSH heredoc.

**Key behavior:**
- Reads active slot: `cat /var/run/blue-green-state 2>/dev/null || echo blue`
- Computes rollback target: `[[ "$active_slot" == "blue" ]] && rollback_slot="green" || rollback_slot="blue"`
- Switches symlink: `ln -sf /etc/nginx/sites-available/blue-green-${rollback_slot}.conf /etc/nginx/sites-enabled/blue-green`
- Validates config: `sudo nginx -t`
- Reloads Nginx: `sudo nginx -s reload`
- Updates state file after successful reload
- Confirms both slots remain running (no docker compose down)
- SSH key and host via environment variable overrides

### Task 2: Create scripts/logs.sh

**Commit:** cda71a2

Created scripts/logs.sh that retrieves container logs and Nginx logs via SSH with flexible targeting and follow mode.

**Key behavior:**
- Targets: `blue`, `green`, `nginx`, `all` (default: `all`)
- Line limit: `--lines/-n` (default: 100 for containers, 50 for Nginx)
- Follow mode: `-f/--follow` for real-time streaming
- Container logs: `docker compose -f /opt/<slot>/docker-compose.yml logs --tail=$lines`
- Nginx logs: `sudo tail -n $lines /var/log/nginx/access.log` and `error.log`
- Help text with usage examples

## Deviation from Plan

None - plan executed exactly as written.

## Acceptance Criteria Status

| Criterion | Status |
|---|---|
| rollback.sh flips Nginx from active slot to the other slot in one command | PASS |
| rollback.sh updates /var/run/blue-green-state after successful switch | PASS |
| rollback.sh leaves all containers running (no docker compose down) | PASS |
| logs.sh retrieves container logs from blue, green, or both | PASS |
| logs.sh retrieves Nginx access.log and error.log | PASS |
| logs.sh supports --lines N and --follow/-f flags | PASS |
| All scripts accept SSH_KEY and HOST as env var overrides | PASS |
| Both scripts are executable | PASS |

## Overall Verification

```
scripts/rollback.sh scripts/logs.sh  -- files exist
set -euo pipefail                       -- safe mode set in both
13.236.205.122                          -- SSH host set in both
ec2-static-site-key                     -- SSH key set in both
/var/run/blue-green-state (rollback.sh) -- state file read/write
/var/log/nginx (logs.sh)               -- nginx logs read
+x scripts/rollback.sh                  -- executable
+x scripts/logs.sh                      -- executable
```

## Self-Check: PASSED

- C:\Users\fiefi\blue-green-deployment\scripts\rollback.sh: FOUND
- C:\Users\fiefi\blue-green-deployment\scripts\logs.sh: FOUND
- Commit 5fd3480: FOUND (rollback.sh)
- Commit cda71a2: FOUND (logs.sh)
