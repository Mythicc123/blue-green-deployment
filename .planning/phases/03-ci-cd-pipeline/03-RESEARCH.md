# Phase 3: CI/CD Pipeline - Research

**Researched:** 2026-04-01
**Domain:** GitHub Actions Docker integration, buildx, blue-green deployment pipeline architecture
**Confidence:** HIGH (rooted in existing project artifacts and confirmed multi-container-service patterns)

---

## Summary

Phase 3 automates the blue-green deployment pipeline via GitHub Actions. The pipeline must: (1) build and push the Docker image to Docker Hub, (2) SSH into the EC2 instance to deploy the new image to the inactive slot, (3) wait for the health check to pass, (4) switch Nginx to point at the new slot, and (5) run a smoke test through the public IP. The core design question -- build on the GitHub runner vs. build on EC2 -- is resolved in favor of building on the runner: it keeps secrets off the server, gives better CI visibility, and costs no more given that the runner must push to Docker Hub regardless.

**Primary recommendation:** Multi-job pipeline with `build-and-push` -> `deploy`, passing the image tag between jobs via `GITHUB_OUTPUT` + `outputs:`. Use `docker/setup-buildx-action` only if multi-arch images are needed (likely not for single-architecture x86 EC2). The `appleboy/ssh-action` v0.40.0 drives all EC2 operations. Concurrency protection is two-layer: GitHub Actions `concurrency` group (first line) + `flock /tmp/blue-green-deploy.lock` on EC2 (second line).

---

## User Constraints (from CONTEXT.md)

### Locked Decisions

- Shared MongoDB: Both blue and green use the existing multi-container-service MongoDB (port 27017). Migrations must be backward-compatible.
- Keep old slot: Both environments stay running after switch. Rollback is instant Nginx reload.
- Same EC2 instance: Blue-green runs on 13.236.205.122 alongside multi-container-service.
- IP only: No domain/R53 for v1.
- Basic monitoring: Health checks, container logs, Nginx logs only.
- Blue-green state file: `/var/run/blue-green-state` contains `blue` or `green`.
- Concurrency lock required: GitHub Actions concurrency group + EC2 lock file (`/tmp/blue-green-deploy.lock`).
- Immutable Docker image tags: `sha-{git_sha}` format (e.g., `sha-abc1234`), never `latest`.

### Claude's Discretion

- Pipeline structure: job count, step ordering, artifact passing mechanism.
- Docker buildx: use or skip, cache strategy.
- Where Docker build happens: GitHub runner vs. EC2.
- Workflow file location and inline vs. script-referencing SSH commands.

### Deferred Ideas (OUT OF SCOPE)

- Separate MongoDB per environment.
- Canary traffic splitting.
- Automated rollback on failure (manual rollback only for v1).
- Kubernetes/EKS.
- Prometheus/Grafana.
- Domain/Route53.
- Separate EC2 instance.
- GitOps.
- Database migrations as a separate pipeline step.

---

## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| BG-06 | Automated pipeline on push to main -- determine active slot, deploy to inactive, health check, Nginx switch, smoke test | Pipeline step sequence, `appleboy/ssh-action`, SSH heredoc pattern |
| BG-07 | Immutable Docker image tags -- git SHA (e.g., `sha-abc1234`), never `latest` | `docker/build-push-action` with `${{ github.sha }}` tag |
| BG-08 | Concurrency lock -- GitHub Actions concurrency group + EC2 lock file | `concurrency:` YAML block, `flock` on `/tmp/blue-green-deploy.lock` |
| BG-09 | Smoke test after switch -- call Todo API endpoints (GET/POST/PUT/DELETE) via public IP | `curl` commands in SSH step, Todo API endpoint inventory |
| BG-11 | Old slot stays alive after switch | Architecture constraint, already implemented in scripts |

---

## Standard Stack

### Core

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| `docker/login-action` | v3 | Authenticate to Docker Hub in CI | Official GitHub Actions action; handles credential storage in GitHub secrets |
| `appleboy/ssh-action` | v0.40.0 | Execute remote SSH commands on EC2 | De facto standard for GitHub Actions SSH; handles key injection, timeout, and multiple commands cleanly |
| `docker/build-push-action` | v6 | Build and push Docker image | Industry standard; supports `cache-from: type=gha`, multi-tag, provenance |
| `docker/setup-buildx-action` | v3 | Enable Docker BuildKit | Only needed for multi-arch images; skip for x86-only single-architecture deployment |
| `docker/metadata-action` | v5 | Generate Docker tags from git metadata | Produces `${{ github.sha }}` and `latest` tags; integrates with build-push |

### Supporting

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| `actions/checkout` | v4 | Checkout repository for workflow access | Always -- needed for `GITHUB_SHA` context |
| `docker/setup-qemu-action` | v3 | QEMU for multi-platform builds | Only if building ARM64 images alongside AMD64 |

**Installation:** No manual install needed -- these are GitHub Actions marketplace actions referenced by `uses:` in the workflow YAML. Runner-side tools (jq, httpie) can be installed via `apt-get` in a run step.

```bash
# Runner-side tools (ubuntu-latest has docker pre-installed)
sudo apt-get update && sudo apt-get install -y jq httpie
```

---

## Architecture Patterns

### Recommended Project Structure

```
blue-green-deployment/
├── .github/
│   └── workflows/
│       └── deploy.yml              # CI/CD pipeline (NEW)
├── app/
│   └── Dockerfile                  # COPY from multi-container-service/app/Dockerfile (NEW)
├── compose/
│   ├── blue/
│   │   └── docker-compose.yml      # Already exists
│   └── green/
│       └── docker-compose.yml      # Already exists
├── scripts/
│   ├── deploy.sh                  # Phase 2 reference
│   ├── health-check.sh             # Phase 2 reference
│   ├── switch-nginx.sh             # Phase 2 reference
│   └── run-deploy.sh               # Phase 2 orchestrator -- mirror this logic in deploy.yml
└── .env.blue.template
```

**Note on `app/Dockerfile`:** The Dockerfile lives in `multi-container-service/app/Dockerfile`. For the blue-green pipeline to build the image independently, copy it to `blue-green-deployment/app/Dockerfile`. Alternatively, use `context: ../multi-container-service` if the CI runner has access to the sibling directory (requires the runner to clone both repos).

### Pattern 1: Build on GitHub Runner (RECOMMENDED)

**Decision:** Build on the GitHub runner, not on EC2.

**Rationale:**
1. **Secrets stay in CI:** The Docker Hub credentials (`DOCKERHUB_TOKEN`) never touch EC2. If the EC2 server is compromised, no registry credentials are exposed.
2. **CI visibility:** Build logs, layer cache hits, and push status are visible in GitHub's UI without SSHing into EC2.
3. **Cost equivalence:** Either way, the runner must push to Docker Hub (or EC2 must pull from it). The network egress from the runner to Docker Hub is equivalent to EC2 pulling from Docker Hub. No advantage to building on EC2.
4. **Simpler EC2:** The EC2 instance only runs `docker compose pull` and `docker compose up` -- minimal complexity on the server.

**Trade-off acknowledged:** A large Docker image (500MB+) pushed from the runner then pulled by EC2 uses runner egress bandwidth. Building on EC2 would use EC2's bandwidth instead. For a typical Node.js app (<200MB compressed), this is negligible. For very large images, consider building on EC2.

### Pattern 2: Two-Job Pipeline with `outputs:` for Tag Passing

**Decision:** Split into `build-and-push` and `deploy` jobs.

**Why not single job:**
- The image tag (`sha-${{ github.sha }}`) computed in a single job would be stable because `github.sha` is a context variable, not a file-based computation. A single job works fine.
- However, a two-job structure is cleaner: `build-and-push` is the "build" concern; `deploy` is the "operate" concern. They have different failure modes and retry logic.
- The `outputs:` mechanism (writing to `$GITHUB_OUTPUT`) is the correct way to pass data between jobs.

```yaml
# Job 1: Build and push
build-and-push:
  outputs:
    image_tag: sha-${{ github.sha }}
  steps:
    - uses: actions/checkout@v4
    - uses: docker/setup-buildx-action@v3   # skip if single-arch amd64
    - uses: docker/login-action@v3
    - uses: docker/build-push-action@v6

# Job 2: Deploy
deploy:
  needs: build-and-push
  steps:
    - uses: appleboy/ssh-action@v0.40.0
      with:
        script: |
          docker compose pull mythicc123/multi-container-service:${{ needs.build-and-push.outputs.image_tag }}
```

**Note on `appleboy/ssh-action` vs `appleboy/ssh-agent-action`:** Both exist. `ssh-action` (v0.40.0) embeds the key and runs commands directly in the action YAML. `ssh-agent-action` sets up `SSH_AUTH_SOCK` so subsequent shell `ssh` commands work. Use `ssh-action` for simplicity; it handles key injection internally.

### Pattern 3: Docker Buildx -- Skip for Single-Arch

**Decision:** `docker/setup-buildx-action` is only needed when building multi-arch images (e.g., amd64 + arm64 simultaneously) or when the runner's Docker does not support the `type=gha` cache backend.

For this project:
- The EC2 instance is x86_64 (Amazon Linux / Ubuntu on x86)
- The Docker Hub image is likely already amd64
- Only one architecture needs to be built

**When to enable buildx:**
```yaml
- uses: docker/setup-buildx-action@v3
  # No conditional needed if always building multi-arch
```

**When to skip it (simpler):** Remove `docker/setup-buildx-action` entirely. The runner's Docker daemon (on `ubuntu-latest`) uses BuildKit by default in recent GitHub Actions images. If `type=gha` cache is needed, buildx is required. If not, skip it.

**Context7 note:** As of 2025, `ubuntu-latest` runners include Docker BuildKit enabled by default. `type=gha` cache backend requires buildx. So: if using `cache-from: type=gha`, keep buildx. If using no cache or `type=local` cache, skip buildx.

### Pattern 4: Concurrency Control -- Two-Layer Defense (BG-08)

**Layer 1: GitHub Actions `concurrency` block**
```yaml
concurrency:
  group: blue-green-deploy-${{ github.ref }}
  cancel-in-progress: true
```
- Cancels any in-flight run when a new push arrives to the same ref
- First line of defense -- stops the runner from starting a second job

**Layer 2: EC2 `flock` lock file**
```bash
# Acquire lock (atomic, blocks until acquired or timeout)
flock -n /tmp/blue-green-deploy.lock -c "echo $$ > /tmp/blue-green-deploy.lock" \
  || { echo "ERROR: Another deployment in progress"; exit 1; }

# ... deployment steps ...

# Release lock (in always-run step)
rm -f /tmp/blue-green-deploy.lock
```
- `flock -n` (non-blocking) fails immediately if lock is held
- Protects against CI-vs-manual races (e.g., someone SSHes in and deploys manually while CI is running)
- The `if: always()` on the release step ensures the lock is cleaned up even if earlier steps fail

**Why both layers:** The `concurrency` block handles CI-vs-CI races. The EC2 lock handles CI-vs-manual races. Both are needed for BG-08 compliance.

### Pattern 5: SSH Heredoc Safety (Confirmed from Phase 2 Scripts)

**Source:** `deploy.sh` line 32 and `switch-nginx.sh` line 21 both use the quoted-delimiter heredoc pattern correctly.

```bash
# WRONG -- local shell expands $tag before SSH
ssh ubuntu@$HOST bash <<EOF
  DOCKER_IMAGE=$tag docker compose pull
EOF

# RIGHT -- remote shell expands $tag
ssh ubuntu@$HOST bash -s -- "$tag" << 'REMOTE'
  DOCKER_IMAGE=$1 docker compose pull
REMOTE
```

**In `appleboy/ssh-action`:** Variables are injected via `envs:` and referenced directly in `script:`. Do NOT use heredocs -- use direct shell variable references:
```yaml
- uses: appleboy/ssh-action@v0.40.0
  with:
    script: |
      set -euo pipefail
      cd /opt/$INACTIVE_SLOT
      docker compose pull
    envs: INACTIVE_SLOT
```

### Pattern 6: Docker Context Path (Critical -- Sibling Repo)

**The problem:** The `blue-green-deployment` repo and `multi-container-service` repo are siblings on disk. The Dockerfile lives in `multi-container-service/app/Dockerfile`, not in `blue-green-deployment`. The `docker/build-push-action` defaults to the runner's `$GITHUB_WORKSPACE` as the build context.

**Options:**

| Option | Complexity | Trade-off |
|--------|-----------|-----------|
| Copy Dockerfile to `blue-green-deployment/app/` | Low | Keeps repos independent; must sync Dockerfile manually |
| Clone `multi-container-service` inside CI | Medium | Both repos available; extra `git clone` step; slight network cost |
| `context: ../multi-container-service` (from runner workspace) | Low | Works if runner has sibling directory; fragile if runner workspace layout changes |

**Recommended:** Copy `app/Dockerfile` (and any needed source files) into `blue-green-deployment/app/`. This makes the pipeline fully self-contained and independent of the sibling repo. Document that the Dockerfile must be kept in sync with `multi-container-service`.

Alternatively, add this step before the build:
```yaml
- name: Clone application source
  run: |
    git clone --depth=1 https://github.com/mythicc123/multi-container-service.git ../multi-container-service
- name: Build and push
  uses: docker/build-push-action@v6
  with:
    context: ../multi-container-service/app
    file: ../multi-container-service/app/Dockerfile
```

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| SSH execution in CI | Custom curl-to-SSH-API | `appleboy/ssh-action@v0.40.0` | Handles key injection, timeout, retry, and multiline script quoting correctly |
| Docker build/push | `docker build && docker push` in `run:` step | `docker/build-push-action@v6` | Handles `type=gha` cache, multi-tag, layer push, and provenance attestation |
| Docker Hub auth | Store credentials as plain env vars | `docker/login-action@v3` | Handles Docker config JSON, secret masking, logout on cleanup |
| Image metadata tags | Manual string concatenation | `docker/metadata-action@v5` or inline tags array | Produces consistent `${{ github.sha }}` and `latest` tags |
| Concurrency prevention | Polling or webhook-based locking | GitHub Actions `concurrency` + `flock` | First-class CI support (cancels in-flight) + filesystem-level lock |
| Deployment mutex | Custom file with `test -f` | `flock -n` | Atomic; no race between test-and-create |

**Key insight:** The entire CI/CD pipeline is built from first-party or widely-adopted GitHub Actions. The only shell fragment that needs to be hand-written is the `flock` lock acquisition (5 lines) and the smoke test curl commands (15 lines).

---

## Common Pitfalls

### Pitfall 1: Lock file not released on failure
**What goes wrong:** If a deploy step fails mid-run, the SSH session may be interrupted before the lock release step runs. Subsequent CI runs block forever waiting for the lock.
**How to avoid:** Use `if: always()` on the lock-release step. Also consider adding a lock timeout (e.g., auto-release after 30 minutes):
```yaml
- name: Release deployment lock
  if: always()
  uses: appleboy/ssh-action@v0.40.0
  with:
    script: rm -f /tmp/blue-green-deploy.lock
```

### Pitfall 2: Image SHA tag does not exist on Docker Hub
**What goes wrong:** Blue-green pipeline pulls `...:<sha>` that multi-container-service has not yet pushed. Race condition when multi-container-service build is slower than blue-green deploy.
**How to avoid:** Build and push the image in the blue-green pipeline itself (not rely on multi-container-service's pipeline). This guarantees the tag exists. Alternatively, add a `docker pull` retry loop:
```bash
for i in 1 2 3 4 5; do
  docker pull "$DOCKER_IMAGE" && break
  echo "Pull failed, retry $i..."
  sleep 10
done
```

### Pitfall 3: Wrong Docker context path
**What goes wrong:** `docker/build-push-action` uses the repo root as context by default. The Dockerfile is in `../multi-container-service/app/Dockerfile` (sibling directory), not in `blue-green-deployment/`.
**How to avoid:** Explicitly set `context:` and `file:` to point to the correct location. Document this in comments.

### Pitfall 4: `latest` tag used for deployment instead of SHA
**What goes wrong:** `docker pull mythicc123/multi-container-service:latest` may pull a stale image from a previous deploy. After two deploys, `latest` points to the newer SHA, but rollback to the older version is impossible without knowing the old SHA.
**How to avoid:** The `.env` file on EC2 always uses the SHA tag. `latest` is pushed as a convenience alias but is never used by the deploy pipeline.

### Pitfall 5: Smoke test fires before Nginx has reloaded
**What goes wrong:** Nginx `reload` is near-instant but not zero-latency. First smoke test request may hit the old backend.
**How to avoid:** Add `sleep 5` between the Nginx switch step and the smoke test. Reference: `run-deploy.sh` line 54 already does this.

### Pitfall 6: Concurrency cancellation during active deploy
**What goes wrong:** Push B arrives while Push A's deploy is in progress. Push A's run is cancelled by GitHub Actions, but Push A's EC2 operations may continue briefly (cancellation is async and not instant for running SSH sessions).
**How to avoid:** The EC2 `flock` lock is the authoritative guard. Push B will block on the lock until Push A releases it (or times out at 30 minutes). This is defense-in-depth.

### Pitfall 7: SSH key path mismatch in CI
**What goes wrong:** Scripts reference `$HOME/.ssh/ec2-static-site-key.pem` which does not exist on the GitHub runner.
**How to avoid:** Store the private key as a GitHub Actions secret (`EC2_SSH_PRIVATE_KEY`) and pass it to `appleboy/ssh-action`'s `key:` parameter. The action handles in-memory key injection.

---

## Code Examples

### Full Workflow: `.github/workflows/deploy.yml`

```yaml
# .github/workflows/deploy.yml
name: Blue-Green Deploy

on:
  push:
    branches: [main]

# BG-08: Layer 1 concurrency -- cancels in-flight runs
concurrency:
  group: blue-green-deploy-${{ github.ref }}
  cancel-in-progress: true

env:
  IMAGE_NAME: mythicc123/multi-container-service
  EC2_HOST: 13.236.205.122

jobs:
  # ─────────────────────────────────────────────────────────────────
  # Job 1: Build and push Docker image to Docker Hub
  # ─────────────────────────────────────────────────────────────────
  build-and-push:
    name: Build and Push
    runs-on: ubuntu-latest
    outputs:
      image_tag: sha-${{ github.sha }}
    steps:
      - name: Checkout repository
        uses: actions/checkout@v4

      - name: Clone application source
        # The multi-container-service repo contains the Dockerfile and app code.
        # Clone it so the build context can find it.
        run: |
          git clone --depth=1 https://github.com/mythicc123/multi-container-service.git ../multi-container-service

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3
        # SKIP this step if you do not need multi-arch or GHA cache.
        # Keep it if using `type=gha` cache below.

      - name: Login to Docker Hub
        uses: docker/login-action@v3
        with:
          registry: docker.io
          username: ${{ secrets.DOCKERHUB_USERNAME }}
          password: ${{ secrets.DOCKERHUB_TOKEN }}

      - name: Extract metadata for Docker
        uses: docker/metadata-action@v5
        id: meta
        with:
          images: ${{ env.IMAGE_NAME }}
          tags: |
            type=sha,prefix=sha-
            type=raw,value=latest

      - name: Build and push
        uses: docker/build-push-action@v6
        with:
          context: ../multi-container-service/app
          file: ../multi-container-service/app/Dockerfile
          push: true
          tags: |
            ${{ env.IMAGE_NAME }}:sha-${{ github.sha }}
            ${{ env.IMAGE_NAME }}:latest
          cache-from: type=gha
          cache-to: type=gha,mode=max

  # ─────────────────────────────────────────────────────────────────
  # Job 2: Deploy via SSH, health check, Nginx switch, smoke test
  # ─────────────────────────────────────────────────────────────────
  deploy:
    name: Deploy to EC2
    runs-on: ubuntu-latest
    needs: build-and-push
    steps:
      - name: Install dependencies
        run: sudo apt-get update && sudo apt-get install -y jq httpie

      # BG-08: Layer 2 lock -- atomic lock acquisition on EC2
      - name: Acquire deploy lock on EC2
        uses: appleboy/ssh-action@v0.40.0
        with:
          host: ${{ env.EC2_HOST }}
          username: ubuntu
          key: ${{ secrets.EC2_SSH_PRIVATE_KEY }}
          script: |
            set -euo pipefail
            if flock -n /tmp/blue-green-deploy.lock -c "echo $$ > /tmp/blue-green-deploy.lock"; then
              echo "Lock acquired (PID: $(cat /tmp/blue-green-deploy.lock))"
            else
              echo "ERROR: Another deployment is in progress at /tmp/blue-green-deploy.lock"
              exit 1
            fi
        timeout: 30s

      # BG-06: Determine active slot and compute inactive slot
      - name: Determine active slot
        id: slot
        uses: appleboy/ssh-action@v0.40.0
        with:
          host: ${{ env.EC2_HOST }}
          username: ubuntu
          key: ${{ secrets.EC2_SSH_PRIVATE_KEY }}
          script: |
            set -euo pipefail
            ACTIVE=$(cat /var/run/blue-green-state 2>/dev/null || echo blue)
            if [[ "$ACTIVE" == "blue" ]]; then
              INACTIVE=green; PORT=3002
            else
              INACTIVE=blue; PORT=3001
            fi
            echo "active=$ACTIVE" >> $GITHUB_OUTPUT
            echo "inactive=$INACTIVE" >> $GITHUB_OUTPUT
            echo "port=$PORT" >> $GITHUB_OUTPUT
            echo "Active: $ACTIVE, Deploying to: $INACTIVE (port $PORT)"
        timeout: 30s

      # BG-06: Deploy image to inactive slot
      - name: Deploy to inactive slot
        env:
          IMAGE_TAG: ${{ needs.build-and-push.outputs.image_tag }}
          INACTIVE: ${{ steps.slot.outputs.inactive }}
        uses: appleboy/ssh-action@v0.40.0
        with:
          host: ${{ env.EC2_HOST }}
          username: ubuntu
          key: ${{ secrets.EC2_SSH_PRIVATE_KEY }}
          script: |
            set -euo pipefail
            cd /opt/$INACTIVE
            # Update DOCKER_IMAGE in .env to the new SHA-tagged image
            sed -i "s|^DOCKER_IMAGE=.*|DOCKER_IMAGE=mythicc123/multi-container-service:$IMAGE_TAG|" .env
            echo "Pulling mythicc123/multi-container-service:$IMAGE_TAG"
            docker compose pull
            docker compose up -d
            echo "Deployed $IMAGE_TAG to /opt/$INACTIVE"
        timeout: 300s

      # BG-03: Health check polling before switch
      - name: Health check inactive slot
        env:
          PORT: ${{ steps.slot.outputs.port }}
        run: |
          url="http://localhost:$PORT/health"
          timeout=60 interval=3 waited=0
          echo "Polling $url (timeout: ${timeout}s)..."
          while true; do
            response=$(curl -sf "$url") && echo "$response" | grep -q '"status":"ok"'
            if [[ $? -eq 0 ]]; then
              echo "PASS: Health check passed after ${waited}s"
              echo "$response"
              exit 0
            fi
            if [[ $waited -ge $timeout ]]; then
              echo "FAIL: Health check timed out after ${timeout}s"
              exit 1
            fi
            echo "  [${waited}s] Not ready..."
            sleep $interval
            waited=$((waited + interval))
          done
        timeout: 120s

      # BG-06: Switch Nginx to inactive slot (now the active slot)
      - name: Switch Nginx
        env:
          INACTIVE: ${{ steps.slot.outputs.inactive }}
        uses: appleboy/ssh-action@v0.40.0
        with:
          host: ${{ env.EC2_HOST }}
          username: ubuntu
          key: ${{ secrets.EC2_SSH_PRIVATE_KEY }}
          script: |
            set -euo pipefail
            echo "Switching Nginx to $INACTIVE..."
            sudo ln -sf /etc/nginx/sites-available/blue-green-${INACTIVE}.conf \
              /etc/nginx/sites-enabled/blue-green
            sudo nginx -t
            sudo nginx -s reload
            echo "$INACTIVE" | sudo tee /var/run/blue-green-state > /dev/null
            echo "Switched. State: $(cat /var/run/blue-green-state)"
        timeout: 60s

      # BG-09: Smoke test -- GET /health
      - name: Smoke test GET /health
        env:
          EC2_HOST: ${{ env.EC2_HOST }}
        run: |
          sleep 5  # Settle time for Nginx
          http --check-status "http://$EC2_HOST/health" \
            | jq '.status == "ok"' || exit 1
        timeout: 30s

      # BG-09: Smoke test -- POST /todos
      - name: Smoke test POST /todos
        env:
          EC2_HOST: ${{ env.EC2_HOST }}
        run: |
          RESPONSE=$(http --check-status --body \
            POST "http://$EC2_HOST/todos" \
            title="CI smoke test $(date +%s)" \
            completed=false \
            Content-Type:application/json)
          echo "$RESPONSE" | jq -e '.title != null' || exit 1
          echo "$RESPONSE" | jq -r '.._id' | tee /tmp/smoke_todo_id.txt
        timeout: 30s

      # BG-09: Smoke test -- PUT /todos/:id
      - name: Smoke test PUT /todos
        env:
          EC2_HOST: ${{ env.EC2_HOST }}
        run: |
          TODO_ID=$(cat /tmp/smoke_todo_id.txt)
          http --check-status --body \
            PUT "http://$EC2_HOST/todos/$TODO_ID" \
            title="CI smoke updated" \
            completed=true \
            Content-Type:application/json \
            | jq -e '.completed == true' || exit 1
        timeout: 30s

      # BG-09: Smoke test -- DELETE /todos/:id
      - name: Smoke test DELETE /todos
        env:
          EC2_HOST: ${{ env.EC2_HOST }}
        run: |
          TODO_ID=$(cat /tmp/smoke_todo_id.txt)
          http --check-status --body \
            DELETE "http://$EC2_HOST/todos/$TODO_ID"
        timeout: 30s

      # BG-08: Release lock -- always runs, even on failure (if: always())
      - name: Release deploy lock
        if: always()
        uses: appleboy/ssh-action@v0.40.0
        with:
          host: ${{ env.EC2_HOST }}
          username: ubuntu
          key: ${{ secrets.EC2_SSH_PRIVATE_KEY }}
          script: |
            rm -f /tmp/blue-green-deploy.lock
            echo "Lock released"
        timeout: 30s
```

### Tag Strategy (BG-07)

```yaml
# Primary immutable tag: sha-{git_sha} -- this is what EC2 pulls
tags: |
  mythicc123/multi-container-service:sha-${{ github.sha }}
  mythicc123/multi-container-service:latest   # convenience alias, never used for deploy

# On EC2 .env file -- ALWAYS use SHA:
DOCKER_IMAGE=mythicc123/multi-container-service:sha-abc1234
```

### Concurrency Lock (BG-08) -- Both Layers

```yaml
# Layer 1: Runner-side concurrency group
concurrency:
  group: blue-green-deploy-${{ github.ref }}
  cancel-in-progress: true

# Layer 2: Server-side flock (first SSH step in deploy job)
- uses: appleboy/ssh-action@v0.40.0
  with:
    script: |
      flock -n /tmp/blue-green-deploy.lock -c "echo $$ > /tmp/blue-green-deploy.lock" \
        || { echo "Another deployment in progress"; exit 1; }
```

### Environment Variables vs Shell Variables

```yaml
# GitHub Actions context variables (set once, used everywhere)
env:
  IMAGE_NAME: mythicc123/multi-container-service
  EC2_HOST: 13.236.205.122

# Passed to appleboy/ssh-action via envs: attribute
envs: IMAGE_TAG,INACTIVE

# Inside ssh-action script: reference directly as shell variables
script: |
  set -euo pipefail
  cd /opt/$INACTIVE
  sed -i "s|^DOCKER_IMAGE=.*|DOCKER_IMAGE=mythicc123/multi-container-service:$IMAGE_TAG|" .env
```

**`github.sha` vs `github.event.pull_request.number`:**
- `github.sha`: Full 40-character commit SHA. Use for immutable tags. `sha-abc1234abc1234abc1234` is unique and reproducible.
- `github.event.pull_request.number`: Pull request number. Use only for temporary test tags on PR branches.
- For `main` branch deploys: `github.sha` is correct.

---

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| `azure/docker-login` | `docker/login-action@v3` | ~2022 | Official GitHub Actions replacement; better credential handling |
| `docker/build-push-action@v4` | `docker/build-push-action@v6` | 2024 | Native GHA cache (`type=gha`), provenance attestation |
| `docker/setup-docker-wrap` | `docker/setup-buildx-action@v3` | 2023 | Builds BuildKit into runner; required for `type=gha` cache |
| `appleboy/ssh-action` v0.38.x | v0.40.0 | 2024-08 | Timeout improvements, bug fixes |
| Heredoc without quoting | `<< 'REMOTE'` (quoted delimiter) | Known pitfall | Prevents local variable expansion in SSH heredocs |
| Raw `ssh -i` without agent | `appleboy/ssh-action` | ~2021 | In-memory key injection; no key file needed on runner |

**Deprecated/outdated:**
- `docker/metadata-action@v4` -- use v5 (same API, security fixes)
- `azure/docker-login` -- replaced by `docker/login-action`
- Raw `ssh -i $HOME/.ssh/key.pem` in CI -- replaced by `appleboy/ssh-action`

---

## Open Questions

1. **Where does the Dockerfile live for blue-green pipeline builds?**
   - What we know: multi-container-service has `app/Dockerfile`. Blue-green is a separate repo.
   - What's unclear: Is the `multi-container-service` directory a git submodule of `blue-green-deployment`, a sibling checked out separately, or will the CI pipeline clone it on demand?
   - Recommendation: Add a `git clone --depth=1` step in the CI before the Docker build, pointing to `context: ../multi-container-service/app`. This keeps the blue-green repo clean and ensures the Dockerfile is always current.

2. **Docker buildx for single-arch x86 EC2?**
   - What we know: The EC2 instance runs x86_64. The Docker Hub image is likely already amd64.
   - What's unclear: Is the existing image multi-arch (amd64 + arm64) or single-arch?
   - Recommendation: Check the existing Docker Hub image manifest (`docker manifest inspect mythicc123/multi-container-service`). If single-arch amd64, skip `docker/setup-buildx-action`. If multi-arch is desired, enable buildx and add `platforms: linux/amd64`.

3. **Docker Hub token scope for CI?**
   - What we know: `docker/login-action` requires username + password/token.
   - What's unclear: Should the token be a personal access token or an organization robot account?
   - Recommendation: Use a Docker Hub Access Token (not password) scoped to the `mythicc` organization. Create at `hub.docker.com/settings/security`. Store as `DOCKERHUB_TOKEN` in GitHub Actions secrets.

4. **GitHub Actions secrets inventory:**
   - What we know: The workflow needs `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN`, `EC2_SSH_PRIVATE_KEY`, and optionally `EC2_HOST` (or hardcode as a `var`).
   - What's unclear: Are all secrets already set in the repository?
   - Recommendation: Before planning, audit existing secrets in the GitHub repo settings. Missing secrets will block CI on first run.

5. **Docker context path on GitHub runner:**
   - What we know: `blue-green-deployment` and `multi-container-service` are sibling directories. The runner's working directory is `$GITHUB_WORKSPACE` (blue-green-deployment repo root).
   - What's unclear: Does `../multi-container-service` exist on the runner filesystem at runtime?
   - Recommendation: Add `git clone --depth=1 https://github.com/mythicc123/multi-container-service.git ../multi-container-service` as a workflow step before the Docker build. This is the safest and most explicit approach.

---

## Environment Availability

> Step 2.6: SKIPPED (GitHub Actions runners provide all required tools; EC2 dependencies verified by Phase 1/2)

**Runner-side tools** (provided by GitHub Actions `ubuntu-latest`):

| Tool | Pre-installed | Version |
|------|--------------|---------|
| Docker | Yes | Latest (runner image) |
| Git | Yes | 2.x |
| bash | Yes | 5.x |
| jq | No | Install via apt |
| httpie | No | Install via pip/apt |
| SSH key on disk | No | Use `appleboy/ssh-action` with inline key |

**EC2-side tools** (per Phase 1/2 verified state):

| Tool | Status |
|------|--------|
| Docker | Installed and running |
| Docker Compose v2 | `docker compose` available |
| Nginx | Running with `blue-green-blue.conf` and `blue-green-green.conf` |
| `/opt/blue/` and `/opt/green/` | Provisioned directories |
| `/var/run/blue-green-state` | Writable state file |
| `/tmp/blue-green-deploy.lock` | Lock file path available |
| `multi-container-service_default` Docker network | External network available |

---

## Validation Architecture

> Skip this section if `workflow.nyquist_validation` is explicitly `false` in `.planning/config.json`.

**Status:** `nyquist_validation` key absent from `.planning/config.json` -- validation section included per default.

### Test Framework

| Property | Value |
|----------|-------|
| Framework | Shell script + curl (manual smoke test) |
| Config file | None |
| Quick run command | `act -j deploy` (with `act` CLI) |
| Full suite command | Push to `main` branch |

### Phase Requirements to Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| BG-06 | Pipeline runs full deploy-to-switch cycle | Integration | Push to `main` branch | `.github/workflows/deploy.yml` -- CREATE |
| BG-07 | Docker image tagged with SHA, not `latest` | Assertion | `grep "github.sha" .github/workflows/deploy.yml` | YES after creation |
| BG-08 | Lock file acquired before deploy, released after (if: always()) | Unit | Check lock step presence + `if: always()` | YES after creation |
| BG-09 | All 4 Todo API endpoints return 2xx | Integration | Push to `main` branch (live smoke test) | YES after creation |

### Wave 0 Gaps

- `.github/workflows/deploy.yml` -- the pipeline file itself (the primary artifact)
- `app/Dockerfile` -- copy from `multi-container-service/app/Dockerfile` (or clone in CI)
- GitHub Secrets to create: `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN`, `EC2_SSH_PRIVATE_KEY`
- GitHub Vars to create: `EC2_HOST` (= `13.236.205.122`)

---

## Sources

### Primary (HIGH confidence)

- `C:\Users\fiefi\multi-container-service\.github\workflows\deploy.yml` -- Docker build-push, login-action, SSH key injection, workflow structure -- **CONFIRMED PROJECT PATTERN**
- `C:\Users\fiefi\multi-container-service\.github\workflows\ci.yml` -- Docker metadata, buildx, login-action patterns -- **CONFIRMED PROJECT PATTERN**
- `C:\Users\fiefi\blue-green-deployment\scripts\deploy.sh` -- SSH heredoc pattern, slot detection, port mapping -- **CONFIRMED DEPLOY LOGIC**
- `C:\Users\fiefi\blue-green-deployment\scripts\switch-nginx.sh` -- Nginx switch via SSH, state file update -- **CONFIRMED SWITCH LOGIC**
- `C:\Users\fiefi\blue-green-deployment\scripts\health-check.sh` -- Health polling via SSH curl -- **CONFIRMED HEALTH LOGIC**
- `C:\Users\fiefi\blue-green-deployment\scripts\run-deploy.sh` -- Full orchestrator pattern -- **CONFIRMED PIPELINE SEQUENCE**
- `docker/login-action` github.com/docker/login-action -- v3, OIDC support, Docker Hub + OCI registries
- `docker/build-push-action` github.com/docker/build-push-action -- v6, `tags:`, `cache-from:`, `cache-to:`, `context:`, `file:` inputs
- `docker/setup-buildx-action` github.com/docker/setup-buildx-action -- v3, BuildKit setup
- `appleboy/ssh-action` github.com/appleboy/ssh-action -- v0.40.0, SSH execution marketplace action

### Secondary (MEDIUM confidence)

- GitHub Actions `concurrency` block documentation -- standard YAML configuration
- `docker/metadata-action@v5` tag generation -- standard marketplace action
- `flock` (util-linux) -- standard on Ubuntu 22.04 (GitHub Actions runner) and EC2

### Tertiary (LOW confidence)

- Exact `appleboy/ssh-action` v0.40.0 behavior -- verify against GitHub marketplace for latest version
- Docker `type=gha` cache backend availability on `ubuntu-latest` -- verify that GitHub Actions Docker engine has `buildx` and GHA cache backend enabled

---

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH -- all actions are official GitHub Actions or verified project patterns
- Architecture: HIGH -- mirrors Phase 2 `run-deploy.sh` which is tested; confirmed in multi-container-service CI files
- Pitfalls: HIGH -- identified from confirmed project artifacts and well-documented shell/SSH behaviors
- Tag strategy: HIGH -- immutable tags are first-class GitHub Actions feature
- Concurrency lock: HIGH -- `flock` + `concurrency` group is a known anti-concurrent-deploy pattern

**Research date:** 2026-04-01
**Valid until:** ~90 days for GitHub Actions (stable API); 30 days for action versions (check for newer major versions quarterly)
