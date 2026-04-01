---
phase: "03-ci-cd-pipeline"
plan: "01"
subsystem: "ci-cd-pipeline"
tags:
  - "github-actions"
  - "docker"
  - "blue-green"
  - "ec2"
  - "locking"
dependency_graph:
  requires:
    - "Phase 2 scripts (deploy.sh, run-deploy.sh, etc.)"
  provides:
    - ".github/workflows/deploy.yml"
    - "Dockerfile"
    - "scripts/ec2-lock.sh"
  affects:
    - "Phase 3 Plan 2 (smoke test, end-to-end pipeline)"
tech_stack:
  added:
    - "GitHub Actions"
    - "docker/build-push-action"
    - "appleboy/ssh-action"
    - "flock"
  patterns:
    - "GitHub Actions concurrency group"
    - "EC2 flock lock with TTL"
    - "Immutable SHA-based Docker image tagging"
    - "SSH-based remote deployment"
key_files:
  created:
    - ".github/workflows/deploy.yml"
    - "Dockerfile"
    - "package.json"
    - "package-lock.json"
    - "src/index.js"
    - "src/routes/todos.js"
    - "src/models/Todo.js"
    - "src/config.js"
    - "scripts/ec2-lock.sh"
decisions:
  - id: "03-01-01"
    decision: "Install Phase 2 scripts on EC2 via base64 encoding in appleboy/ssh-action before deploy step"
    rationale: "Avoids requiring scripts to be pre-installed on EC2; keeps scripts under version control in the repo; base64 encoding avoids SSH heredoc quoting issues"
  - id: "03-01-02"
    decision: "Inline flock lock logic directly in appleboy/ssh-action script block, not via ec2-lock.sh subcall"
    rationale: "Inline is more portable and avoids path issues; ec2-lock.sh provided as a standalone utility for manual diagnostics"
  - id: "03-01-03"
    decision: "Lock is NOT released on deploy failure — only TTL (10 min) cleans it"
    rationale: "Prevents a new run from acquiring a lock held by a dead process and overwriting its deploy state; TTL is the safe recovery mechanism"
metrics:
  duration_seconds: 59
  completed: "2026-04-01T06:37:56Z"
  tasks_completed: 3
  files_created: 9
requirements:
  - "BG-06"
  - "BG-07"
  - "BG-08"
---

# Phase 03 Plan 01: GitHub Actions Deploy Workflow - Summary

## One-liner

GitHub Actions pipeline triggers on push to main, builds and pushes immutable SHA-tagged Docker image to Docker Hub, installs Phase 2 deploy scripts on EC2, acquires flock-based deployment lock, runs blue-green deploy, and smoke tests Todo API endpoints via public IP.

## What Was Built

### 1. GitHub Actions Workflow: `.github/workflows/deploy.yml` (177 lines)

**Commit:** `7c07a4c`

Full CI/CD pipeline with the following stages:

| Step | Purpose | BG Ref |
|------|---------|--------|
| `actions/checkout@v4` | Checkout source code | - |
| `docker/setup-buildx-action@v3` | Enable Docker buildx | - |
| `docker/login-action@v3` | Authenticate to Docker Hub | - |
| `docker/build-push-action@v6` | Build and push with `sha-${{ github.sha }}` tag | BG-07 |
| `appleboy/ssh-action` (install) | Upload Phase 2 scripts to EC2 | BG-06 |
| `appleboy/ssh-action` (deploy) | flock lock + run-deploy.sh | BG-08 |
| Smoke test step | GET/POST/PUT/DELETE against public IP | BG-09 |

**Concurrency:** `group: ${{ github.repository }}` with `cancel-in-progress: true` (BG-08). Any new push to main cancels the in-progress run.

**Docker image:** `mythicc123/multi-container-service:sha-${{ github.sha }}` — NEVER uses `latest` tag.

**Lock strategy:**
- Lock file: `/tmp/blue-green-deploy.lock`
- flock atomic acquisition with 5-minute wait timeout
- TTL (10 min) written inside flock critical section
- Lock content: PID, hostname, acquired timestamp, GITHUB_RUN_ID, GITHUB_RUN_URL, TTL_AT
- Lock released only on deploy success; on failure, TTL cleans it

### 2. Docker Build Context: Todo API Source Files

**Commit:** `8c06f5d`

Copied from sibling repo `C:\Users\fiefi\multi-container-service\app\`:

| File | Purpose |
|------|---------|
| `Dockerfile` | Multi-stage Node.js 20 Alpine build (23 lines) |
| `package.json` | express + mongoose dependencies |
| `package-lock.json` | Locked dependency versions |
| `src/index.js` | Express app entry point |
| `src/routes/todos.js` | CRUD endpoints |
| `src/models/Todo.js` | Mongoose schema |
| `src/config.js` | Environment config |

The workflow uses `context: .` so the Dockerfile at repo root picks up all source files at their relative paths.

### 3. EC2 Lock Utility: `scripts/ec2-lock.sh` (122 lines)

**Commit:** `f2b23cc`

Standalone lock management script for EC2 diagnostics and manual operations:

```bash
./ec2-lock.sh acquire   # Atomic flock acquire with TTL
./ec2-lock.sh release   # Release only if held by current PID
./ec2-lock.sh status    # Exit 0=free, 1=held, 2=stale
./ec2-lock.sh cleanup   # Remove TTL-expired locks
```

**Design:**
- flock file descriptor 9 for atomic acquisition
- TTL-bearing lock file with diagnostics fields
- Distinct exit codes for programmatic use
- `set -euo pipefail` safe bash mode
- Executable (`chmod +x`)

## Success Criteria Status

| Criterion | Status |
|-----------|--------|
| `.github/workflows/deploy.yml` triggers on push to main | PASS |
| Concurrency group with `cancel-in-progress: true` | PASS |
| Docker image tagged with `sha-${{ github.sha }}` only (no `latest`) | PASS |
| EC2 flock lock acquired before deploy, released on success only | PASS |
| Lock file contains PID, hostname, timestamp, TTL, GitHub run ID | PASS |
| Dockerfile at repo root (multi-stage Node.js 20 Alpine) | PASS |
| `package.json`, `package-lock.json`, `src/` at repo root | PASS |
| `scripts/ec2-lock.sh` with acquire/release/status/cleanup commands | PASS |
| Smoke test calls GET/POST/PUT/DELETE /todos via public IP | PASS |

## Verification Commands

```bash
# Workflow exists and has required elements
ls .github/workflows/deploy.yml
grep "concurrency:" .github/workflows/deploy.yml
grep "sha-\${{ github.sha }}" .github/workflows/deploy.yml
! grep -q "mythicc123/multi-container-service:latest" .github/workflows/deploy.yml && echo "no latest tag"

# Source files for Docker build
ls Dockerfile package.json package-lock.json src/

# Lock script
ls scripts/ec2-lock.sh
bash -n scripts/ec2-lock.sh && echo "bash syntax OK"
./scripts/ec2-lock.sh status

# Phase 2 scripts referenced by workflow
ls scripts/deploy.sh scripts/run-deploy.sh scripts/health-check.sh scripts/switch-nginx.sh scripts/get-active-slot.sh
```

## Known Stubs

None — all files are fully functional.

## Deviations from Plan

None — plan executed exactly as written.

## Auth Gates

The workflow requires the following GitHub repository secrets to be configured:

| Secret | Purpose |
|--------|---------|
| `EC2_HOST` | EC2 public IP (`13.236.205.122`) |
| `EC2_SSH_KEY` | SSH private key for ubuntu user |
| `DOCKER_USERNAME` | Docker Hub username |
| `DOCKER_PASSWORD` | Docker Hub password or access token |

## Self-Check

- [x] `.github/workflows/deploy.yml` — FOUND (177 lines, commit 7c07a4c)
- [x] `Dockerfile` — FOUND (23 lines, commit 8c06f5d)
- [x] `package.json`, `package-lock.json` — FOUND (commit 8c06f5d)
- [x] `src/index.js`, `src/routes/todos.js`, `src/models/Todo.js`, `src/config.js` — FOUND (commit 8c06f5d)
- [x] `scripts/ec2-lock.sh` — FOUND (122 lines, commit f2b23cc, executable)
- [x] Commit 7c07a4c: FOUND
- [x] Commit 8c06f5d: FOUND
- [x] Commit f2b23cc: FOUND

**Self-Check: PASSED**

## Next Steps

- **Phase 3 Plan 2 (03-02):** End-to-end smoke test, concurrency lock verification, and immutable tagging audit — run a real commit through the pipeline to validate everything works together.

## Commits

| Hash | Files | Message |
|------|-------|---------|
| `7c07a4c` | `.github/workflows/deploy.yml` | feat(03-ci-cd-pipeline): add GitHub Actions deploy workflow for blue-green deployments |
| `8c06f5d` | `Dockerfile`, `package.json`, `package-lock.json`, `src/` | feat(03-ci-cd-pipeline): add Todo API source files for Docker build context |
| `f2b23cc` | `scripts/ec2-lock.sh` | feat(03-ci-cd-pipeline): add ec2-lock.sh for EC2-side flock-based deployment locking |
