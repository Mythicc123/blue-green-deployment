# Requirements: Blue-Green Deployment System

**Project:** blue-green-deployment
**Status:** Active

---

## Validated

(None yet — ship to validate)

## Active

### Infrastructure

- [ ] **BG-01**: Dual environment setup — `/opt/blue/` and `/opt/green/` directories each contain a Docker Compose project with the Node.js API container. Blue on port 3001, green on port 3002.
- [ ] **BG-02**: Nginx symlink-based switching — two pre-written Nginx config files (`blue-green-blue.conf`, `blue-green-green.conf`) in `/etc/nginx/sites-available/`, activated via `ln -sf` symlink to `/etc/nginx/sites-enabled/blue-green`, followed by `nginx -s reload`. Zero-downtime.
- [ ] **BG-03**: Health check polling before switch — CI/CD or manual script polls `http://localhost:<inactive_port>/health` until healthy (up to 60s), before Nginx switch is triggered.
- [ ] **BG-04**: Active slot state tracking — `/var/run/blue-green-state` contains `blue` or `green` text, updated after each switch. Readable by CI/CD and humans.
- [ ] **BG-05**: Shared MongoDB connection — both environments connect to the existing multi-container-service MongoDB via `MONGO_URL` environment variable, not a baked-in connection string.

### CI/CD Pipeline

- [x] **BG-06**: Automated CI/CD pipeline on push — GitHub Actions `deploy.yml` triggers on push to main. Steps: determine active slot, deploy to inactive slot, health check, Nginx switch, smoke test.
- [x] **BG-07**: Immutable Docker image tags — images tagged with git SHA (e.g., `v1.0.0-sha-abc1234`), never `latest`. Each deploy is reproducible.
- [x] **BG-08**: Concurrency lock — GitHub Actions concurrency group prevents simultaneous deployments. Deployment lock file on EC2 (`/tmp/blue-green-deploy.lock`) as secondary protection.
- [x] **BG-09**: Smoke test after switch — CI/CD calls Todo API endpoints (GET/POST/PUT/DELETE) through the public IP after Nginx switch to confirm full path works.

### Rollback

- [x] **BG-10**: Manual rollback — SSH script that reads `/var/run/blue-green-state`, flips Nginx symlink to the other slot, runs `nginx -s reload`. No container rebuild needed.
- [ ] **BG-11**: Old slot stays alive — after switch, the previously active environment keeps running. Rollback is instant Nginx reload, not a full redeploy.

### Monitoring (Bonus)

- [ ] **BG-12**: Health check endpoints — `/health` endpoint on the API verifies MongoDB connectivity, not just container liveness.
- [x] **BG-13**: Container log access — `docker compose logs` readable via SSH or CI/CD.
- [x] **BG-14**: Nginx access log monitoring — logs in `/var/log/nginx/access.log`, readable and queryable.

## Out of Scope

- **Separate MongoDB per environment** — each blue/green having its own MongoDB adds resource overhead and is deferred to future phases.
- **Canary traffic splitting** — gradual 5%/10%/50% routing before full switch is complex and deferred.
- **Automated rollback on failure** — manual rollback is v1. Automated rollback (post-switch monitoring + auto-switch-back) is v1.x.
- **Kubernetes / EKS** — Docker Compose on EC2 is the right abstraction for this project's scope.
- **Prometheus/Grafana** — basic monitoring (health checks, logs) is sufficient for v1.
- **Domain / Route53** — IP address access only, domain can be added in v1.x.
- **Separate EC2 instance** — blue-green runs on the same instance as multi-container-service.
- **GitOps** — manual `helm install/upgrade` is v1. GitOps deferred.
- **Database migrations as separate pipeline step** — migrations must be backward-compatible and run as part of the app startup, not a separate pipeline stage.

---

## Traceability

| Requirement | Phase | Notes |
|-------------|-------|-------|
| BG-01 | 1 | Foundation: Docker Compose dirs |
| BG-02 | 1 | Foundation: Nginx config files |
| BG-05 | 1 | Foundation: env var strategy |
| BG-03 | 2 | Deployment automation |
| BG-04 | 2 | State tracking |
| BG-06 | 3 | CI/CD pipeline |
| BG-07 | 3 | CI/CD: immutable tagging |
| BG-08 | 3 | CI/CD: concurrency lock |
| BG-09 | 3 | CI/CD: smoke test |
| BG-10 | 2 | Rollback script |
| BG-11 | 1 | Architecture decision |
| BG-12 | 1 | Health endpoint verification |
| BG-13 | 2 | Log access |
| BG-14 | 2 | Nginx log access |
