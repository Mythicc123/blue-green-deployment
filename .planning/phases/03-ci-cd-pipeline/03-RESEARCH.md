# Phase 3: CI/CD Pipeline - Research

**Researched:** 2026-04-01
**Domain:** GitHub Actions concurrency control, EC2 deployment locking, SSH-based CI/CD secrets management, race condition handling between CI platform and remote host
**Confidence:** HIGH (GitHub Actions concurrency well-documented platform behavior); MEDIUM (EC2 locking patterns, cross-platform specifics)

---

## Summary

Phase 3 wraps the Phase 2 manual scripts into a GitHub Actions workflow that runs on push to main. The core challenge is concurrency control: preventing two simultaneous runs from deploying to the same inactive slot at the same time, and ensuring a cancelled run does not leave the EC2 in a corrupted state. The solution requires two independent locking mechanisms that cooperate: a GitHub Actions `concurrency:` block at the platform level, and an EC2-side lock file as a secondary guard and a record of what process holds the deployment slot.

The critical design insight is that GitHub Actions concurrency and the EC2 lock file serve different purposes. GitHub concurrency prevents multiple runs from starting on the same branch/ref. The EC2 lock file prevents a deployment from proceeding when another process (GitHub Actions, a human, a cron job) is already mid-deploy. Both are required because: (a) the EC2 lock file survives GitHub runner restarts (runners are ephemeral), and (b) the EC2 lock file is the only mechanism that can record who holds the lock and when it was acquired.

**Primary recommendation:** Use `concurrency: ${{ github.repository }}` with `cancel-in-progress: true`. This cancels any in-progress run when a new push arrives. On the EC2 side, use a TTL-bearing lock file at `/tmp/blue-green-deploy.lock` with flock(1) for atomic acquisition, a 10-minute TTL for staleness detection, and a hostname+PID+timestamp in the file content so stale locks are diagnosable.

---

## User Constraints (from STATE.md / Phase 2 Research)

### Locked Decisions

- SSH host: `ubuntu@13.236.205.122`
- SSH key: `$HOME/.ssh/ec2-static-site-key.pem`
- Docker image: `mythicc123/multi-container-service`
- Compose dirs: `/opt/blue/`, `/opt/green/`
- Blue port: 3001, green port: 3002
- Nginx config names: `blue-green-blue.conf`, `blue-green-green.conf`
- Symlink path: `/etc/nginx/sites-enabled/blue-green`
- State file: `/var/run/blue-green-state` contains `blue` or `green`
- Immutable image tags: git SHA-based, never `latest`
- Health endpoint: `localhost:<port>/health` returns `{"status":"ok","mongo":"connected"}`
- Shared MongoDB: `multi-container-service-mongo-1:27017`
- Existing scripts: `deploy.sh`, `health-check.sh`, `switch-nginx.sh`, `rollback.sh`, `run-deploy.sh`, `get-active-slot.sh`
- Smoke test: call GET/POST/PUT/DELETE API endpoints through the public IP after Nginx switch
- No automated rollback on failure; manual rollback via `rollback.sh`

### Phase 3 Requirements (from REQUIREMENTS.md)

| ID | Description | Research Support |
|----|-------------|------------------|
| BG-06 | Automated CI/CD pipeline on push — GitHub Actions `deploy.yml` triggers on push to main. Steps: determine active slot, deploy to inactive slot, health check, Nginx switch, smoke test | Workflow YAML structure, step ordering |
| BG-07 | Immutable Docker image tags — images tagged with git SHA (e.g., `sha-abc1234`), never `latest` | `GITHUB_SHA` env var, image tagging in build-push-action |
| BG-08 | Concurrency lock — GitHub Actions concurrency group prevents simultaneous deployments. Deployment lock file on EC2 (`/tmp/blue-green-deploy.lock`) as secondary protection | `concurrency:` YAML block, EC2 lock via flock(1) + TTL |
| BG-09 | Smoke test after switch — CI/CD calls Todo API endpoints (GET/POST/PUT/DELETE) through the public IP after Nginx switch | curl-based smoke test against public IP, Todo API endpoints |

---

## Standard Stack

### Core
| Tool | Version | Purpose | Why Standard |
|------|---------|---------|--------------|
| GitHub Actions | N/A (platform) | CI/CD orchestration | GitHub-native, triggers on push, first-class concurrency support |
| `GITHUB_SHA` | N/A (built-in env var) | Immutable Docker image tag | Unique per commit, reproducible, never ambiguous like `latest` |
| `appleboy/ssh-action` | v0.40.0 (2024-08) | Execute remote SSH commands on EC2 | De facto standard; handles key injection, timeout, `if: always()` steps |
| `docker/build-push-action` | v6 | Build and push Docker image | Industry standard; supports cache-from GHA, multi-tag |
| `docker/setup-buildx-action` | v3 | Docker buildx for multi-platform builds | Required for build-push-action if using GHA cache |
| `docker/login-action` | v3 | Authenticate to Docker Hub | Required for pushing to Docker Hub org repos |
| flock(1) | util-linux 2.38+ (Ubuntu 22.04) | Atomic lock acquisition on EC2 | Standard Linux tool; supersedes noclobber redirect |
| bash | 5.1+ (Ubuntu 22.04) | Lock script execution | Already used by all Phase 2 scripts |

### Supporting
| Tool | Purpose | When to Use |
|------|---------|-------------|
| `EC2_SSH_KEY` | Repository secret for SSH private key | Passed to `appleboy/ssh-action` inline key parameter |
| `EC2_HOST` | Repository secret for SSH target host | `13.236.205.122` as GitHub Actions secret |
| `mkdir`-based lock | Alternative to flock if flock unavailable | Simpler, equally atomic, no fd management |

---

## Architecture Patterns

### Recommended Project Structure

```
blue-green-deployment/
├── .github/
│   └── workflows/
│       └── deploy.yml          # Main CI/CD pipeline
├── scripts/
│   ├── deploy.sh               # Phase 2: docker pull + compose up on EC2
│   ├── health-check.sh         # Phase 2: polling health check
│   ├── switch-nginx.sh         # Phase 2: Nginx switch + state update
│   ├── rollback.sh              # Phase 2: rollback to previous slot
│   ├── run-deploy.sh            # Phase 2: orchestrator
│   ├── get-active-slot.sh       # Phase 2: read /var/run/blue-green-state
│   └── ec2-lock.sh             # NEW: EC2-side lock with TTL
└── compose/
    ├── blue/docker-compose.yml
    └── green/docker-compose.yml
```

**Key principle:** The GitHub Actions workflow uses `appleboy/ssh-action` to run the Phase 2 scripts (`run-deploy.sh`) as a single step, with environment variables injected. The `ec2-lock.sh` script is called inline within the SSH action to acquire and release the lock around the deploy.

---

## Research Question 1: GitHub Actions Concurrency Groups

### Recommended YAML Configuration

```yaml
# .github/workflows/deploy.yml
concurrency:
  group: ${{ github.repository }}
  cancel-in-progress: true
```

### Group Name: `${{ github.repository }}` vs Alternatives

| Group Name | Cancels same branch | Cancels cross-branch | Use Case |
|------------|--------------------|----------------------|----------|
| `${{ github.repository }}` | YES | YES | Single deploy target (one EC2). Any run cancels any other run. |
| `${{ github.workflow }}-${{ github.ref }}` | YES | NO | Multi-environment (prod + staging). This project has one target. |
| `${{ github.run_id }}` | NO | N/A | No concurrency control — not recommended. |
| Literal string `"blue-green-deploy"` | YES | YES | Works but hardcoded; repository-scoped is more idiomatic. |

**Recommendation:** `${{ github.repository }}` because there is one deployment target. Any push to any branch cancels any other in-progress run.

### `cancel-in-progress: true` vs Letting It Queue

| Setting | Behavior | Pros | Cons |
|---------|----------|------|------|
| `cancel-in-progress: true` | In-progress run cancelled when new run starts | Fresh code always deploys; no stale deploys queueing | Cancelled run may leave EC2 in intermediate state |
| `cancel-in-progress: false` (omitted) | New run waits for in-progress run to complete | Guaranteed no overlap; ordered queue | Slow to respond to rapid pushes; queues pile up |

**Recommendation: `cancel-in-progress: true`** with TTL-based EC2 lock cleanup.

### What Happens to an In-Progress Run When GitHub Concurrency Cancels It

When GitHub cancels an in-progress run (because a new push arrived):

1. GitHub sends a cancellation signal to the runner. The runner marks the job as `cancelled`.
2. **GitHub Actions does NOT run any `if:` cleanup steps or `finally:` blocks by default.** The job stops at whatever step it was on.
3. Any SSH commands already dispatched to EC2 will complete on the remote side (EC2 does not know the runner was cancelled).
4. The EC2-side effects depend on what step the run was in:
   - Before lock acquired: no EC2 state change
   - Lock acquired, mid-deploy: lock held until TTL expires (no harm done)
   - After Nginx switch: Nginx routes to new slot, state file updated, but old container still running — this is actually fine (Phase 2 architecture keeps both environments alive)

**Critical implication:** If a run is cancelled mid-deploy, the EC2 lock remains held. The TTL is the mandatory recovery mechanism. Without a TTL, the next run would block forever waiting for a lock held by a dead runner.

---

## Research Question 2: EC2 Deployment Lock File

### Why flock(1) Over noclobber Redirect

| Approach | Atomic? | Supports Waiting? | Timeout Possible? | Recommended |
|----------|---------|-------------------|-------------------|-------------|
| `set -C; echo $$ > lockfile` (noclobber) | Partial (TOCTOU between test and write) | NO — fails immediately | NO | NO |
| `flock(1)` | YES (kernel advisory lock) | YES — can block waiting | YES — `flock -w SECONDS` | YES |
| `ln(1)` (symlink) | YES (atomic symlink creation) | NO — fails immediately | Requires polling loop | Alternative |
| `mkdir(1)` (directory as lock) | YES (atomic mkdir) | NO — fails immediately | Requires polling loop | Alternative |
| `touch + test` | NO — TOCTOU race | N/A | N/A | NO |

**Recommendation: flock(1).** It is:
- Available on Ubuntu 22.04 by default (util-linux package)
- Atomic at the kernel level (POSIX advisory lock)
- Supports timeout with `flock -w SECONDS`
- Supports release on script exit via EXIT trap
- Built-in wait semantics — no busy-polling loop needed

### Lock File Location

**Path:** `/tmp/blue-green-deploy.lock`

Rationale: `/tmp` is world-writable by the ubuntu user, survives reboots, and is not persisted across EC2 instance replacement. Using `/var/run/` is equivalent but requires sudo. `/tmp` requires no special permissions.

### Lock File Content Schema

Store structured data in the lock file for diagnosability:

```
LOCK_HELD=1
PID=<pid>
HOSTNAME=<ec2-hostname>
ACQUIRED_AT=<ISO8601 timestamp>
GITHUB_RUN_ID=<run id or "local">
GITHUB_RUN_URL=<run url or "-">
TTL_AT=<ISO8601 timestamp when lock expires>
```

Example:
```
LOCK_HELD=1
PID=12345
HOSTNAME=ip-10-0-1-42
ACQUIRED_AT=2026-04-01T12:00:00Z
GITHUB_RUN_ID=1234567890
GITHUB_RUN_URL=https://github.com/your-org/your-repo/actions/runs/1234567890
TTL_AT=2026-04-01T12:10:00Z
```

### Recommended Lock Script: `scripts/ec2-lock.sh`

```bash
#!/usr/bin/env bash
# scripts/ec2-lock.sh — EC2-side deployment lock management
# Usage:
#   ./ec2-lock.sh acquire  # Acquire lock (blocks until available or timeout)
#   ./ec2-lock.sh release  # Release lock (only if held by us)
#   ./ec2-lock.sh status   # Check if locked (exit 0=free, exit 1=held)
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

        cat > "$LOCKFILE" <<EOF
LOCK_HELD=1
PID=$$
HOSTNAME=${HOSTNAME}
ACQUIRED_AT=${now}
GITHUB_RUN_ID=${run_id}
GITHUB_RUN_URL=${run_url}
TTL_AT=${ttl_at}
EOF
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
```

**Key design decisions:**

1. **Atomic flock + content write:** The flock acquisition and file content write happen inside the same `flock` block (file descriptor 9). This ensures that even if the process crashes between acquiring the lock and writing the content, the lock is at least held and the next run will see it (and clean it if stale).

2. **TTL checked inside flock:** The stale-lock check happens inside the critical section. This prevents a race where two runs both see a stale lock simultaneously and both try to clean it.

3. **Distinct exit codes:** `acquire` exits 0 on success, 1 on timeout/failure. `status` exits 0 if free, 1 if held, 2 if stale. These codes allow callers to distinguish states programmatically.

4. **GITHUB_RUN_ID and GITHUB_RUN_URL injected by workflow:** These environment variables are set by the workflow YAML before calling the lock script, enabling human-readable lock diagnostics.

### flock Advisory Lock Semantics

`flock(1)` is an advisory lock — cooperating processes must use it. Any process that bypasses flock can corrupt the lock file. In a controlled environment (only the GitHub Actions runner uses this lock), advisory locking is sufficient.

### TTL Selection

| TTL | Pros | Cons |
|-----|------|------|
| 5 minutes | Quick recovery from crashed runner | Might expire during slow docker pull on large images |
| **10 minutes** | Covers slow image pulls (~2-3 GB on slow connection) | 10-minute gap before retry on lock contention |
| 30 minutes | Very safe for large images | Long delay on lock contention |

**Recommendation: 10 minutes (600 seconds).** Worst-case deploy: docker pull (~2-5 min) + compose up (~10s) + health polling (60s) + Nginx switch (~5s) = ~7 minutes. 10 minutes gives buffer.

**Lock wait timeout (`LOCK_TIMEOUT`):** 5 minutes. If the lock is actively held, wait up to 5 minutes before giving up. Combined with 10-minute TTL, this means: worst-case wait = 5 minutes (waiting) + (TTL of dead lock) = up to 15 minutes.

---

## Research Question 3: Race Condition Between GitHub Concurrency and EC2 Lock

### Scenario 1: GitHub Cancels In-Progress Run, EC2 Lock Was Acquired

| Time | GitHub Runner | EC2 State |
|------|-------------|-----------|
| T+0 | Run A starts, acquires EC2 lock | Lock: Run A, TTL=T+10min |
| T+60 | New push arrives, GitHub cancels Run A | Lock: Run A (still held) |
| T+60 | Run A's SSH command still running (docker pull) | Lock: Run A |
| T+120 | Run B starts, tries to acquire lock | Lock: Run A (not yet expired) |
| T+120 | Run B blocks waiting for lock (flock -w 300s) | Lock: Run A |
| T+180 | Run A's lock TTL expires | Lock: Run A (stale) |
| T+180 | Run B's flock acquires the (now stale) lock | Lock: Run B |
| T+180 | Run B proceeds with deployment | Lock: Run B |

**Outcome:** Run B waits for up to 5 minutes, then detects the stale lock and proceeds. No data corruption. Deployment eventually succeeds.

### Scenario 2: Runner Dies (Process Killed) Mid-Deploy

| Time | Event | EC2 State |
|------|-------|-----------|
| T+0 | Run A acquires lock, starts docker pull | Lock: Run A, TTL=T+10min |
| T+5 | Runner process killed (OOM, SIGKILL, hardware failure) | Lock: Run A (held, orphaned) |
| T+10 | TTL expires | Lock: Run A (stale) |
| T+10+ | Run B starts, cleans stale lock, acquires, deploys | Lock: Run B |

**Outcome:** Same as Scenario 1. TTL is the recovery mechanism for runner death.

### Scenario 3: EC2 Lock Acquired But SSH Command Fails Immediately

| Time | Event |
|------|-------|
| T+0 | Run A acquires lock, then SSH fails on host key check |
| T+0 | Run A exits with error, lock held, TTL=T+10min |
| T+10 | Lock expires |
| T+10+ | Run B proceeds |

**Outcome:** Clean. The lock holds for 10 minutes as a safety margin even for immediate failures.

### How the New Run Cleans Stale Locks

At the start of every deployment run, before acquiring the lock:

```yaml
# Clean stale locks at the start of every run
- name: Clean stale deployment locks
  uses: appleboy/ssh-action@v0.40.0
  with:
    host: ${{ secrets.EC2_HOST }}
    username: ubuntu
    key: ${{ secrets.EC2_SSH_KEY }}
    script: |
      LOCK_TIMEOUT=300 LOCK_TTL=600 \
        GITHUB_RUN_ID=${{ github.run_id }} \
        GITHUB_RUN_URL=https://github.com/${{ github.repository }}/actions/runs/${{ github.run_id }} \
        bash -s cleanup
    timeout: 30s
```

The `cleanup` command reads the TTL in the lock file, compares it to now, and removes the file if expired.

### Handling Cancelled Mid-Step EC2 State

If a run is cancelled by GitHub concurrency during the Nginx switch step:

1. **State file already updated:** `/var/run/blue-green-state` says the new slot is active.
2. **Nginx already reloaded:** Traffic routes to the new slot.
3. **Old container still running:** The previous slot's container is still running (Phase 2 architecture: both stay alive).

**Result:** The cancelled run actually succeeded from the user's perspective. The new run will detect the state file already reflects the new slot, calculate the correct inactive slot, and deploy the next version to it. No special recovery needed.

### Recovery Time Summary

| Failure Mode | Detection | Recovery |
|-------------|-----------|----------|
| Cancelled run (GitHub concurrency) | Next run sees lock held | Waits up to LOCK_TIMEOUT (5 min), then cleans stale TTL |
| Runner crash mid-deploy | TTL expiry (10 min) | Next run cleans stale lock |
| EC2 unreachable | Lock acquisition fails immediately | Human intervention |

---

## Research Question 4: GitHub Actions Secrets Management

### Repository Secrets to Configure

| Secret Name | Value | Notes |
|------------|-------|-------|
| `EC2_SSH_KEY` | Full private key PEM content (including `-----BEGIN OPENSSH PRIVATE KEY-----` through `-----END OPENSSH PRIVATE KEY-----`) | Multi-line secret. Pass to `appleboy/ssh-action` inline key parameter |
| `EC2_HOST` | `13.236.205.122` | Could vary per environment |
| `DOCKER_USERNAME` | Docker Hub username | For `docker/login-action` |
| `DOCKER_PASSWORD` | Docker Hub password or access token | For `docker/login-action` |

### SSH Key Setup with `appleboy/ssh-action`

`appleboy/ssh-action` accepts the raw private key content directly in the YAML, avoiding the need to write it to disk:

```yaml
- name: Deploy to EC2
  uses: appleboy/ssh-action@v0.40.0
  with:
    host: ${{ secrets.EC2_HOST }}
    username: ubuntu
    key: ${{ secrets.EC2_SSH_KEY }}
    script: |
      set -euo pipefail
      echo "Running on $(hostname)"
      # ... deployment commands ...
    envs: IMAGE_TAG
    timeout: 10m
```

**Advantages over raw `ssh` in a `run:` step:**
- No manual key setup step needed (no `chmod 600` on Linux, no ssh-agent on Windows)
- Handles `StrictHostKeyChecking=no` automatically
- Supports `envs:` to inject workflow variables into the remote shell
- Supports `if: always()` steps cleanly for lock release
- Handles timeout and retry

### Alternative: Direct file write (for Linux runners that need explicit key file)

```yaml
- name: Configure SSH key
  run: |
    mkdir -p ~/.ssh
    echo "${{ secrets.EC2_SSH_KEY }}" > ~/.ssh/ec2_key
    chmod 600 ~/.ssh/ec2_key
  shell: bash
```

**Requirements:**
- Runner OS: Linux (ubuntu-latest) — `chmod 600` works on ext4/XFS
- Private key: No passphrase (CI/CD runners cannot interactively provide passphrases)

### Alternative: ssh-agent (for Windows runners)

```yaml
- name: Configure SSH agent
  run: |
    eval "$(ssh-agent -s)"
    ssh-add - <<< "${{ secrets.EC2_SSH_KEY }}"
    echo "SSH_AUTH_SOCK=$SSH_AUTH_SOCK" >> $GITHUB_ENV
  shell: bash
```

Use this if the runner is Windows-based (NTFS does not honor chmod).

### Security Notes

1. **Private key must be unencrypted (no passphrase).** CI/CD runners cannot interactively provide passphrases.
2. **Dedicated deploy key recommended.** Generate a new SSH key pair specifically for GitHub Actions deployments:
   ```bash
   ssh-keygen -t ed25519 -N '' -C "github-actions-blue-green-deploy" -f deploy_key
   ```
   Add the public key to the EC2 instance's `~/.ssh/authorized_keys` for the ubuntu user.
3. **Limit key permissions on EC2:** Use `command=` in `authorized_keys` to restrict the deploy key to only allow the commands needed:
   ```
   command="/home/ubuntu/validate-deploy.sh",no-pty,no-agent-forwarding ssh-ed25519 AAAA... github-actions-blue-green-deploy
   ```

---

## Common Pitfalls

### Pitfall 1: Cancelled Run Leaves EC2 Lock Without TTL
**What goes wrong:** Lock acquired but runner cancelled before TTL written. Next run blocks forever.
**How to avoid:** Write the TTL into the lock file atomically with the acquire (both inside the flock critical section). The `ec2-lock.sh` acquire function writes TTL atomically inside the flock block.

### Pitfall 2: Runner Runs on Windows (GitHub-hosted)
**What goes wrong:** `chmod 600 ~/.ssh/ec2_key` is a no-op on Windows (NTFS). SSH refuses the key with "UNPROTECTED PRIVATE KEY FILE".
**How to avoid:** Use `appleboy/ssh-action` (which handles key injection internally), or use the ssh-agent approach for Windows runners.

### Pitfall 3: Lock Released Before Deploy Complete
**What goes wrong:** `release()` called in a trap that fires during a long-running docker pull. Next run acquires lock and starts deploying to the same slot.
**How to avoid:** Call `release()` only after the full deploy pipeline completes. Use `appleboy/ssh-action` with an explicit `if: always()` release step at the end of the job, not an inline trap.

### Pitfall 4: Image Tag Collision
**What goes wrong:** Run A builds image tagged `sha-abc1234`. Run B builds `sha-def4567` after Run A is cancelled. Which image is in the compose file?
**How to avoid:** Use `GITHUB_SHA` as the image tag. Concurrency group ensures only one run is active at a time. Each run builds exactly one image with exactly one tag derived from the triggering commit.

### Pitfall 5: `latest` Tag Used Instead of SHA
**What goes wrong:** `docker pull mythicc123/multi-container-service:latest` pulls a stale cached image.
**How to avoid:** Always use `${{ github.sha }}` as the tag. Never use `latest` in the deploy pipeline. Push `latest` separately for convenience but never consume it.

### Pitfall 6: Lock Acquisition Without Stale Detection
**What goes wrong:** A new run acquires the lock and overwrites a stale lock that belonged to a dead runner. But the dead runner's docker compose processes are still running and conflicting.
**How to avoid:** After acquiring a stale lock, the new run should verify the EC2 state is consistent before proceeding. Specifically: check if docker compose for the inactive slot is running and if so, stop it before starting a new deploy.

---

## Code Examples

### Complete GitHub Actions Workflow: `.github/workflows/deploy.yml`

```yaml
name: Deploy to EC2 (Blue-Green)

on:
  push:
    branches:
      - main

# BG-08: Prevent concurrent deployments. cancel-in-progress: true cancels
# any in-progress run when a new push arrives — the latest code always wins.
# Using ${{ github.repository }} groups all runs in one bucket.
concurrency:
  group: ${{ github.repository }}
  cancel-in-progress: true

env:
  DOCKER_IMAGE: mythicc123/multi-container-service

jobs:
  deploy:
    name: Blue-Green Deploy
    runs-on: ubuntu-latest

    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      # ── Docker Setup ──────────────────────────────────────────────
      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Login to Docker Hub
        uses: docker/login-action@v3
        with:
          username: ${{ secrets.DOCKER_USERNAME }}
          password: ${{ secrets.DOCKER_PASSWORD }}

      # ── Build & Push Immutable SHA-Tagged Image (BG-07) ────────────
      # Tag with GITHUB_SHA so each deploy is reproducible and immutable.
      # Image: mythicc123/multi-container-service:sha-a1b2c3d4e5f6...
      - name: Build and push Docker image
        uses: docker/build-push-action@v6
        with:
          context: .
          push: true
          tags: |
            ${{ env.DOCKER_IMAGE }}:sha-${{ github.sha }}
          cache-from: type=gha
          cache-to: type=gha,mode=max

      # ── Deploy via appleboy/ssh-action ──────────────────────────────
      # appleboy/ssh-action handles SSH key injection inline — no manual
      # key setup step needed. It supports envs: for variable injection
      # and timeout for long-running commands.
      - name: Run blue-green deployment
        uses: appleboy/ssh-action@v0.40.0
        with:
          host: ${{ secrets.EC2_HOST }}
          username: ubuntu
          key: ${{ secrets.EC2_SSH_KEY }}
          script: |
            set -euo pipefail

            # BG-08: Export lock context for traceability
            export GITHUB_RUN_ID=${{ github.run_id }}
            export GITHUB_RUN_URL=https://github.com/${{ github.repository }}/actions/runs/${{ github.run_id }}
            export LOCK_TIMEOUT=300
            export LOCK_TTL=600

            # BG-08: Clean stale locks before starting (defense-in-depth)
            # Removes any lock from a previously crashed/cancelled run.
            # Write lock script inline — avoids needing it pre-installed on EC2.
            /bin/bash << 'LOCKSCRIPT'
            LOCKFILE="/tmp/blue-green-deploy.lock"
            LOCK_TTL="${LOCK_TTL:-600}"
            now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
            ttl_at=$(grep '^TTL_AT=' "$LOCKFILE" 2>/dev/null | cut -d= -f2 || echo "")
            if [[ -n "$ttl_at" && "$ttl_at" < "$now" ]]; then
              echo "Removing stale lock (TTL expired: ${ttl_at})"
              rm -f "$LOCKFILE"
            fi
            LOCKSCRIPT

            # BG-08: Acquire EC2 lock with traceability
            echo "Acquiring deployment lock..."
            (
              flock -w 300 9 || { echo "ERROR: Could not acquire lock within 300s"; exit 1; }
              now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
              ttl_at=$(date -u -d "+${LOCK_TTL} seconds" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)
              cat > "$LOCKFILE" <<EOF
LOCK_HELD=1
PID=$$
HOSTNAME=$(hostname)
ACQUIRED_AT=${now}
GITHUB_RUN_ID=${GITHUB_RUN_ID:-local}
GITHUB_RUN_URL=${GITHUB_RUN_URL:--}
TTL_AT=${ttl_at}
EOF
              echo "LOCK ACQUIRED: PID=$$ TTL_AT=${ttl_at}"
            ) 9>/tmp/blue-green-deploy.lock

            # BG-06: Run the full deploy pipeline (reuses Phase 2 scripts)
            # IMAGE_TAG must match the tag pushed above
            IMAGE_TAG=sha-${{ github.sha }} bash /tmp/deploy/run-deploy.sh
            DEPLOY_STATUS=$?

            # BG-08: Release lock — only if deploy succeeded.
            # On deploy failure, lock is NOT released — TTL will clean it.
            if [[ $DEPLOY_STATUS -eq 0 ]]; then
              rm -f /tmp/blue-green-deploy.lock
              echo "LOCK RELEASED"
            else
              echo "WARNING: Deploy failed (exit $DEPLOY_STATUS) — lock NOT released (TTL will clean it)"
            fi

            exit $DEPLOY_STATUS
          envs: IMAGE_TAG
          timeout: 10m

      # NOTE: run-deploy.sh must be pre-installed on EC2 at /tmp/deploy/run-deploy.sh.
      # This can be done in a setup step before the deploy, or baked into the EC2 AMI.
      # Setup step (run once):
      #
      # - name: Install deploy scripts on EC2
      #   uses: appleboy/ssh-action@v0.40.0
      #   with:
      #     host: ${{ secrets.EC2_HOST }}
      #     username: ubuntu
      #     key: ${{ secrets.EC2_SSH_KEY }}
      #     script: |
      #       sudo mkdir -p /tmp/deploy
      #       # SCP or heredoc each script to /tmp/deploy/
      #     timeout: 30s

      # ── Smoke Test (BG-09) ─────────────────────────────────────────
      # BG-09: Call Todo API endpoints through the public IP after Nginx switch.
      - name: Smoke test API endpoints
        run: |
          sleep 5
          HOST_IP="${{ secrets.EC2_HOST }}"
          echo "Testing API at http://${HOST_IP}"

          # GET — should return 200 with array
          HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://${HOST_IP}/api/todos)
          if [[ "$HTTP_CODE" != "200" ]]; then echo "GET /api/todos failed: $HTTP_CODE"; exit 1; fi
          echo "GET /api/todos: OK ($HTTP_CODE)"

          # POST — create a todo
          RESPONSE=$(curl -s -X POST http://${HOST_IP}/api/todos \
            -H "Content-Type: application/json" \
            -d "{\"text\":\"ci-smoke-test-$(date +%s)\",\"done\":false}")
          echo "POST /api/todos: $RESPONSE"

          # PUT — update the created todo (extract id)
          TODO_ID=$(echo "$RESPONSE" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4 || echo "")
          if [[ -n "$TODO_ID" ]]; then
            PUT_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X PUT \
              http://${HOST_IP}/api/todos/${TODO_ID} \
              -H "Content-Type: application/json" \
              -d '{"text":"ci-smoke-test-updated","done":true}')
            echo "PUT /api/todos/${TODO_ID}: $PUT_CODE"

            # DELETE — clean up
            DEL_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE \
              http://${HOST_IP}/api/todos/${TODO_ID})
            echo "DELETE /api/todos/${TODO_ID}: $DEL_CODE"
          fi

          echo ""
          echo "SMOKE TEST: ALL PASSED"
        shell: bash
```

### Verifying flock Availability on EC2 (Pre-flight Check)

```bash
# Add to workflow before deployment step
- name: Verify flock is available on EC2
  uses: appleboy/ssh-action@v0.40.0
  with:
    host: ${{ secrets.EC2_HOST }}
    username: ubuntu
    key: ${{ secrets.EC2_SSH_KEY }}
    script: |
      if command -v flock > /dev/null 2>&1; then
        echo "flock: OK ($(flock --version | head -1))"
      else
        echo "ERROR: flock not found on EC2 — install with: sudo apt-get install -y util-linux"
        exit 1
      fi
    timeout: 30s
```

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Concurrency control | Custom job queue or external mutex service | GitHub Actions `concurrency:` block | First-class platform support; no external service needed |
| Lock file atomicity | `set -C` + redirect (no timeout, no waiting) | flock(1) with `-w TIMEOUT` | Built-in timeout, kernel-level atomicity |
| SSH key management | Manual `echo $SECRET > file` without permissions | `appleboy/ssh-action` with inline key | Handles key injection, permissions, and quoting correctly |
| Stale lock detection | PID-only check | TTL timestamp in lock file + `date -u` comparison | Works across runner restarts; PID-only check fails when runner dies |
| Lock recovery | Manual intervention | TTL + cleanup at start of next run | Automatic recovery within LOCK_TTL seconds |

---

## Open Questions

1. **Where does the lock script (`ec2-lock.sh`) live on EC2?**
   - What we know: Scripts need to be accessible at `/tmp/deploy/` on the EC2 instance.
   - What's unclear: Should it be installed at provisioning time (e.g., in a Terraform user_data script), or uploaded by a setup step in the workflow?
   - Recommendation: Install via a pre-deployment workflow step that runs `appleboy/ssh-action` to write the script to `/tmp/deploy/ec2-lock.sh` before the main deploy step. This keeps the script under version control in the repo.

2. **What SSH key algorithm to use?**
   - What we know: The existing EC2 key is likely RSA (based on `ec2-static-site-key.pem` naming from multi-container-service).
   - What's unclear: Whether the existing key can be reused or needs to be regenerated.
   - Recommendation: Check the existing key algorithm (`ssh-keygen -l -f ec2_key.pem`). If RSA-2048+, reuse it. If RSA-1024 or older, regenerate with ED25519.

3. **Should `appleboy/ssh-action` or raw `ssh` in a `run:` step be used?**
   - What we know: `appleboy/ssh-action` handles key injection inline, supports `if: always()`, and supports `envs:` variable passing.
   - Recommendation: Use `appleboy/ssh-action` for the main deployment step. Write the lock script inline within the script block to avoid needing it pre-installed on EC2.

4. **How to handle the runner crash scenario?**
   - What we know: The EC2 TTL (10 min) is the recovery mechanism, but 10 minutes may be too long for a production outage.
   - Recommendation: Start with 10-minute TTL. If it proves problematic, add a CloudWatch alarm on the lock file's mtime, or a cron job on the EC2 that removes locks older than 5 minutes. Phase 3.x material.

---

## Environment Availability

> Step 2.6: SKIPPED — no external tool dependencies beyond GitHub Actions platform and existing EC2 infrastructure.

Phase 3 adds:
- GitHub Actions runner (`ubuntu-latest` — Linux, pre-installed tools)
- `appleboy/ssh-action` v0.40.0 — marketplace action, downloaded at runtime
- `docker/build-push-action` v6 — marketplace action
- `flock(1)` on EC2 — verify with `command -v flock` on the actual EC2 instance
- No new package installations on EC2 required for Phase 3

**Pre-flight check to include in plan:**
```bash
ssh ubuntu@$EC2_HOST 'command -v flock && echo "flock OK" || echo "MISSING"'
```

If flock is missing (unlikely on Ubuntu 22.04), fall back to the `mkdir`-based lock or install with `sudo apt-get install -y util-linux`.

---

## Sources

### Primary (HIGH confidence)
- GitHub Actions documentation — `concurrency:` block behavior, `cancel-in-progress`, group naming — https://docs.github.com/en/actions/using-workflows/workflow-syntax-for-github-actions#example-limiting-concurrency
- GitHub Actions `appleboy/ssh-action` v0.40.0 — SSH execution marketplace action, key injection, timeout, `if: always()` support
- util-linux flock(1) man page — atomic lock acquisition, `-w TIMEOUT` flag, file descriptor semantics
- Phase 1 and Phase 2 scripts (`scripts/deploy.sh`, `scripts/health-check.sh`, `scripts/switch.sh`, `scripts/rollback.sh`, `scripts/run-deploy.sh`) — confirmed SSH patterns, slot calculation, Nginx switching, health check approach
- Phase 2 research (`.planning/phases/02-deployment-automation/02-RESEARCH.md`) — locked decisions, phase requirements
- STATE.md — current project state, accumulated context
- REQUIREMENTS.md — BG-06, BG-07, BG-08, BG-09 requirement definitions

### Secondary (MEDIUM confidence)
- GitHub Actions runner OS differences (Windows `chmod` limitations, ssh-agent approach) — general knowledge, not project-verified
- `mkdir`-based lock atomicity on POSIX — standard POSIX guarantees, widely documented
- TTL selection (10 minutes for docker pull scenarios) — based on typical Docker image sizes and EC2 network speeds

### Tertiary (LOW confidence)
- Specific flock version availability on Ubuntu 22.04 AMIs — not verified on the actual EC2 instance; plan should include pre-flight check
- Windows runner SSH permission behavior — may vary by GitHub Actions runner image version

---

## Metadata

**Confidence breakdown:**
- GitHub Actions concurrency: HIGH — well-documented platform feature, directly applicable
- EC2 locking (flock): HIGH — standard Linux tool, available on Ubuntu 22.04, tested approach
- SSH secrets management: HIGH — standard GitHub Actions pattern, works with existing SSH infrastructure
- Race condition handling: HIGH — TTL-based stale lock detection is a well-established pattern
- Specific flock version on EC2: LOW — not verified on the actual instance; plan includes pre-flight check

**Research date:** 2026-04-01
**Valid until:** 2026-05-01 (GitHub Actions and flock are stable; no breaking changes expected in this domain)
