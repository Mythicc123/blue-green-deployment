# Research Summary: Blue-Green Deployment

**Confidence:** MEDIUM-HIGH (established patterns, no web verification)

## Key Decisions Made

1. **Shared MongoDB** — Reuse the existing MongoDB from multi-container-service (port 27017). Both blue and green containers connect to the same DB. Migration must be backward-compatible.
2. **Keep old slot** — Both environments stay running after switch. Rollback is just `nginx -s reload` + another `ln -sf`. No redeploy needed.

## Stack

| Component | Technology | Version |
|-----------|-----------|---------|
| Router | Nginx (host-level, systemd) | 1.24+ (Ubuntu 22.04) |
| Orchestration | Docker Compose v2 | standalone `docker compose` |
| CI/CD | GitHub Actions + `appleboy/ssh-agent-action` | latest |
| IaC | Terraform (data-only, no new resources) | >= 1.5.0 |
| App runtime | Node.js | 20.x (unchanged) |
| Database | MongoDB | 7 (shared, existing) |

## Architecture

```
EC2 Host (13.236.205.122)
├── Nginx (host, port 80) — switches between blue/green via symlink
├── /opt/blue/         — blue-api:3001, shared MongoDB:27017
├── /opt/green/        — green-api:3002, shared MongoDB:27017
└── /var/run/blue-green-state — "blue" or "green" (active slot tracker)
```

## Traffic Flow
1. Request → Nginx (port 80)
2. Nginx → active environment (blue:3001 OR green:3002)
3. API container → shared MongoDB (27017)

## Deployment Flow
1. Determine active slot → deploy to inactive
2. Health check via `localhost:<port>/health` (NOT public IP)
3. `nginx -t && ln -sf sites-available/active /etc/nginx/sites-enabled/`
4. `nginx -s reload` (zero downtime)
5. Smoke test via public IP
6. Old slot stays alive for instant rollback

## Requirements (v1)

### Must Have
- [ ] BG-01: Dual environment setup (`/opt/blue`, `/opt/green`) with Docker Compose
- [ ] BG-02: Nginx symlink-based switching between environments
- [ ] BG-03: Health check polling before switch (local, not public IP)
- [ ] BG-04: Automated CI/CD pipeline on push
- [ ] BG-05: Smoke test after switch
- [ ] BG-06: Manual rollback via Nginx switch
- [ ] BG-07: Immutable Docker image tags (git SHA, not `latest`)
- [ ] BG-08: Shared MongoDB connection via environment variable
- [ ] BG-09: Concurrency lock in CI/CD
- [ ] BG-10: Active slot state tracking (`/var/run/blue-green-state`)

### Bonus (Monitoring)
- [ ] BG-11: Health check endpoints (container-level)
- [ ] BG-12: Container log access
- [ ] BG-13: Nginx access log monitoring

## Watch Out For
1. Health checks must target `localhost:3001` (inactive), NOT public IP — public IP always hits the live environment
2. Database migrations must be backward-compatible — shared DB means old env breaks if migration isn't safe
3. Session storage must be MongoDB-backed — in-memory sessions die on switch
4. Old slot must stay alive — instant rollback depends on it
5. Concurrency lock — two simultaneous deployments corrupt the inactive slot

## Anti-Patterns to Avoid
- Nginx inside Docker (use host-level Nginx)
- Single Nginx config rewritten by CI (use pre-written static configs + symlink)
- Tearing down old env before health checks pass
- `latest` tag in Docker images
- MongoDB connection string baked into Docker image

## Files Created

| File | Purpose |
|------|---------|
| STACK.md | Technology choices with versions and rationale |
| FEATURES.md | Feature landscape, MVP, prioritization |
| ARCHITECTURE.md | Component boundaries, data flows, project structure |
| PITFALLS.md | 8 critical pitfalls, prevention strategies, phase mapping |
