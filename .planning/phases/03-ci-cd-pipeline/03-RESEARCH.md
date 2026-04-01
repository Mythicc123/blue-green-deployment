# Phase 3: CI/CD Pipeline - Research

**Researched:** 2026-04-01
**Domain:** GitHub Actions CI/CD pipeline, blue-green deployment automation, Docker Hub image publishing
**Confidence:** HIGH (rooted in existing project artifacts and confirmed multi-container-service patterns)

---

## Summary

Phase 3 automates the blue-green deployment pipeline that was manually executed in Phase 2 via `scripts/run-deploy.sh`. The GitHub Actions workflow lives in `.github/workflows/deploy.yml`, triggers on push to `main`, and orchestrates: determine active slot, pull Docker image with immutable SHA tag, deploy to inactive slot, health-check, Nginx switch, and smoke test. Two concurrency mechanisms work together: GitHub Actions `concurrency` groups (cancels in-flight runs) and an EC2-side lock file at `/tmp/blue-green-deploy.lock` (prevents CI colliding with manual runs). The pipeline is intentionally simple: a single `deploy` job using `appleboy/ssh-action` to run the same shell logic that `run-deploy.sh` uses, just with injected environment variables instead of local files.

---

## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| BG-06 | Automated pipeline on push to main — determine active slot, deploy to inactive, health check, Nginx switch, smoke test | Pipeline step sequence, `appleboy/ssh-action`, SSH heredoc pattern |
| BG-07 | Immutable Docker image tags — git SHA (e.g., `v1.0.0-sha-abc1234`), never `latest` | `docker/build-push-action` with `${{ github.sha }}` tag, metadata action, Docker Hub tag format |
| BG-08 | Concurrency lock — GitHub Actions concurrency group + deployment lock file on EC2 | `concurrency:` YAML block, EC2 lock file via SSH `mkdir` + `ls` check |
| BG-09 | Smoke test after switch — call Todo API endpoints (GET/POST/PUT/DELETE) via public IP | `curl` commands in SSH step, Todo API endpoint inventory |

---

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| `appleboy/ssh-action` | v0.40.0 (2024-08) | Execute remote SSH commands on EC2 | De facto standard for GitHub Actions SSH; handles key injection, timeout, and multiple commands cleanly |
| `docker/setup-buildx-action` | v3 | Docker buildx for multi-platform image builds | Required for `docker/build-push-action`; cache-from GHA support |
| `docker/login-action` | v3 | Authenticate to Docker Hub | Required for pushing to private or org Docker Hub repos |
| `docker/metadata-action` | v5 | Generate Docker tags from git metadata | Produces `${{ github.sha }}` and `latest` tags; integrates with build-push |
| `docker/build-push-action` | v6 | Build and push Docker image | Industry standard; supports `cache-from: type=gha`, multi-tag, provenance |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| `actions/checkout` | v4 | Checkout repository for workflow access | Always — needed for `GITHUB_SHA` context |
| `docker/setup-qemu-action` | v3 | QEMU for multi-platform builds | Only if building ARM64 images alongside AMD64 |

**Installation:**
No install step needed — these are GitHub Actions marketplace actions referenced by `uses:` in the workflow YAML. No `npm install` or similar.

---

## Architecture Patterns

### Recommended Project Structure
```
blue-green-deployment/
├── .github/
│   └── workflows/
│       └── deploy.yml          # CI/CD pipeline (NEW)
├── compose/
│   ├── blue/
│   │   └── docker-compose.yml  # Already exists
│   └── green/
│       └── docker-compose.yml  # Already exists
├── scripts/
│   ├── deploy.sh              # Phase 2 reference
│   ├── health-check.sh        # Phase 2 reference
│   ├── switch-nginx.sh        # Phase 2 reference
│   └── run-deploy.sh          # Phase 2 orchestrator — mirror this logic in deploy.yml
└── .env.blue.template         # NEW — for GitHub Actions to inject DOCKER_IMAGE
```

### Pattern 1: Single-Job Pipeline with SSH Orchestration

The pipeline is a single `deploy` job. All "steps" (determine slot, deploy, health check, switch, smoke test) run as remote shell commands via `appleboy/ssh-action`. This mirrors the Phase 2 `run-deploy.sh` pattern exactly, just executed from GitHub Actions instead of a local machine.

**Why single job:** Blue-green deploy is inherently sequential (deploy then health-check then switch then smoke-test). Parallelism would add complexity without benefit. The `concurrency` block handles cancellation of redundant runs.

**When to split into multiple jobs:** Only if you need to run Docker build in a separate job (requires checkout + build-push before deploy). But for this project, Docker images are built by the **multi-container-service** pipeline (`C:\Users\fiefi\multi-container-service\.github\workflows\deploy.yml` lines 70-79), which pushes `${{ github.sha }}` tags to Docker Hub. The blue-green pipeline only pulls and deploys.

**Critical requirement:** The `DOCKER_IMAGE` value passed to SSH must include the git SHA tag that matches what was pushed by multi-container-service. The convention is:
```
DOCKER_IMAGE=<docker_username>/multi-container-service:<github_sha>
```

Example: `mythicc123/multi-container-service:a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2`

### Pattern 2: Docker Image Tagging (BG-07)

**Source:** multi-container-service `.github/workflows/deploy.yml` lines 70-79
```yaml
- name: Build and push Docker image
  uses: docker/build-push-action@v6
  with:
    context: ./app
    push: true
    tags: |
      ${{ secrets.DOCKER_USERNAME }}/multi-container-service:latest
      ${{ secrets.DOCKER_USERNAME }}/multi-container-service:${{ github.sha }}
    cache-from: type=gha
    cache-to: type=gha,mode=max
```

The blue-green pipeline does NOT rebuild the image. It pulls `...:<github_sha>` from Docker Hub. This is correct because:
1. The multi-container-service CI already builds and pushes on every push to main (its own `main` branch)
2. Blue-green pipeline runs on its own `main` push — the SHA refers to the blue-green repo commit, but the image is built from multi-container-service
3. **Risk:** If blue-green and multi-container-service are out of sync, the SHA tag may not exist on Docker Hub yet

**Resolution for SHA tag mismatch:**
The blue-green pipeline should use `${{ github.sha }}` for its own image tag convention. But the image it pulls must match what multi-container-service pushed. The safest approach:
- Blue-green pipeline pushes its own image with its own SHA tag to Docker Hub
- Both pipelines use the same tag: `${{ github.sha }}`
- The blue-green pipeline can push the image in the same job (no separate job needed since no tests run first)

**Recommended image tagging in blue-green deploy.yml:**
```yaml
# Build and push with immutable SHA tag
- name: Build and push Docker image
  uses: docker/build-push-action@v6
  with:
    context: ../multi-container-service/app   # relative path from blue-green repo root
    dockerfile: ../multi-container-service/app/Dockerfile
    push: true
    tags: |
      ${{ secrets.DOCKER_USERNAME }}/multi-container-service:${{ github.sha }}
    cache-from: type=gha
    cache-to: type=gha,mode=max
```

**Important path consideration:** The `context` and `dockerfile` paths must be relative to the checkout root. Since blue-green-deploy is a separate repo from multi-container-service, the Dockerfile must either be cloned into blue-green or the pipeline must clone both repos. **Best practice: copy the Dockerfile into the blue-green repo** (`app/Dockerfile`) or use the multi-container-service repo URL as part of the checkout if both repos are owned by the same account.

**Alternative (simpler):** Keep Dockerfile in blue-green repo at `app/Dockerfile`. On each push to multi-container-service, trigger blue-green pipeline via `repository_dispatch` event (with `client_payload` containing the image SHA). This decouples the two pipelines.

### Pattern 3: Concurrency Control (BG-08)

**Two layers of protection:**

**Layer 1: GitHub Actions built-in concurrency**
```yaml
concurrency:
  group: blue-green-deploy
  cancel-in-progress: true
```
- `cancel-in-progress: true` cancels any in-flight run when a new push arrives
- The concurrency group name `blue-green-deploy` groups all runs under one bucket
- This handles the CI-vs-CI race (two rapid pushes)

**Layer 2: EC2 lock file**
```bash
# Acquire lock
ssh $SSH_OPTS -i "$SSH_KEY" ubuntu@$HOST \
  "mkdir /tmp/blue-green-deploy.lock && echo $$ > /tmp/blue-green-deploy.lock/lock.pid" \
  || { echo "Deploy already in progress"; exit 1; }

# ... deployment steps ...

# Release lock
ssh $SSH_OPTS -i "$SSH_KEY" ubuntu@$HOST \
  "rm -rf /tmp/blue-green-deploy.lock"
```
- Uses `mkdir` as an atomic lock acquisition primitive (mkdir fails if directory exists)
- The lock PID is written for human debugging
- `|| exit 1` makes lock acquisition failure fatal
- Lock is released even on failure via `finally`-equivalent pattern (separate step that always runs)

**Shell `set -euo pipefail` consideration:** In the SSH heredoc, `set -e` means any failed command exits. The lock acquisition must succeed. The lock release should also succeed or be ignored.

### Pattern 4: Smoke Test Sequence (BG-09)

**Public IP smoke test** — runs AFTER Nginx switch, targeting the public IP on port 80 (via Nginx):
```bash
# Wait for Nginx to settle
sleep 5

# GET /todos
curl -sf "http://$PUBLIC_IP/todos" | grep -q '^\[' && echo "GET /todos: OK"

# POST /todos
RESPONSE=$(curl -sf -X POST "http://$PUBLIC_IP/todos" \
  -H "Content-Type: application/json" \
  -d '{"title":"ci-test-todo","completed":false}')
echo "$RESPONSE" | grep -q '"title":"ci-test-todo"' && echo "POST /todos: OK"

# Extract todo ID for PUT/DELETE
TODO_ID=$(echo "$RESPONSE" | grep -o '"_id":"[^"]*"' | cut -d'"' -f4)
if [[ -n "$TODO_ID" ]]; then
  # PUT /todos/:id
  curl -sf -X PUT "http://$PUBLIC_IP/todos/$TODO_ID" \
    -H "Content-Type: application/json" \
    -d '{"title":"ci-test-todo-updated","completed":true}' \
    | grep -q '"completed":true' && echo "PUT /todos/$TODO_ID: OK"

  # DELETE /todos/:id
  curl -sf -X DELETE "http://$PUBLIC_IP/todos/$TODO_ID" && echo "DELETE /todos/$TODO_ID: OK"
fi
```

**All curl calls use `-sf`** to suppress progress and fail silently (no verbose output). Pipe to `|| exit 1` for proper CI failure.

### Pattern 5: SSH Key Injection (appleboy/ssh-action)

**Source:** `appleboy/ssh-action` v0.40.0 documentation
```yaml
- name: Deploy to EC2
  uses: appleboy/ssh-action@v0.40.0
  with:
    host: ${{ vars.EC2_HOST }}
    username: ubuntu
    key: ${{ secrets.EC2_SSH_PRIVATE_KEY }}
    script: |
      set -euo pipefail
      echo "Running on $(hostname)"
      # deployment commands
    envs: DOCKER_IMAGE,INACTIVE_SLOT,PORT
    debug: ${{ vars.SSH_DEBUG == 'true' }}
```

**Important attributes:**
- `key:` accepts the raw private key content (not a file path) — pass via GitHub secret
- `script:` is a single multiline string; each line runs in the same shell session
- `envs:` exposes workflow environment variables into the remote shell
- `timeout:` defaults to 10 minutes; blue-green deploy should need < 5 minutes
- `command:` is alternative to `script:`; `script:` is preferred for multiline

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| SSH execution | Custom curl-to-SSH-API | `appleboy/ssh-action` | Handles key injection, timeout, retry, and script quoting correctly |
| Docker build/push | `docker build && docker push` in `run:` step | `docker/build-push-action` | Handles cache-from GHA, multi-tag, layer push, and output formatting |
| Docker metadata | Manual string concatenation | `docker/metadata-action` | Produces consistent tags from git events; handles semver, raw, and sha formats |
| Concurrent deploys | Only GitHub Actions concurrency | Both `concurrency:` + EC2 lock file | CI-vs-manual races need EC2-level protection |
| Concurrency lock | Custom file with `flock` | `mkdir`-as-lock | Atomic, no race between test-and-create |

---

## Common Pitfalls

### Pitfall 1: Lock file not released on failure
**What goes wrong:** If the SSH step fails mid-deploy, the lock file is left on EC2 and subsequent runs (manual or CI) will block forever.
**How to avoid:** Always release the lock in a separate `appleboy/ssh-action` step that runs even when the deploy step fails. In GitHub Actions, use `if: always()` on the lock-release step:
```yaml
- name: Release deployment lock
  if: always()
  uses: appleboy/ssh-action@v0.40.0
  with:
    host: ${{ vars.EC2_HOST }}
    username: ubuntu
    key: ${{ secrets.EC2_SSH_PRIVATE_KEY }}
    script: rm -rf /tmp/blue-green-deploy.lock
```

### Pitfall 2: Image SHA tag does not exist on Docker Hub
**What goes wrong:** Blue-green pipeline pulls `...:<sha>` that multi-container-service has not yet pushed. Race condition: multi-container-service build runs slower than blue-green deploy.
**How to avoid:** Add a `docker pull` with retry loop before deploying:
```bash
for i in 1 2 3 4 5; do
  if docker pull "$DOCKER_IMAGE"; then
    break
  fi
  echo "Pull failed, retry $i..."
  sleep 10
done
```
Or: have the multi-container-service pipeline trigger blue-green via `repository_dispatch` only after successful image push.

### Pitfall 3: SSH heredoc with local variable expansion
**What goes wrong:** Variables like `$inactive_slot` in the heredoc are expanded locally before being sent to remote.
**How to avoid:** Use `'REMOTE'` (quoted delimiter) so that variables are NOT expanded locally, and pass values as arguments (`"$1"`, `"$2"`). Phase 2 scripts already do this correctly. Reference: `deploy.sh` line 32 and `switch-nginx.sh` line 21.
**In `appleboy/ssh-action`:** Variables are injected via `envs:` and referenced directly in `script:`. Do NOT use heredocs with appleboy — use direct shell variable references.

### Pitfall 4: `latest` tag used instead of SHA
**What goes wrong:** `docker pull mythicc123/multi-container-service:latest` may pull a stale image from a previous deploy, not the current commit.
**How to avoid:** Always use `${{ github.sha }}` as the tag. `latest` can be pushed separately for convenience but is never used by the deploy pipeline.

### Pitfall 5: Smoke test fires before Nginx has reloaded
**What goes wrong:** Nginx `reload` is near-instant, but not zero-latency. First smoke test request may hit the old backend.
**How to avoid:** Add `sleep 5` between the Nginx switch step and the smoke test. Reference: `run-deploy.sh` line 54 already does this.

### Pitfall 6: Concurrency group cancellation during active deploy
**What goes wrong:** Push B arrives while Push A's deploy is in progress. Push A's run is cancelled, but Push A's EC2 operations may continue briefly (cancellation is async).
**How to avoid:** The EC2 lock file (`/tmp/blue-green-deploy.lock`) prevents Push B from starting while Push A holds the lock. The lock acquisition will fail for Push B until Push A releases it (or times out). This is the correct defense-in-depth pattern.

---

## Code Examples

### deploy.yml — Complete Pipeline Structure
```yaml
# .github/workflows/deploy.yml
name: Deploy

on:
  push:
    branches: [main]

# BG-08: Concurrency lock — cancels in-flight runs
concurrency:
  group: blue-green-deploy
  cancel-in-progress: true

env:
  DOCKER_IMAGE: ${{ secrets.DOCKER_USERNAME }}/multi-container-service:${{ github.sha }}

jobs:
  deploy:
    name: Blue-Green Deploy
    runs-on: ubuntu-latest

    steps:
      - uses: actions/checkout@v4

      # BG-07: Build and push immutable SHA-tagged image
      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Login to Docker Hub
        uses: docker/login-action@v3
        with:
          username: ${{ secrets.DOCKER_USERNAME }}
          password: ${{ secrets.DOCKER_PASSWORD }}

      # Build from multi-container-service Dockerfile path
      - name: Build and push Docker image
        uses: docker/build-push-action@v6
        with:
          context: ./app                    # or path to Dockerfile in this repo
          push: true
          tags: |
            ${{ env.DOCKER_IMAGE }}
          cache-from: type=gha
          cache-to: type=gha,mode=max

      # BG-08: Acquire EC2 lock
      - name: Acquire deployment lock
        uses: appleboy/ssh-action@v0.40.0
        with:
          host: ${{ vars.EC2_HOST }}
          username: ubuntu
          key: ${{ secrets.EC2_SSH_PRIVATE_KEY }}
          script: |
            set -euo pipefail
            if mkdir /tmp/blue-green-deploy.lock 2>/dev/null; then
              echo $$ > /tmp/blue-green-deploy.lock/lock.pid
              echo "Lock acquired: $(cat /tmp/blue-green-deploy.lock/lock.pid)"
            else
              echo "ERROR: Lock already held"
              exit 1
            fi
        envs: DOCKER_IMAGE
        timeout: 30s

      # BG-06: Determine active slot and deploy to inactive
      - name: Deploy to inactive slot
        uses: appleboy/ssh-action@v0.40.0
        with:
          host: ${{ vars.EC2_HOST }}
          username: ubuntu
          key: ${{ secrets.EC2_SSH_PRIVATE_KEY }}
          script: |
            set -euo pipefail
            # Determine active slot
            ACTIVE=$(cat /var/run/blue-green-state 2>/dev/null || echo blue)
            if [[ "$ACTIVE" == "blue" ]]; then
              INACTIVE=green; PORT=3002
            else
              INACTIVE=blue; PORT=3001
            fi
            echo "Active: $ACTIVE, Deploying to: $INACTIVE (port $PORT)"

            # Update .env with new image tag and deploy
            cd /opt/$INACTIVE
            sed -i "s|DOCKER_IMAGE=.*|DOCKER_IMAGE=${DOCKER_IMAGE}|" .env
            docker compose pull
            docker compose up -d
            echo "Deployed $INACTIVE"
        envs: DOCKER_IMAGE
        timeout: 300s

      # BG-06: Health check inactive slot
      - name: Health check
        uses: appleboy/ssh-action@v0.40.0
        with:
          host: ${{ vars.EC2_HOST }}
          username: ubuntu
          key: ${{ secrets.EC2_SSH_PRIVATE_KEY }}
          script: |
            set -euo pipefail
            ACTIVE=$(cat /var/run/blue-green-state 2>/dev/null || echo blue)
            if [[ "$ACTIVE" == "blue" ]]; then INACTIVE=green; PORT=3002
            else INACTIVE=blue; PORT=3001; fi

            echo "Health checking port $PORT..."
            for i in $(seq 1 20); do
              if curl -sf "http://localhost:$PORT/health" | grep -q '"status":"ok"'; then
                echo "PASS: Healthy after $((i * 3))s"
                exit 0
              fi
              echo "  [$((i * 3))s] Not ready..."
              sleep 3
            done
            echo "FAIL: Health check timed out"
            exit 1
        timeout: 120s

      # BG-06: Switch Nginx to new slot
      - name: Switch Nginx
        uses: appleboy/ssh-action@v0.40.0
        with:
          host: ${{ vars.EC2_HOST }}
          username: ubuntu
          key: ${{ secrets.EC2_SSH_PRIVATE_KEY }}
          script: |
            set -euo pipefail
            ACTIVE=$(cat /var/run/blue-green-state 2>/dev/null || echo blue)
            if [[ "$ACTIVE" == "blue" ]]; then TARGET=green; else TARGET=blue; fi

            echo "Switching to $TARGET..."
            sudo ln -sf /etc/nginx/sites-available/blue-green-${TARGET}.conf \
                        /etc/nginx/sites-enabled/blue-green
            sudo nginx -t
            sudo nginx -s reload
            echo "$TARGET" | sudo tee /var/run/blue-green-state > /dev/null
            echo "Switched to $TARGET"
        timeout: 60s

      # BG-09: Smoke test via public IP
      - name: Smoke test
        uses: appleboy/ssh-action@v0.40.0
        with:
          host: ${{ vars.EC2_HOST }}
          username: ubuntu
          key: ${{ secrets.EC2_SSH_PRIVATE_KEY }}
          script: |
            set -euo pipefail
            PUBLIC_IP="13.236.205.122"  # or read from var
            echo "Waiting for Nginx to settle..."
            sleep 5

            echo "Testing GET /todos..."
            curl -sf "http://$PUBLIC_IP/todos" | grep -q '^\[' && echo "GET /todos: OK"

            echo "Testing POST /todos..."
            RESPONSE=$(curl -sf -X POST "http://$PUBLIC_IP/todos" \
              -H "Content-Type: application/json" \
              -d '{"title":"ci-smoke-test","completed":false}')
            echo "$RESPONSE" | grep -q '"title":"ci-smoke-test"' && echo "POST /todos: OK"

            TODO_ID=$(echo "$RESPONSE" | grep -o '"_id":"[^"]*"' | head -1 | cut -d'"' -f4)
            if [[ -n "$TODO_ID" ]]; then
              echo "Testing PUT /todos/$TODO_ID..."
              curl -sf -X PUT "http://$PUBLIC_IP/todos/$TODO_ID" \
                -H "Content-Type: application/json" \
                -d '{"title":"ci-smoke-updated","completed":true}' \
                | grep -q '"completed":true' && echo "PUT /todos/$TODO_ID: OK"

              echo "Testing DELETE /todos/$TODO_ID..."
              curl -sf -X DELETE "http://$PUBLIC_IP/todos/$TODO_ID" && echo "DELETE /todos/$TODO_ID: OK"
            fi
        envs: DOCKER_IMAGE
        timeout: 120s

      # BG-08: Release lock — always runs, even on failure
      - name: Release deployment lock
        if: always()
        uses: appleboy/ssh-action@v0.40.0
        with:
          host: ${{ vars.EC2_HOST }}
          username: ubuntu
          key: ${{ secrets.EC2_SSH_PRIVATE_KEY }}
          script: |
            rm -rf /tmp/blue-green-deploy.lock
            echo "Lock released"
        timeout: 30s
```

---

## Environment Availability

> Step 2.6: SKIPPED — no external tool dependencies beyond GitHub Actions marketplace actions (all downloaded at runtime). No local tool installation required.

---

## Validation Architecture

> Skip this section if `workflow.nyquist_validation` is explicitly `false` in `.planning/config.json`.

**Status:** `nyquist_validation` key absent from `.planning/config.json` — validation section is included.

### Test Framework
| Property | Value |
|----------|-------|
| Framework | Shell script + curl (manual verification) |
| Config file | None |
| Quick run command | `GITHUB_REF=refs/heads/main GITHUB_SHA=$(git rev-parse HEAD) act -j deploy` (with `act`) |
| Full suite command | Manual push to `main` branch |

### Phase Requirements to Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| BG-06 | Pipeline runs full deploy-to-switch cycle | Integration | Push to `main` branch | `.github/workflows/deploy.yml` — CREATE |
| BG-07 | Docker image tagged with SHA, not `latest` | Assertion | `grep "github.sha" .github/workflows/deploy.yml` | YES after creation |
| BG-08 | Lock file acquired before deploy, released after | Unit | Check lock step presence + `if: always()` | YES after creation |
| BG-09 | All 4 Todo API endpoints return 2xx | Integration | Push to `main` branch (live smoke test) | YES after creation |

### Wave 0 Gaps
- `.github/workflows/deploy.yml` — the pipeline file itself (the primary artifact)
- `.github/workflows/ci.yml` — optional: run tests before deploy (if Node.js app tests exist in blue-green repo)
- `app/Dockerfile` — if image building is done in blue-green repo, needs Dockerfile copy
- Secrets to create in GitHub repo settings: `DOCKER_USERNAME`, `DOCKER_PASSWORD`, `EC2_SSH_PRIVATE_KEY`
- Vars to create in GitHub repo settings: `EC2_HOST` (= `13.236.205.122`), `AWS_REGION` (= `ap-southeast-2`)

*(If no gaps: "None — existing test infrastructure covers all phase requirements")*

---

## Open Questions

1. **Where does the Dockerfile live for blue-green pipeline builds?**
   - What we know: multi-container-service has `app/Dockerfile`. Blue-green is a separate repo.
   - What's unclear: Should blue-green pipeline build the image itself (needs Dockerfile in blue-green repo), or should it rely entirely on multi-container-service's pipeline pushing images?
   - Recommendation: **Option A (recommended):** Copy `app/Dockerfile` from multi-container-service into `blue-green-deployment/app/Dockerfile`. Blue-green pipeline builds and pushes with its own `${{ github.sha }}`. Option B: Decouple with `repository_dispatch` event. Option A is simpler for v1.

2. **Should the blue-green pipeline also run application tests before deploying?**
   - What we know: multi-container-service has a CI pipeline (`.github/workflows/ci.yml`) that runs `npm test`. Blue-green deploys the same app.
   - What's unclear: Should blue-green have its own test step, or rely on multi-container-service's tests?
   - Recommendation: Blue-green pipeline should NOT re-run tests. Rely on multi-container-service's test suite. Blue-green deploys proven images. Adding tests here would duplicate CI.

3. **How does the blue-green pipeline get the correct image SHA when both repos push to the same Docker Hub repo?**
   - What we know: Both pipelines push to `mythicc123/multi-container-service:<sha>`. The SHA must match the commit being deployed.
   - What's unclear: If blue-green pushes its own image with its own SHA, the image content reflects blue-green repo code. If blue-green pulls multi-container-service's SHA, the image reflects multi-container-service repo code.
   - Recommendation: Blue-green pipeline should build from its own Dockerfile with its own SHA. This ensures the deployed code matches the blue-green commit. The multi-container-service and blue-green pipelines remain loosely coupled via Docker Hub — each pushes its own SHA.

---

## Sources

### Primary (HIGH confidence)
- `C:\Users\fiefi\multi-container-service\.github\workflows\deploy.yml` — Docker build-push, SSH key injection, AWS credentials, workflow structure — **CONFIRMED PROJECT PATTERN**
- `C:\Users\fiefi\multi-container-service\.github\workflows\ci.yml` — Docker metadata, buildx, login-action patterns — **CONFIRMED PROJECT PATTERN**
- `C:\Users\fiefi\blue-green-deployment\scripts\deploy.sh` — SSH heredoc pattern, slot detection, port mapping — **CONFIRMED DEPLOY LOGIC**
- `C:\Users\fiefi\blue-green-deployment\scripts\switch-nginx.sh` — Nginx switch via SSH, state file update — **CONFIRMED SWITCH LOGIC**
- `C:\Users\fiefi\blue-green-deployment\scripts\health-check.sh` — Health polling via SSH curl — **CONFIRMED HEALTH LOGIC**
- `C:\Users\fiefi\blue-green-deployment\scripts\run-deploy.sh` — Full orchestrator pattern — **CONFIRMED PIPELINE SEQUENCE**
- GitHub `appleboy/ssh-action` v0.40.0 — SSH execution marketplace action — **TRAINING DATA (verified via README patterns)**

### Secondary (MEDIUM confidence)
- GitHub Actions `concurrency` block documentation — standard YAML configuration
- `docker/metadata-action@v5` tag generation — standard marketplace action

### Tertiary (LOW confidence)
- Exact version numbers for appleboy/ssh-action v0.40.0 — training data, verify against GitHub marketplace
- Exact image tag format used by multi-container-service pipeline — confirmed from deploy.yml but SHA format was not inspected

---

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — rooted in verified multi-container-service workflow files
- Architecture: HIGH — mirrors Phase 2 `run-deploy.sh` which is tested
- Pitfalls: MEDIUM — identified from common GitHub Actions + SSH deployment patterns, not from project-specific failure modes yet

**Research date:** 2026-04-01
**Valid until:** 2026-05-01 (GitHub Actions syntax is stable; appleboy/ssh-action releases quarterly)
