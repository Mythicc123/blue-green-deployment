# Feature Research

**Domain:** Blue-green container deployment with Nginx traffic switching
**Researched:** 2026-04-01
**Confidence:** MEDIUM

> **Research note:** Web search tools were unavailable during this session. Findings are based on established deployment-pattern knowledge. All claims should be validated against current documentation before implementation decisions are finalized.

---

## Feature Landscape

### Table Stakes (Users Expect These)

Features operators assume exist in any production deployment system. Missing these = broken, not just incomplete.

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| Dual environment (blue/green) | The defining requirement of blue-green. Two independently deployable environments on the same Docker host, in `/opt/blue` and `/opt/green` | LOW | Each environment is a Docker Compose project with its own `.env`. The inactive environment is the deployment target |
| Nginx upstream switching | Nginx must proxy to the active environment and switch upstream blocks when switching environments | MEDIUM | Requires an Nginx config that defines both `blue_backend` and `green_backend` upstreams, and a `server` block that points to the active one. Switch is done via `nginx -s reload` (zero downtime) |
| Health check before switch | Traffic must not route to new version until it is confirmed healthy. A health check endpoint (`/health` already exists on the app at `src/index.js:12`) must be polled | MEDIUM | Must distinguish "container is up" from "application is healthy". Container up + MongoDB connection down = unhealthy. Requires polling the `/health` endpoint with retry logic |
| Rollback to previous environment | If the new version fails health checks or post-switch monitoring, operator must be able to switch back instantly without redeploying | LOW | Since both environments stay up post-switch, rollback is just another Nginx upstream switch + reload. No container rebuild needed |
| Deployment automation (CI/CD pipeline) | Manual deployments are error-prone and slow. Pipeline must trigger on push, build the new image, deploy to inactive environment, run health checks, switch, and optionally clean up | HIGH | GitHub Actions workflow with steps: build+push image, SSH to EC2, `docker compose -f /opt/{inactive}/docker-compose.yml up -d`, health check loop, Nginx switch, teardown old environment |
| Smoke test after switch | Confirm the deployment works end-to-end by making a real request through Nginx (not just to the container directly) | MEDIUM | Post-switch smoke test calls the public IP or Nginx upstream to confirm the full request path works. Catches Nginx misconfiguration that health checks alone would miss |
| Database migration strategy | Both environments share the same MongoDB instance. Schema changes must be backward-compatible or migrations must run before switch | HIGH | This is the most dangerous table-stakes feature. If a migration is not backward-compatible and blue-green uses the same DB, the old environment will break after switch. Migrations must run as a separate step before the switch, and must be idempotent |
| Deployment state tracking | Operators must know which environment is active and what version is deployed where | LOW | Simple file (`/opt/active-environment.txt`) or Nginx config comment noting which upstream is active. Readable by CI/CD pipeline and humans |

### Differentiators (Competitive Advantage)

Features that set the system apart. Not required for basic blue-green, but valued by operators who run it frequently.

| Feature | Value Proposition | Complexity | Notes |
|---------|-------------------|------------|-------|
| Automated rollback on failure | No human involvement needed if new version fails health checks or post-switch error rate spikes | MEDIUM | Pipeline detects failure, runs Nginx switch back to previous environment, and reports the failure. Requires post-switch monitoring window (e.g., 60s of error-rate checking) |
| Canary traffic splitting | Route a small percentage (e.g., 5%) of traffic to new version before full switch. Catches issues with real users | HIGH | Requires Nginx weighted upstream or Lua module, or a separate canary Nginx config. Complexity is high for v1; defer to v1.x |
| Deployment approval gate | Require human approval in CI/CD before switching traffic. Useful for high-risk releases | LOW | GitHub Actions `environment` protection rules or a manual workflow_dispatch gate. Very low effort to add, high value for controlled rollouts |
| Deployment history / audit log | Record every deployment: timestamp, version, who triggered it, outcome | LOW | Append entries to a log file (`/var/log/blue-green-deployments.log`) or a lightweight SQLite DB. Simple to implement, valuable for incident post-mortems |
| Pre-deployment compatibility check | Run integration tests against the new version before switching, using a temporary deployment or a test script against the new container directly | MEDIUM | Uses the inactive environment's container (already deployed) as a test target. Runs API tests (GET/POST/PUT/DELETE on the Todo endpoints) before switching. Catches app-level bugs before users see them |
| Environment parity validation | Before deploying, confirm inactive environment is clean (no leftover containers from previous rollback) to avoid version mixing | LOW | `docker compose ps` check in CI/CD pipeline before `up -d`. If stale containers exist, clean them first |
| Graceful connection draining | Before tearing down the old environment post-switch, wait for in-flight requests to complete | MEDIUM | `docker stop --time 30` gives existing connections 30s to drain. Nginx `keepalive_timeout` and `keepalive_requests` settings also matter. Prevents dropped requests during teardown |
| Container image tagging strategy | Use git SHA-based tags (`blue-green:abc123f`) instead of `:latest` so deployments are reproducible and rollback targets are unambiguous | LOW | GitHub Actions `GITHUB_SHA` env var gives the SHA. Tag images as both `:sha-abc123f` and `:blue` / `:green` (the environment tag flips on each deploy) |

### Anti-Features (Commonly Requested, Often Problematic)

Features that seem good in theory but create real problems in practice for this specific project.

| Feature | Why Requested | Why Problematic | Alternative |
|---------|---------------|-----------------|-------------|
| Zero-downtime database migrations | Developers want to run schema changes as part of deployment without downtime | Blue-green is designed for stateless app changes. DB migrations in blue-green require careful backward-compatibility planning and are not "zero-downtime" by default. Running migrations as part of the pipeline before the switch creates a window where both old and new code run against the new schema | Run migrations as a separate pipeline step before deployment. Use MongoDB migration scripts that are idempotent and backward-compatible. Accept that migration runs have their own deployment window |
| Simultaneous blue AND green with traffic split (canary) | Why not get the best of both worlds and route 10% to new version? | Adds significant complexity: requires Nginx configuration for weighted routing or a separate canary config, a mechanism to gradually increase traffic, and monitoring to detect when to abort. For a v1 blue-green on a single EC2 instance, this is overkill | Add canary routing in v1.x after basic blue-green is stable. Start with 0%/100% switch, not gradual |
| Prometheus / Grafana monitoring | It would be nice to have real observability for the deployment | The project explicitly defers observability to v1.x. Adding a full Prometheus/Grafana stack to the existing EC2 instance adds operational complexity and resource usage. The basic health checks and smoke tests are sufficient for v1 | Add kube-prometheus-stack or a lightweight uptime monitor in v1.x. For v1, `curl` health checks + smoke tests + container logs are enough |
| Kubernetes orchestration | Since the CLAUDE.md for the Kubernetes cluster project recommends EKS + Helm, why not run blue-green on K8s? | The project explicitly uses same-EC2 Docker Compose. K8s would require a new cluster, significant IaC changes, and is a different operational model. The value of blue-green on this project is simplicity | Stick to Docker Compose on EC2 as designed. EKS would be a separate project |
| Rolling deployments alongside blue-green | Why not support both blue-green and rolling deployments as options? | Supporting two deployment strategies doubles the complexity of the CI/CD pipeline, testing matrix, and documentation. Blue-green and rolling are mutually exclusive strategies for the same goal | Choose one. Blue-green is already selected. Rolling (replacing containers one by one) is the simpler alternative if blue-green proves too complex, but it does not belong in the same system |
| Auto-scaling based on deployment state | Scale up the new environment before switch based on load predictions | The existing EC2 instance has fixed resources. Autoscaling would require pre-provisioning more capacity or migrating to a cluster. Adds a dependency on infrastructure that does not exist in this project | Not relevant for v1. If load requires it, migrate to EKS with Karpenter (separate project) |

---

## Feature Dependencies

```
Database Migration Strategy
    └──requires──> Backward-Compatible Schema Changes (must be verified before deployment)
                       └──requires──> Migration Run Before Switch (pipeline step 1)

Deployment Pipeline
    └──requires──> Docker Image Build + Push (step 1)
                       └──requires──> Deploy to Inactive Environment (step 2, docker compose up -d)
                              └──requires──> Health Check Polling (step 3)
                                      └──requires──> Nginx Upstream Switch (step 4)
                                              └──requires──> Smoke Test (step 5)
                                                      └──enhances──> Rollback Capability (step 6: switch back)
```

### Dependency Notes

- **Health check polling requires Nginx to test the inactive environment directly:** The CI/CD pipeline must SSH to EC2 and `curl http://localhost:3000/health` via the inactive environment's container port (docker compose port mapping). If health checks only hit the public IP (which routes through Nginx to the active environment), they will always succeed on the old version and never test the new one
- **Smoke test requires smoke test script:** The post-switch smoke test must call the Todo API endpoints (GET/POST/PUT/DELETE) against the public IP. This tests the full path: Nginx -> active environment -> MongoDB. Without a smoke test, Nginx misconfiguration would go undetected
- **Rollback requires both environments to stay up:** The teardown step (removing old environment containers) must only run after a grace period post-switch, or be manual. If the old environment is torn down immediately, rollback requires a full redeploy
- **Git SHA tagging conflicts with rollback clarity:** If images are only tagged with `:blue` / `:green` (flipping on each deploy), previous versions are lost. Use git SHA tags for reproducibility; environment tags for routing
- **MongoDB shared between environments:** Both blue and green point to the same MongoDB. Schema changes in the new version that are not backward-compatible will break the old environment after the switch. The migration must run before the switch and must not break existing code paths

---

## MVP Definition

### Launch With (v1)

Minimum viable product — the smallest set that validates zero-downtime deployments work.

- [ ] **Dual environment setup** (`/opt/blue`, `/opt/green`, separate Docker Compose files + `.env`) — foundational isolation
- [ ] **Nginx upstream switching** (config with both upstreams, switch via `nginx -s reload`) — the core mechanism
- [ ] **Health check polling in CI/CD** (deploy, then poll `/health` until healthy or timeout) — gate before switch
- [ ] **Smoke test after switch** (call Todo API endpoints through public IP) — confirm full path works
- [ ] **Manual rollback** (SSH to EC2, run switch script back to old environment) — safety net
- [ ] **CI/CD pipeline on push** (GitHub Actions: build, deploy inactive, health check, switch, smoke test) — automation

### Add After Validation (v1.x)

Features to add once the core loop is proven.

- [ ] **Automated rollback on failure** — post-switch monitoring window (60s error rate check), auto-switch-back on threshold breach
- [ ] **Deployment history log** — append to `/var/log/blue-green-deployments.log` with timestamp, version, outcome
- [ ] **Git SHA image tagging** — tag with `sha-{GITHUB_SHA}` for reproducible rollbacks, environment tag flips on switch
- [ ] **Pre-deployment compatibility check** — run a small integration test suite against the inactive environment before switching
- [ ] **Graceful connection draining on teardown** — `docker stop --time 30` before removing old environment

### Future Consideration (v2+)

Features that require a more mature operational context.

- [ ] **Canary traffic splitting** (5% / 10% / 50% / 100% gradual routing) — requires Nginx weighted upstream or separate canary config
- [ ] **Deployment approval gate** — GitHub Actions environment protection rules for human sign-off before switch
- [ ] **Prometheus/Grafana monitoring** — metrics for deployment duration, error rates, health check latency
- [ ] **Multi-region blue-green** — active environment in one AZ, inactive in another, for true disaster recovery
- [ ] **Database per environment** — eliminates backward-compatibility constraint on migrations, but adds MongoDB data migration step and doubles storage costs

---

## Feature Prioritization Matrix

| Feature | User Value | Implementation Cost | Priority |
|---------|------------|---------------------|----------|
| Dual environment setup | HIGH | LOW | P1 |
| Nginx upstream switching | HIGH | MEDIUM | P1 |
| Health check polling | HIGH | MEDIUM | P1 |
| Smoke test post-switch | HIGH | MEDIUM | P1 |
| CI/CD pipeline (build + deploy + switch) | HIGH | HIGH | P1 |
| Manual rollback | HIGH | LOW | P1 |
| Database migration strategy (backward-compat) | HIGH | MEDIUM | P1 |
| Deployment state tracking | MEDIUM | LOW | P2 |
| Git SHA image tagging | MEDIUM | LOW | P2 |
| Pre-deployment compatibility check | MEDIUM | MEDIUM | P2 |
| Automated rollback on failure | MEDIUM | MEDIUM | P2 |
| Graceful connection draining | MEDIUM | LOW | P2 |
| Deployment history log | LOW | LOW | P3 |
| Deployment approval gate | LOW | LOW | P3 |
| Canary traffic splitting | MEDIUM | HIGH | P3 |
| Prometheus/Grafana monitoring | MEDIUM | HIGH | P3 |

**Priority key:**
- P1: Must have for launch
- P2: Should have, add in v1.x
- P3: Nice to have, future consideration

---

## Competitor Feature Analysis

| Feature | AWS CodeDeploy (Blue/Green) | Kubernetes (Rolling Update + blue-green svc) | Our Approach |
|---------|------------------------------|----------------------------------------------|--------------|
| Dual environment | Managed by AWS (separate ASG) | Two ReplicaSets or two deployments | `/opt/blue` + `/opt/green` on same EC2 |
| Traffic switching | AWS reroutes ALB target group | Service selector switch | Nginx upstream switch + reload |
| Health verification | Built-in (ELB health checks) | Liveness/readiness probes | CI/CD polling `/health` endpoint |
| Rollback | One-click in CodeDeploy console | `kubectl rollout undo` | Nginx switch back to previous environment |
| Database migration handling | Out of scope | Out of scope (stateful = complex) | Must be handled explicitly (backward-compatible migrations) |
| CI/CD integration | Native (CodeDeploy, CodePipeline) | Argo CD, Flux, Helm | GitHub Actions + SSH to EC2 |
| Cost | Extra EC2/ASG resources during switch | Extra pods during transition | Zero extra cost (reuse same EC2) |
| Complexity to set up | Medium (AWS-native) | High (K8s + Helm knowledge) | Low-Medium (Docker Compose + Nginx) |

### Key Takeaway

AWS CodeDeploy and Kubernetes handle blue-green natively but add infrastructure cost or operational complexity. This project's Docker Compose + Nginx approach is the simplest path for a single EC2 instance. The trade-off is that database migrations must be handled manually (no native rollback of DB schema changes). This is the biggest operational risk for v1.

---

## Sources

- **Confidence: MEDIUM** — Findings based on established blue-green deployment patterns. Web search tools were unavailable; all claims should be validated against current documentation before implementation.
- Multi-container-service codebase review: `docker-compose.yml`, `nginx/nginx.conf`, `app/src/index.js` (health endpoint confirmed at line 12)
- Blue-green deployment patterns: AWS CodeDeploy blue-green deployments, Kubernetes deployment strategies (rolling, recreate, blue-green, canary)
- nginx upstream switching for zero-downtime deployments (standard pattern: `proxy_pass` to upstream block, switch upstream, `nginx -s reload`)
- MongoDB schema migration best practices: backward-compatible migrations, expand-contract pattern

---

*Feature research for: blue-green deployment system*
*Researched: 2026-04-01*
