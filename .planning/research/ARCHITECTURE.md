# Architecture Research: Blue-Green Deployment on Single EC2

**Domain:** Infrastructure / Deployment Operations
**Researched:** 2026-04-01
**Confidence:** MEDIUM (grounded in confirmed multi-container-service Ansible/Nginx patterns; no external search available to verify current best practices, so patterns drawn from established Linux/NGINX blue-green patterns)

---

## System Overview

The system runs on a single AWS EC2 instance (13.236.205.122, ap-southeast-2) that also hosts the existing multi-container-service. The blue-green deployment introduces two isolated Docker Compose environments (`/opt/blue` and `/opt/green`) and a host-level Nginx router that switches between them. The existing multi-container-service Nginx and its containers remain untouched and continue serving their existing traffic independently.

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                         EC2 Host (13.236.205.122)                             │
│  ap-southeast-2                                                               │
├──────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌────────────────────────────────────────────────────────────────────────┐  │
│  │         Host Nginx (port 80) — existing reverse proxy                   │  │
│  │   /etc/nginx/sites-available/blue-green-{active}                        │  │
│  │   Switched by GitHub Actions via `nginx -s reload`                      │  │
│  └──────────────────────────┬─────────────────────────────────────────────┘  │
│                              │                                                │
│         ┌────────────────────┴────────────────────┐                          │
│         │                                     │                                │
│         ▼                                     ▼                                │
│  ┌─────────────┐                        ┌─────────────┐                      │
│  │   /opt/blue │                        │  /opt/green │                      │
│  │ docker-     │                        │  docker-    │                      │
│  │ compose.yml │                        │  compose.yml│                      │
│  │             │                        │             │                      │
│  │  blue-api   │                        │  green-api  │                      │
│  │  (port 8080)│◄────── active ─────────│  (port 8081)│                      │
│  │  blue-mongo │                        │  green-mongo│                      │
│  │  (port 27018)                        │  (port 27019)│                      │
│  └─────────────┘                        └─────────────┘                      │
│                                                                              │
│  ┌────────────────────────────────────────────────────────────────────────┐  │
│  │   Existing multi-container-service (unchanged)                          │  │
│  │   /opt/multi-container-service/docker-compose.yml                      │  │
│  │   Host Nginx serves this on port 80 — separate sites-enabled entry     │  │
│  │   blue-green uses its own Nginx config slot, does NOT touch this        │  │
│  └────────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
└──────────────────────────────────────────────────────────────────────────────┘
```

---

## Component Responsibilities

| Component | Responsibility | Implementation | Lives On |
|-----------|---------------|----------------|---------|
| **Host Nginx** | Reverse proxy router. Receives all HTTP traffic on port 80, routes to the active blue-green environment. Also serves existing multi-container-service via its own Nginx config. | Nginx config files in `/etc/nginx/sites-available/` and `sites-enabled/`. Swapped atomically via symlink + `nginx -s reload`. | EC2 host (systemd) |
| **Blue environment** | Isolated Docker Compose deployment. Runs its own API and MongoDB containers. Only active (receives traffic) when it is the current deployment target. | `docker-compose.yml` at `/opt/blue/`. API on port 8080, MongoDB on port 27018. | EC2 host Docker daemon |
| **Green environment** | Same as blue. Active when blue is not. Provides instant rollback target. | `docker-compose.yml` at `/opt/green/`. API on port 8081, MongoDB on port 27019. | EC2 host Docker daemon |
| **Blue-Green Nginx config** | Nginx upstream block pointing to the currently active environment's API port. Two variants: `blue-green-blue` (upstream 127.0.0.1:8080) and `blue-green-green` (upstream 127.0.0.1:8081). | Static config files, not managed by Docker. Copied to `/etc/nginx/sites-available/` by Ansible/GitHub Actions. | EC2 host |
| **Health check script** | Validates the newly deployed environment is healthy before switching traffic. | Shell script executed by GitHub Actions over SSH. Calls `/health` endpoint of the target environment. | Runs in GitHub Actions runner |
| **GitHub Actions workflow** | Orchestrates the full deployment cycle: build, deploy to inactive env, health check, switch Nginx, teardown old env. | `deploy.yml` in `.github/workflows/`. Uses `azure/setup-ssh` + raw SSH commands. | GitHub Actions runner |

---

## Data Flow

### Request Flow (Production)

```
Internet user
    │
    ▼
Host Nginx (port 80)
    │
    │  Routes to active upstream based on current Nginx config
    ▼
blue-api container  OR  green-api container
(port 8080)              (port 8081)
    │
    │  App connects to MongoDB URL
    ▼
blue-mongo container OR  green-mongo container
(port 27018)             (port 27019)
```

**Key detail:** Blue-green MongoDB runs inside each Docker Compose environment on a non-standard port (27018/27019). This avoids conflict with the existing multi-container-service MongoDB which runs on the default 27017. Each environment's Node.js API connects via `MONGO_URL=mongodb://localhost:27018/todos` (or 27019), keeping the two environments fully isolated.

### Deployment Flow

```
GitHub Actions: deploy.yml triggered on main branch push
    │
    ▼
1. Determine active environment (read current Nginx symlink or state file)
    │
    ▼
2. Deploy to INACTIVE environment
   SSH → EC2 → docker compose -f /opt/{inactive}/up
   (e.g., docker compose -f /opt/green/up if blue is active)
    │
    ▼
3. Health check inactive environment
   SSH → curl http://localhost:{inactive_port}/health
   Retry up to N times. Fail deployment if unhealthy.
    │
    ▼
4. Switch Nginx to inactive environment
   SSH → copy blue-green-{inactive} config → sites-available/
   SSH → rm sites-enabled/blue-green && ln -s ... → sites-enabled/blue-green
   SSH → nginx -s reload
   (atomic: config change + reload = zero-downtime switch)
    │
    ▼
5. Optional: tear down old environment
   SSH → docker compose -f /opt/{old}/down
   (Keep running for faster rollback until next deployment succeeds)
    │
    ▼
6. Mark new environment as active (update state file or flip symlink)
```

### Rollback Flow

```
If health check fails OR post-deployment smoke test fails:
    │
    ▼
1. Nginx already pointing to NEW environment (traffic already switched)
2. OLD environment containers still running (not yet torn down)
   OR
   Restart old environment: docker compose -f /opt/{old}/up
    │
    ▼
3. Switch Nginx back: same symlink + reload process
   SSH → ln -sf /etc/nginx/sites-available/blue-green-{old} ...
   SSH → nginx -s reload
    │
    ▼
4. Tear down failed environment: docker compose -f /opt/{failed}/down
```

---

## How Blue-Green Coexists with Existing multi-container-service

The existing multi-container-service and blue-green deployment share the same EC2 host, Docker daemon, and Nginx process, but are fully isolated at the application layer. The coexistence strategy:

1. **Port isolation:** Multi-container-service runs its API container on port 3000 (internal to Docker Compose network). Blue-green runs on ports 8080/8081. No port conflicts.

2. **Nginx config isolation:** Host Nginx uses separate `sites-available/` files:
   - `default` — existing multi-container-service routing (unchanged)
   - `blue-green-blue` and `blue-green-green` — blue-green routing (separate)
   Blue-green's sites-enabled entry is a separate symlink. Blue-green CI never touches the `default` config.

3. **Docker directory isolation:** Blue-green directories (`/opt/blue`, `/opt/green`) are completely separate from `/opt/multi-container-service`. Docker Compose project names are prefixed (`blue-`, `green-`) to avoid any namespace collision.

4. **GitHub Actions isolation:** Blue-green has its own CI/CD pipeline and repository. It does not interact with the multi-container-service GitHub Actions workflow.

5. **MongoDB isolation:** Blue-green runs its own MongoDB containers (ports 27018/27019) so it never shares or conflicts with the existing MongoDB at 27017.

---

## Recommended Project Structure

```
blue-green-deployment/
├── .github/
│   └── workflows/
│       └── deploy.yml          # Main deployment pipeline
├── ansible/
│   ├── playbook.yml             # EC2 provisioning & config (if separate from multi-container-service)
│   └── inventory.ini
├── scripts/
│   ├── deploy.sh                # SSH script: deploy to inactive env, health check, switch
│   ├── rollback.sh             # SSH script: flip Nginx back to other env
│   ├── health-check.sh         # SSH script: curl + retry logic for health endpoint
│   └── switch-nginx.sh          # SSH script: copy config + symlink + reload Nginx
├── nginx/
│   ├── blue-green-blue.conf    # Nginx config: upstream → 127.0.0.1:8080 (blue active)
│   └── blue-green-green.conf   # Nginx config: upstream → 127.0.0.1:8081 (green active)
├── compose/
│   ├── blue/
│   │   ├── docker-compose.yml  # Blue environment (api + mongo)
│   │   └── .env                # Blue environment variables
│   └── green/
│       ├── docker-compose.yml  # Green environment (api + mongo)
│       └── .env                # Green environment variables
└── .planning/
    └── research/               # This directory
```

### Structure Rationale

- **`compose/blue/` and `compose/green/`:** Side-by-side Docker Compose directories. `docker compose -p blue- ...` and `docker compose -p green- ...` keep project namespaces distinct. Each directory contains its own `.env` with environment-specific values.
- **`nginx/` configs as files (not Docker):** Blue-green Nginx routing lives on the host, not in containers, so it can be swapped without touching Docker. This is the standard pattern for host-level Nginx switching.
- **`scripts/`:** All SSH-executed scripts live here. GitHub Actions calls these via `ssh -o StrictHostKeyChecking=no ... 'bash -s' < scripts/deploy.sh`. Keeping scripts in the repo (not inline in the workflow) makes them testable locally.
- **`ansible/`:** Reuses the same pattern as multi-container-service. Can be skipped for v1 if Ansible adds unnecessary complexity — direct SSH commands in GitHub Actions are sufficient.

---

## Architectural Patterns

### Pattern 1: Host-Level Nginx Router (Not Dockerized Nginx)

**What:** Nginx runs as a host-level systemd service, not inside a Docker container. Docker Compose environments are addressed via `localhost:{port}` from the host.

**Why:** Swapping Nginx configs requires reloading or restarting Nginx — trivial when Nginx is a host process. If Nginx were inside Docker, you would need to rebuild an Nginx container for every config change, which breaks the zero-downtime contract.

**Trade-offs:**
- Pro: Atomic config swap via symlink + `nginx -s reload` — zero downtime
- Pro: Direct access to host Docker network (containers reachable via `localhost`)
- Pro: No Docker networking complexity for the router
- Con: Nginx config management must be done via SSH/Ansible, not Docker
- Con: Nginx version is determined by the EC2 AMI, not controlled by the project

### Pattern 2: Static Port Assignment per Environment

**What:** Each environment (blue/green) is assigned a fixed internal port (e.g., 8080, 8081) that never changes. Nginx upstream points to that port. The environment is started or stopped; the port stays the same.

**Why:** Dynamic port allocation (Docker assigning a random host port via `ports: - "3000:3000"`) creates uncertainty — you cannot predict which port the new environment will use before starting it. Fixed ports mean Nginx config can be pre-written and just activated.

**Trade-offs:**
- Pro: Nginx config is static — no dynamic port discovery needed
- Pro: Rollback is instant — just flip Nginx upstream, old environment still on its fixed port
- Con: Ports must be reserved and documented (8080=blue, 8081=green, 27018=blue-mongo, 27019=green-mongo)
- Con: Only two environments possible (extend with ports 8082, 8083 for canary if needed)

### Pattern 3: Docker Compose Project Prefix Isolation

**What:** Each environment uses `docker compose -p blue-` or `docker compose -p green-` to prefix all container names and network names.

**Why:** Without prefixes, `docker ps` shows generic names and `docker compose down` might affect the wrong environment if working directory is wrong. Prefixes create clear namespace separation.

**Example:**
```bash
# In /opt/blue/
docker compose -p blue- -f docker-compose.yml up -d

# In /opt/green/
docker compose -p green- -f docker-compose.yml up -d

# Both can run simultaneously without naming conflicts
# Container names: blue-api-1, blue-mongo-1 vs green-api-1, green-mongo-1
```

---

## Integration Points

### With Existing multi-container-service

| Integration Point | Method | Risk | Mitigation |
|-------------------|--------|------|------------|
| Host Nginx | Shared Nginx process, separate config files | Blue-green CI accidentally overwrites `default` config | Use separate filenames (`blue-green-*`) — never touch `default` |
| Docker daemon | Same host, same daemon | Blue-green containers visible to multi-container-service via `docker ps` | Use `blue-` and `green-` prefixes — keeps namespace clean |
| EC2 instance | Same host, same security group | Port conflicts, resource contention (CPU/memory) | Reserve ports 8080-8081 and 27018-27019 for blue-green |
| GitHub Actions | Separate repo, separate workflow | None — fully isolated pipeline | — |

### External Services

| Service | Integration | Notes |
|---------|-------------|-------|
| AWS EC2 | SSH (port 22) for all remote operations | Reuse existing `ec2-static-site-key.pem` |
| Docker Hub | Pull images during deployment | `docker compose -p {env}- pull` before `up -d` |
| GitHub Actions | Trigger on push to main | Separate `deploy.yml`, separate secrets |
| Health endpoint | `GET /health` on deployed API | Returns 200 + JSON when ready; must be implemented in Node.js API |

---

## Scaling Considerations

Blue-green on a single EC2 instance is inherently scale-limited. This is appropriate for v1.

| Scale | What Breaks | Mitigation |
|-------|-------------|------------|
| 0-100 RPS | Nothing (single instance fine) | — |
| 100-500 RPS | CPU contention between blue/green containers and multi-container-service | Separate EC2 instance for blue-green when RPS exceeds ~200 sustained |
| 500+ RPS | Single EC2 cannot handle blue-green + multi-container-service + MongoDB on one instance | Migrate to EKS (see multi-container-service project plan) or separate EC2 for blue-green |

**Horizontal scaling for blue-green itself:** At higher scale, the pattern evolves to: multiple EC2 instances with a shared load balancer in front, each running blue-green. The Nginx switching pattern stays the same but moves to an LB layer. This is out of scope for v1.

---

## Anti-Patterns

### Anti-Pattern 1: Blue-Green Nginx Inside Docker Compose

**What:** Running Nginx inside each blue-green Docker Compose environment as the router.

**Why it breaks:** When you want to switch from blue to green, you would need to restart or rebuild the Nginx container in the new environment. This causes a brief period where neither Nginx is routing correctly. Additionally, Nginx inside Docker cannot directly route to the other Docker Compose environment's containers without extra networking configuration.

**Instead:** Keep Nginx on the host as a single, always-running process. Each blue-green environment just exposes its API on a fixed host port. Nginx switches upstream — no container restart needed.

### Anti-Pattern 2: Single Nginx Config File That Gets Rewritten by CI

**What:** CI generates a new Nginx config file from scratch each deployment and overwrites a single config file, then reloads Nginx.

**Why it breaks:** If the config generation fails mid-write or the new config has a syntax error, Nginx fails to reload and goes down. Users see 502. The rollback involves manually fixing the config on the server.

**Instead:** Pre-write two complete, tested Nginx config files (`blue-green-blue.conf` and `blue-green-green.conf`). CI only flips which one is symlinked in `sites-enabled/`. Both configs should be validated with `nginx -t` before the symlink is flipped.

### Anti-Pattern 3: Tearing Down Old Environment Before Confirming New One Works

**What:** Stop and remove old environment containers immediately after deploying the new environment, before health checks pass.

**Why it breaks:** If the new environment fails health checks, you have no running environment to roll back to. You must redeploy from scratch, which takes the full deployment time (build + push + deploy), causing real downtime.

**Instead:** Keep the old environment running until the new environment passes health checks AND a post-deployment smoke test. Only then optionally tear down the old environment. For maximum safety, keep the old environment running until the next successful deployment.

### Anti-Pattern 4: Sharing MongoDB Across Blue/Green Environments

**What:** Both blue and green connect to the same shared MongoDB instance (e.g., the existing multi-container-service MongoDB).

**Why it breaks:** Blue-green deployments share a database schema, so data from blue leaks into green's testing. More critically, if you need to roll back, the database has been migrated forward and cannot be easily reverted. Each environment should have its own MongoDB for true isolation.

**Instead:** Each blue-green environment runs its own MongoDB container (at different ports: 27018, 27019). For production workloads with persistent data requirements, use a shared external database only after the schema migration is confirmed stable, and only for read-heavy scenarios.

---

## Sources

- Confirmed from multi-container-service codebase:
  - `multi-container-service/ansible/playbook.yml` — host-level Nginx + Docker Compose pattern (MEDIUM confidence, internal source)
  - `multi-container-service/nginx/nginx.conf` — upstream configuration and proxy headers (MEDIUM confidence, internal source)
  - `multi-container-service/.github/workflows/deploy.yml` — SSH-based Ansible deployment (MEDIUM confidence, internal source)
- Established blue-green deployment patterns (LOW confidence, drawn from training data / standard Linux operations):
  - nginx.org/en/docs/http/load_balancing.html — upstream module documentation
  - docs.docker.com/compose/reference/ — `docker compose` CLI patterns
  - nginx.org/en/docs/beginners_guide.html — config reload with `nginx -s`

---

*Architecture research for: blue-green-deployment*
*Researched: 2026-04-01*
