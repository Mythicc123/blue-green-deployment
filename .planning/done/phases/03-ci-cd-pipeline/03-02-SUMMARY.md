---
phase: 03-ci-cd-pipeline
plan: "02"
subsystem: infra
tags: [github-actions, docker-hub, blue-green, smoke-test, immutable-tags, ssh, ec2]

requires:
  - phase: "02-deployment-automation"
    provides: deploy scripts, health-check, state tracking

provides:
  - GitHub Actions deploy workflow with immutable SHA tags
  - End-to-end pipeline tested on real commit (run #14)
  - Concurrency lock (BG-08) preventing simultaneous deploys
  - Smoke test validating GET/POST/PUT/DELETE on /todos endpoint
  - Docker Hub immutable SHA tags confirmed (no 'latest' from CI/CD)

affects: [04-observability, 05-security-review]

tech-stack:
  added: [docker/build-push-action@v6, appleboy/ssh-action@v1.2.5]
  patterns: [immutable SHA tagging, mkdir-based atomic lock, smoke test after Nginx switch]

key-files:
  created: [.github/README-secrets.md]
  modified: [.github/workflows/deploy.yml]

key-decisions:
  - "Full GitHub SHA (40 chars) required for Docker Hub tag lookup - short SHA returns 404"
  - "Lock NOT released on deploy failure - only TTL (10 min) cleans stale locks"
  - "Inline SSH script in appleboy/ssh-action avoids base64 encoding fragility"

patterns-established:
  - "Pattern: Only SHA-tagged images in CI/CD; 'latest' is manual-only"
  - "Pattern: mkdir-based atomic lock with polling and TTL metadata"
  - "Pattern: Smoke test runs after Nginx reload, not before"

requirements-completed: [BG-06, BG-07, BG-08, BG-09]

duration: ~50min
completed: "2026-04-01"
---

# Phase 3, Plan 2: GitHub Actions Secrets, Pipeline Test, Immutable Tagging

**End-to-end CI/CD pipeline validated: GitHub Actions pushed immutable SHA-tagged Docker image to Docker Hub, deployed to EC2 via blue-green, and smoke tested all /todos endpoints successfully.**

## Performance

- **Duration:** ~50 min (including 4 failed pipeline iterations fixing bugs)
- **Started:** 2026-04-01T06:39Z
- **Completed:** 2026-04-01T07:40Z
- **Tasks:** 3 (1 human-action, 1 human-verify, 1 auto)
- **Files modified:** 3

## Accomplishments

- User configured all 4 GitHub Actions secrets: `EC2_SSH_KEY`, `EC2_HOST`, `DOCKER_USERNAME`, `DOCKER_PASSWORD`
- GitHub Actions run #14 passed end-to-end on commit `7969bc6`: build, deploy, lock, health check, Nginx switch, smoke test
- Docker Hub confirmed receiving immutable SHA-tagged image `mythicc123/multi-container-service:sha-7969bc6b1bb94e06c24bf716af8bf5159133ce4f`
- Smoke test verified all endpoints: GET /health, GET /todos, POST /todos, PUT /todos/:id, DELETE /todos/:id all returned 200
- Lock acquired and released cleanly; no stale locks
- `.github/README-secrets.md` documents step-by-step secret setup for future onboarding

## Task Commits

1. **Task 1: Configure GitHub Actions secrets** — Human-action checkpoint (user completed)
2. **Task 2: Run end-to-end pipeline test** — Human-verify checkpoint (user confirmed "it's up! thank you." — pipeline #14 passed)
3. **Task 3: Verify immutable SHA tagging on Docker Hub** — `7969bc6` (docs: verify SHA tag on Docker Hub)

## Files Created/Modified

- `.github/README-secrets.md` - Step-by-step guide for configuring 4 required GitHub Actions secrets
- `.github/workflows/deploy.yml` - GitHub Actions workflow with SHA tagging, blue-green deploy, smoke test
- `.planning/phases/03-ci-cd-pipeline/03-02-SUMMARY.md` - This summary

## Decisions Made

- Used full 40-character GitHub SHA for Docker Hub tag lookup (short 7-char SHA returns 404 from Docker Hub API)
- Lock file uses `mkdir` (atomic on all filesystems) with polling loop instead of `flock`
- Lock TTL metadata stored in lock directory for debugging stale locks
- Smoke test runs from GitHub Actions runner (not SSH) against public IP after Nginx reload

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

- **Pipeline run failures (iterations #10-13):** Four consecutive pipeline runs failed before success. Bugs fixed:
  1. Lock cleanup path handling (file vs directory artifact)
  2. Script install base64 fragility
  3. Smoke test field mismatch (`title`/`completed` vs wrong field names)
  4. MongoDB `_id` extraction (plain string format vs ObjectId wrapper)
- **Docker Hub short SHA 404:** Docker Hub API requires the full 40-char SHA for tag lookups. Short SHA `sha-7969bc6` returned 404; full SHA `sha-7969bc6b1bb94e06c24bf716af8bf5159133ce4f` confirmed present.
- **No Docker CLI on local machine:** Could not `docker pull` locally. Used Docker Hub REST API to verify tag existence instead.

## User Setup Required

None - no external service configuration required beyond the GitHub Actions secrets already configured.

## Next Phase Readiness

- Phase 3 complete (2/2 plans executed)
- All BG-06, BG-07, BG-08, BG-09 requirements validated
- Phase 1 (Foundation) and Phase 2 (Deployment Automation) remain pending but are prerequisites for future phases
- No blockers for Phase 4

---
*Phase: 03-ci-cd-pipeline*
*Completed: 2026-04-01*
