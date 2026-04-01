# ROADMAP: Blue-Green Deployment System

**Project:** blue-green-deployment
**Granularity:** Coarse
**Mode:** Yolo
**Phases:** 3
**Coverage:** 14/14 requirements mapped

---

## Phases

- [ ] **Phase 1: Foundation** - Docker Compose directories, Nginx configs, shared MongoDB
- [ ] **Phase 2: Deployment Automation** - Scripts, health check, state tracking, rollback
- [ ] **Phase 3: CI/CD Pipeline** - GitHub Actions, immutable tags, smoke test, concurrency

---

## Phase Details

### Phase 1: Foundation

**Goal:** `/opt/blue/` and `/opt/green/` Docker Compose environments are created, Nginx switching configs are pre-written and validated, both environments can be manually deployed and switched.

**Depends on:** None

**Requirements:** BG-01, BG-02, BG-05, BG-11, BG-12

**Success Criteria** (what must be TRUE):
1. `/opt/blue/` and `/opt/green/` directories exist on EC2 with Docker Compose files
2. Blue container starts on port 3001, green on port 3002
3. Both containers connect to shared MongoDB (multi-container-service)
4. Two Nginx config files (`blue-green-blue.conf`, `blue-green-green.conf`) exist and pass `nginx -t`
5. Active slot can be switched via `ln -sf` + `nginx -s reload` with zero downtime
6. Health endpoint (`/health`) verifies MongoDB connectivity
7. Both environments use environment variables (`.env` files), not baked-in connection strings

**Plans:** 2 plans
- [ ] 01-01-PLAN.md — Docker Compose directories for blue and green environments
- [ ] 01-02-PLAN.md — Nginx config files and symlink-based switching

---

### Phase 2: Deployment Automation

**Goal:** Manual deployment scripts exist that deploy to inactive environment, run health checks, and switch Nginx. Rollback is tested.

**Depends on:** Phase 1

**Requirements:** BG-03, BG-04, BG-10, BG-13, BG-14

**Success Criteria** (what must be TRUE):
1. `scripts/deploy.sh` deploys to inactive slot based on `/var/run/blue-green-state`
2. `scripts/health-check.sh` polls `localhost:<port>/health` with retry logic
3. `scripts/switch-nginx.sh` runs `ln -sf` + `nginx -t` + `nginx -s reload`
4. `scripts/rollback.sh` flips Nginx back to previous slot in one command
5. `/var/run/blue-green-state` is updated after each switch
6. Container logs readable via `docker compose logs`
7. Nginx logs readable from `/var/log/nginx/`
8. Full deploy-to-switch cycle tested manually on EC2

**Plans:** 2 plans
- [x] 02-01-PLAN.md — Deploy scripts, health check, switch Nginx, run-deploy orchestrator
- [x] 02-02-PLAN.md — Rollback script, log access

---

### Phase 3: CI/CD Pipeline

**Goal:** GitHub Actions pipeline automates build, deploy, health check, switch, and smoke test on every push to main. Concurrency protection prevents simultaneous deployments.

**Depends on:** Phase 2

**Requirements:** BG-06, BG-07, BG-08, BG-09

**Success Criteria** (what must be TRUE):
1. `.github/workflows/deploy.yml` triggers on push to main
2. Pipeline determines active slot, deploys to inactive slot
3. Docker images tagged with git SHA (not `latest`)
4. Health check passes before Nginx switch is triggered
5. Smoke test calls Todo API endpoints through public IP after switch
6. Concurrency group prevents simultaneous runs
7. Deployment lock file prevents CI and manual deploys from colliding
8. Full pipeline tested end-to-end with a real commit

**Plans:** 2 plans
- [ ] 03-01-PLAN.md — GitHub Actions deploy workflow
- [ ] 03-02-PLAN.md — Smoke test, concurrency lock, immutable tagging

---

## Progress

| Phase | Plans Complete | Status | Completed |
|-------|---------------|--------|-----------|
| 1. Foundation | 0/2 | Not started | - |
| 2. Deployment Automation | 2/2 | Complete | 2026-04-01 |
| 3. CI/CD Pipeline | 0/2 | Not started | - |

---

## Coverage Map

| Requirement | Phase | Status |
|-------------|-------|--------|
| BG-01 | Phase 1 | Pending |
| BG-02 | Phase 1 | Pending |
| BG-05 | Phase 1 | Pending |
| BG-11 | Phase 1 | Pending |
| BG-12 | Phase 1 | Pending |
| BG-03 | Phase 2 | Pending |
| BG-04 | Phase 2 | Pending |
| BG-10 | Phase 2 | Pending |
| BG-13 | Phase 2 | Pending |
| BG-14 | Phase 2 | Pending |
| BG-06 | Phase 3 | Pending |
| BG-07 | Phase 3 | Pending |
| BG-08 | Phase 3 | Pending |
| BG-09 | Phase 3 | Pending |

**v1 coverage: 14/14** — All requirements mapped. No orphans.
