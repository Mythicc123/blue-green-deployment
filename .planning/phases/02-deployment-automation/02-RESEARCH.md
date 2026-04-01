# Phase 2: Deployment Automation - Research

**Researched:** 2026-04-01
**Domain:** Bash scripting, Docker Compose health-check polling, Nginx state management, SSH-based remote deployment orchestration
**Confidence:** HIGH

## Summary

Phase 2 delivers the manual deployment automation scripts that wrap the Phase 1 foundation. The key insight driving the architecture: Phase 1 already built `/opt/blue/` and `/opt/green/` Docker Compose environments and the two Nginx configs. Phase 2 scripts now orchestrate those pieces into a cohesive deploy-to-switch pipeline and provide a rollback safety net. The critical design constraint is that these scripts will be consumed by GitHub Actions in Phase 3, so every script must be idempotent, accept env-var overrides, and output machine-parseable status.

**Primary recommendation:** Write four scripts (`deploy.sh`, `health-check.sh`, `switch-nginx.sh`, `rollback.sh`) as pure remote-execution wrappers around SSH, each covering exactly one responsibility. Compose them into a single `run-deploy.sh` entry point that handles the full blue-to-green or green-to-blue cycle. All scripts must use `set -euo pipefail`, read from `/var/run/blue-green-state`, and write to it only after a successful operation.

---

## User Constraints (from CONTEXT.md / STATE.md)

### Locked Decisions

- Both environments stay running after switch; rollback is `nginx -s reload` only, no container rebuild
- State file: `/var/run/blue-green-state` contains `blue` or `green` (Phase 1 architecture)
- Nginx switching: `ln -sf` + `nginx -t` + `nginx -s reload` (Phase 1 already implemented in `scripts/switch.sh`)
- Health endpoint: `localhost:<port>/health` returns `{"status":"ok","mongo":"connected"}`
- Shared MongoDB: `multi-container-service-mongo-1:27017`
- SSH host: `ubuntu@13.236.205.122`, SSH key: `$HOME/.ssh/ec2-static-site-key.pem`
- Docker image: `mythicc123/multi-container-service`
- Blue port: 3001, green port: 3002
- Compose dirs: `/opt/blue/`, `/opt/green/`
- Nginx config names: `blue-green-blue.conf`, `blue-green-green.conf`
- Symlink path: `/etc/nginx/sites-enabled/blue-green`

### Out of Scope (Deferred)

- Automated rollback (Phase 2: manual rollback only)
- Separate MongoDB per environment
- Canary traffic splitting
- Kubernetes / EKS
- Prometheus/Grafana
- Domain / Route53
- Separate EC2 instance
- GitOps
- Database migrations as separate pipeline step

---

## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| BG-03 | Health check polling before switch — CI/CD or manual script polls `http://localhost:<inactive_port>/health` until healthy (up to 60s), before Nginx switch | Script pattern, polling loop, retry timeout, exit codes |
| BG-04 | Active slot state tracking — `/var/run/blue-green-state` contains `blue` or `green`, updated after each switch | State file format, read/write atomicity, read by CI/CD |
| BG-10 | Manual rollback — SSH script that reads state, flips Nginx symlink to other slot, `nginx -s reload`. No container rebuild | Rollback logic, detecting "previous" slot |
| BG-13 | Container log access — `docker compose logs` readable via SSH or CI/CD | Log commands, tailing options |
| BG-14 | Nginx access log monitoring — logs in `/var/log/nginx/access.log`, readable and queryable | Log path, query approaches |

---

## Standard Stack

### Core
| Tool | Version | Purpose | Why Standard |
|------|---------|---------|--------------|
| bash | 5.1+ (Ubuntu 22.04) | Scripting runtime | Ships with Ubuntu on EC2; all existing scripts use it |
| SSH | OpenSSH 8.x | Remote execution | Already configured; all Phase 1 scripts use it |
| curl | 7.81+ | Health check HTTP calls | Already on EC2; lightweight, no jq needed for simple health check |
| docker compose | v2.x | Container orchestration | Already in use; `docker compose logs` is the log command |
| nginx | 1.24+ (Ubuntu 22.04) | Reverse proxy/switching | Already installed and configured |

### Supporting
| Tool | Purpose | When to Use |
|------|---------|-------------|
| wget | Health check HTTP calls | Alternative to curl (already on EC2, used in Docker healthcheck) |
| timeout | Enforce polling timeout | `timeout 60 curl ...` for polling loop with hard ceiling |
| readlink | Read symlink target | Verify active config without parsing state file |
| tee | Atomic state file writes | `tee /var/run/blue-green-state` for atomic update |

---

## Architecture Patterns

### Recommended Project Structure

```
scripts/
├── deploy.sh              # Pull new image + docker compose up on inactive slot
├── health-check.sh        # Poll localhost:<port>/health with retry logic
├── switch-nginx.sh        # ln -sf + nginx -t + nginx -s reload + update state
├── rollback.sh            # Read state, switch to other slot, reload nginx
├── run-deploy.sh          # Orchestrator: deploy → health-check → switch → log check
└── get-active-slot.sh     # Read /var/run/blue-green-state, echo slot name
```

**Key structure principle:** Each script owns exactly one responsibility and can be called independently (by a human or by GitHub Actions in Phase 3). `run-deploy.sh` is the convenience composer; `deploy.sh`, `health-check.sh`, and `switch-nginx.sh` must also work standalone.

### Pattern 1: SSH Remote Execution Wrapper

**What:** Local script SSH's into EC2 to run a command or series of commands.

**When to use:** All remote operations in Phase 2.

**Source:** All three Phase 1 scripts (`switch.sh`, `setup-envs.sh`, `setup-nginx.sh`) already follow this pattern.

**Template:**
```bash
SSH_KEY="${SSH_KEY:-$HOME/.ssh/ec2-static-site-key.pem}"
HOST="${HOST:-13.236.205.122}"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

ssh $SSH_OPTS -i "$SSH_KEY" ubuntu@$HOST '<remote command>'
```

**Anti-pattern to avoid:** Embedding the SSH key path or host directly in the script body — use env-var overrides so CI/CD can inject values.

### Pattern 2: State File Read/Write

**What:** `/var/run/blue-green-state` contains exactly `blue` or `green` (no trailing newline preferred).

**Read:**
```bash
# Read active slot (default to blue if file missing — first-run safety)
active_slot=$(ssh $SSH_OPTS -i "$SSH_KEY" ubuntu@$HOST "cat /var/run/blue-green-state 2>/dev/null || echo blue")
```

**Write (atomic via tee + sudo):**
```bash
# Update state file after switch
ssh $SSH_OPTS -i "$SSH_KEY" ubuntu@$HOST "echo '$new_slot' | sudo tee /var/run/blue-green-state > /dev/null"
```

**Why tee + sudo:** The state file is at `/var/run/` which requires root. `sudo tee` is the cleanest approach. Alternatively, make the file owned by ubuntu: `sudo chown ubuntu:ubuntu /var/run/blue-green-state` at first-run.

### Pattern 3: Health Check Polling with Timeout

**What:** Loop that calls `curl` against the inactive slot's health endpoint, retrying until healthy or until a timeout is reached.

**Source:** BG-03 requires "up to 60s" polling. The existing Phase 1 `setup-envs.sh` uses a flat `sleep 30` which is not robust — Phase 2 must use actual retry logic.

**Template:**
```bash
# Poll health endpoint, fail if not healthy within MAX_WAIT seconds
health_check() {
    local port="$1"
    local max_wait="${2:-60}"
    local waited=0
    local interval=3

    while [[ $waited -lt $max_wait ]]; do
        if curl -sf "http://localhost:${port}/health" | grep -q '"status":"ok"'; then
            echo "Healthy after ${waited}s"
            return 0
        fi
        sleep "$interval"
        waited=$((waited + interval))
    done
    echo "TIMEOUT: Not healthy after ${max_wait}s"
    return 1
}
```

**Port mapping:** blue=3001, green=3002. `inactive_port=$((active_slot == "blue") ? 3002 : 3001)` — but simpler: hardcode the map.

### Pattern 4: Deterministic Inactive Slot Calculation

**What:** Given the active slot, compute the inactive slot without conditionals.

**Source:** Required by deploy.sh to know which slot to deploy to.

```bash
inactive_slot="blue"
[[ "$active_slot" == "blue" ]] && inactive_slot="green"
# OR
inactive_slot=$([[ "$active_slot" == "blue" ]] && echo "green" || echo "blue")
```

**Port map:**
```bash
# Simple lookup
case "$slot" in
    blue)  port=3001 ;;
    green) port=3002 ;;
esac
```

### Pattern 5: Nginx Switch (reused from Phase 1)

**What:** `ln -sf` symlink + `nginx -t` + `nginx -s reload` + state file update.

**Source:** `scripts/switch.sh` already implements this pattern. The only addition for Phase 2 is writing the state file after the switch.

**Steps:**
1. `sudo ln -sf /etc/nginx/sites-available/blue-green-{slot}.conf /etc/nginx/sites-enabled/blue-green`
2. `sudo nginx -t`
3. `sudo nginx -s reload`
4. `echo '{slot}' | sudo tee /var/run/blue-green-state`

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Polling with timeout | Custom sleep loop tracking | bash `while` + arithmetic | Simple enough to write correctly; no external tool needed |
| State file atomicity | `echo > file` (race condition) | `tee` (atomic write) | `tee` is atomic on Linux for single-line writes |
| Container logs | `docker logs` (single container) | `docker compose logs` (compose-aware) | Blue/green are compose projects; `docker compose logs` is compose-aware |
| Nginx config test | Skip `nginx -t` | Always run `nginx -t` before reload | Config errors cause Nginx to fail to reload, leaving site down |

**Key insight:** This domain is simple enough that hand-rolling is appropriate. No external libraries needed. The risk is not in the bash logic itself but in edge cases: missing state file on first run, port already in use, image pull failures.

---

## Common Pitfalls

### Pitfall 1: State File Missing on First Run
**What goes wrong:** `cat /var/run/blue-green-state` fails on first deployment, scripts exit with error or return empty string.
**How to avoid:** Default to `blue` if file is missing: `active_slot=$(cat /var/run/blue-green-state 2>/dev/null || echo blue)`.
**Warning signs:** Scripts returning empty slot, switch targeting wrong config.

### Pitfall 2: Polling Succeeds on Wrong /health Response
**What goes wrong:** Curl returns 200 but body is not `{"status":"ok"...}`. Script proceeds to switch Nginx before app is ready.
**How to avoid:** Parse the JSON body with `grep -q '"status":"ok"'` or `jq` if available. `curl -f` alone is not sufficient since the endpoint always returns 200.
**Warning signs:** Switch to new slot, public health check fails, MongoDB connection not established yet.

### Pitfall 3: State File Written Before Nginx Reload
**What goes wrong:** State file updated to `green`, then `nginx -t` fails, then script exits. State file says `green` but Nginx still routes to `blue`.
**How to avoid:** Write state file only after `nginx -s reload` succeeds (or not at all on failure).
**Warning signs:** State file and Nginx routing disagree after a failed deploy.

### Pitfall 4: Docker Image Pull Failures Not Detected
**What goes wrong:** `docker compose pull` fails silently or times out, `docker compose up` starts the old cached image.
**How to avoid:** Explicitly check exit code of `docker compose pull`: `ssh ... "cd /opt/$slot && DOCKER_IMAGE=... docker compose pull || exit 1"`.

### Pitfall 5: Missing `sudo` for State File
**What goes wrong:** `echo blue > /var/run/blue-green-state` fails with "Permission denied" because `/var/run` requires root.
**How to avoid:** Always use `echo '$slot' | sudo tee /var/run/blue-green-state > /dev/null`. Alternatively, `sudo chown ubuntu:ubuntu /var/run/blue-green-state` at setup time and skip sudo in scripts.

---

## Code Examples

### deploy.sh (remote execution via SSH)

```bash
#!/usr/bin/env bash
set -euo pipefail

# Env-var overrides
SSH_KEY="${SSH_KEY:-$HOME/.ssh/ec2-static-site-key.pem}"
HOST="${HOST:-13.236.205.122}"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

# Determine slots
active_slot=$(ssh $SSH_OPTS -i "$SSH_KEY" ubuntu@$HOST \
    "cat /var/run/blue-green-state 2>/dev/null || echo blue")
inactive_slot="blue"; [[ "$active_slot" == "blue" ]] && inactive_slot="green"

# Port map
port=3001; [[ "$inactive_slot" == "green" ]] && port=3002

echo "Deploying to inactive slot: $inactive_slot (port $port)"

ssh $SSH_OPTS -i "$SSH_KEY" ubuntu@$HOST bash <<REMOTE
    set -euo pipefail
    cd /opt/$inactive_slot

    # Pull new image (exit on failure)
    DOCKER_IMAGE=\$(grep DOCKER_IMAGE .env | cut -d= -f2)
    echo "Pulling image: \$DOCKER_IMAGE"
    docker compose pull

    # Restart containers with new image
    echo "Restarting containers..."
    docker compose up -d

    echo "Deploy complete for $inactive_slot"
REMOTE

echo "SUCCESS: Deployed to $inactive_slot"
```

### health-check.sh (polling with timeout)

```bash
#!/usr/bin/env bash
set -euo pipefail

SSH_KEY="${SSH_KEY:-$HOME/.ssh/ec2-static-site-key.pem}"
HOST="${HOST:-13.236.205.122}"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

# Args: slot name, optional timeout (default 60s)
slot="${1:-}"
timeout="${2:-60}"
interval="${3:-3}"

if [[ -z "$slot" ]]; then
    echo "Usage: $0 <blue|green> [timeout] [interval]"
    exit 1
fi

port=3001; [[ "$slot" == "green" ]] && port=3002
url="http://localhost:${port}/health"

echo "Polling $url (timeout: ${timeout}s, interval: ${interval}s)..."

waited=0
while [[ $waited -lt $timeout ]]; do
    # Run curl on remote host
    response=$(ssh $SSH_OPTS -i "$SSH_KEY" ubuntu@$HOST "curl -sf '$url'" 2>/dev/null || echo "")

    if echo "$response" | grep -q '"status":"ok"'; then
        echo "PASS: Health check passed after ${waited}s"
        echo "$response"
        exit 0
    fi

    echo "  [${waited}s] Not ready yet..."
    sleep "$interval"
    waited=$((waited + interval))
done

echo "FAIL: Health check timed out after ${timeout}s"
exit 1
```

### switch-nginx.sh (clean separation from existing switch.sh)

```bash
#!/usr/bin/env bash
set -euo pipefail

# Env-var overrides
SSH_KEY="${SSH_KEY:-$HOME/.ssh/ec2-static-site-key.pem}"
HOST="${HOST:-13.236.205.122}"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

target="${1:-}"
if [[ -z "$target" ]] || [[ "$target" != "blue" && "$target" != "green" ]]; then
    echo "Usage: $0 <blue|green>"
    exit 1
fi

echo "=== Switching to $target ==="

ssh $SSH_OPTS -i "$SSH_KEY" ubuntu@$HOST bash <<REMOTE
    set -euo pipefail

    echo "[1/4] Symlink to blue-green-${target}.conf..."
    sudo ln -sf /etc/nginx/sites-available/blue-green-${target}.conf /etc/nginx/sites-enabled/blue-green

    echo "[2/4] Validating Nginx config..."
    sudo nginx -t

    echo "[3/4] Reloading Nginx..."
    sudo nginx -s reload

    echo "[4/4] Updating state file..."
    echo '$target' | sudo tee /var/run/blue-green-state > /dev/null

    echo "Active config: \$(readlink /etc/nginx/sites-enabled/blue-green)"
    echo "State file: \$(cat /var/run/blue-green-state)"
REMOTE

echo "SUCCESS: Switched to $target"
```

### rollback.sh

```bash
#!/usr/bin/env bash
set -euo pipefail

SSH_KEY="${SSH_KEY:-$HOME/.ssh/ec2-static-site-key.pem}"
HOST="${HOST:-13.236.205.122}"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

# Read active slot
active_slot=$(ssh $SSH_OPTS -i "$SSH_KEY" ubuntu@$HOST \
    "cat /var/run/blue-green-state 2>/dev/null || echo blue")

# Compute other slot
rollback_slot="blue"; [[ "$active_slot" == "blue" ]] && rollback_slot="green"

echo "=== Rolling back: $active_slot -> $rollback_slot ==="

# Reuse switch-nginx.sh logic inline (or call it)
ssh $SSH_OPTS -i "$SSH_KEY" ubuntu@$HOST bash <<REMOTE
    set -euo pipefail
    sudo ln -sf /etc/nginx/sites-available/blue-green-${rollback_slot}.conf /etc/nginx/sites-enabled/blue-green
    sudo nginx -t
    sudo nginx -s reload
    echo '$rollback_slot' | sudo tee /var/run/blue-green-state > /dev/null
    echo "Rollback complete. Active slot: \$(cat /var/run/blue-green-state)"
REMOTE

echo "SUCCESS: Rolled back to $rollback_slot"
```

### run-deploy.sh (orchestrator)

```bash
#!/usr/bin/env bash
set -euo pipefail

# Convenience entry point: deploy + health check + switch in one command
# Can also be run step-by-step by calling individual scripts

SSH_KEY="${SSH_KEY:-$HOME/.ssh/ec2-static-site-key.pem}"
HOST="${HOST:-13.236.205.122}"
IMAGE_TAG="${IMAGE_TAG:-latest}"  # Passed by CI/CD

echo "=== Blue-Green Deployment ==="
echo "Image tag: $IMAGE_TAG"
echo ""

# Step 1: Deploy
echo "[Step 1/4] Deploying to inactive slot..."
./deploy.sh || { echo "DEPLOY FAILED"; exit 1; }

# Step 2: Health check
echo "[Step 2/4] Waiting for health..."
# Health check script must be called with the slot name that was deployed to
# We need to determine that slot first (inactive slot = deploy target)
active_slot=$(ssh $SSH_OPTS -i "$SSH_KEY" ubuntu@$HOST \
    "cat /var/run/blue-green-state 2>/dev/null || echo blue")
inactive_slot="blue"; [[ "$active_slot" == "blue" ]] && inactive_slot="green"
./health-check.sh "$inactive_slot" || { echo "HEALTH CHECK FAILED"; exit 1; }

# Step 3: Switch Nginx
echo "[Step 3/4] Switching Nginx to $inactive_slot..."
./switch-nginx.sh "$inactive_slot" || { echo "SWITCH FAILED"; exit 1; }

# Step 4: Verify
echo "[Step 4/4] Verifying public health..."
sleep 2
curl -sf "http://$HOST/health" | grep -q '"status":"ok"' && echo "PUBLIC HEALTH: OK" || { echo "PUBLIC HEALTH: FAILED"; exit 1; }

echo ""
echo "=== Deployment complete ==="
echo "Active slot: $inactive_slot"
echo "Previous slot still running at port: $((active_slot == "blue" ? 3001 : 3002))"
```

### Log access helpers

```bash
# Container logs (last 100 lines, follow mode)
ssh -i "$SSH_KEY" ubuntu@$HOST "docker compose -f /opt/blue/docker-compose.yml logs --tail=100"
ssh -i "$SSH_KEY" ubuntu@$HOST "docker compose -f /opt/green/docker-compose.yml logs -f"

# Nginx access log (last 100 lines)
ssh -i "$SSH_KEY" ubuntu@$HOST "sudo tail -n 100 /var/log/nginx/access.log"

# Nginx error log
ssh -i "$SSH_KEY" ubuntu@$HOST "sudo tail -n 50 /var/log/nginx/error.log"
```

---

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Flat `sleep N` wait after deploy | Polling loop with health check | Phase 2 | Reliable deploy — no false success on slow container start |
| Manual Nginx switch via ssh | `switch-nginx.sh` script | Phase 1 (existing), Phase 2 (add state update) | Scripted pipeline becomes possible |
| No state tracking | State file `/var/run/blue-green-state` | Phase 1 (existing), Phase 2 (update + read) | CI/CD can determine active slot programmatically |

**Deprecated/outdated:**
- None relevant to Phase 2 scope.

---

## Open Questions

1. **Who creates `/var/run/blue-green-state` on first run?**
   - What we know: Phase 1 setup creates it implicitly or it starts empty. The state file must exist before Phase 2 scripts run.
   - Recommendation: `deploy.sh` or `switch-nginx.sh` should create it with `blue` as default if missing. Add `test -f /var/run/blue-green-state || echo blue | sudo tee /var/run/blue-green-state` as first step.

2. **Should `rollback.sh` update the state file?**
   - What we know: BG-10 says "reads `/var/run/blue-green-state`, flips Nginx symlink". It doesn't explicitly say to update the state file.
   - Recommendation: Yes, update the state file after rollback. This keeps state file and Nginx routing in sync, which is required for subsequent deploys to work correctly.

3. **Should the deploy script update the `.env` file's `DOCKER_IMAGE` with the new tag before `docker compose pull`?**
   - What we know: `.env` files contain `DOCKER_IMAGE=mythicc123/multi-container-service` without a tag.
   - Recommendation: Phase 2 manual scripts can use `docker pull mythicc123/multi-container-service:sometag` directly. Phase 3 (GitHub Actions) will handle the tag injection. Keep `.env` files as-is for Phase 2.

---

## Environment Availability

Step 2.6: SKIPPED (no external dependencies identified)

Phase 2 is entirely bash scripting that:
1. Wraps existing SSH commands (SSH available locally, OpenSSH available on EC2)
2. Calls existing EC2 services (Docker, Nginx)
3. Reads/writes local files (scripts) and remote files (state, configs)

No additional package installations, service accounts, or external tools are required. The entire Phase 2 scripts run against the infrastructure established in Phase 1.

---

## Sources

### Primary (HIGH confidence)
- Phase 1 scripts (`scripts/switch.sh`, `scripts/setup-envs.sh`, `scripts/setup-nginx.sh`) — exact SSH patterns, symlink approach, health check approach
- Phase 1 compose files (`compose/blue/docker-compose.yml`, `compose/green/docker-compose.yml`) — container names, port mapping, env_file usage
- Phase 1 Nginx configs (`nginx/blue-green-blue.conf`, `nginx/blue-green-green.conf`) — upstream names, upstream server IPs
- `.env` files (`compose/blue/.env`, `compose/green/.env`) — DOCKER_IMAGE variable, MONGO_URL
- STATE.md — accumulated context, locked decisions, EC2 host and ports
- ROADMAP.md — Phase 2 plan structure, 2 plans (02-01, 02-02), success criteria
- REQUIREMENTS.md — BG-03, BG-04, BG-10, BG-13, BG-14 requirement definitions

### Secondary (MEDIUM confidence)
- BG-03 "up to 60s" polling window — directly from REQUIREMENTS.md, not externally verified
- `nginx -s reload` zero-downtime guarantee — standard Nginx behavior, verified via Nginx documentation

### Tertiary (LOW confidence)
- None — all key facts sourced from Phase 1 completed work

---

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — bash/SSH/Docker Compose/Nginx are all confirmed in use by Phase 1
- Architecture: HIGH — script patterns derived directly from existing Phase 1 scripts
- Pitfalls: HIGH — all pitfalls identified from real failure modes in SSH-based deployment orchestration

**Research date:** 2026-04-01
**Valid until:** 2026-05-01 (stable domain, no external API changes expected)
