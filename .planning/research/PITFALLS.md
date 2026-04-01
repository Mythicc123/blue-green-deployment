# Pitfalls Research

**Domain:** Blue-Green Deployment on AWS EC2 with Docker Compose + Nginx
**Researched:** 2026-04-01
**Confidence:** MEDIUM — WebSearch unavailable; findings from documented deployment patterns, Docker Compose behavior, Nginx reload semantics, and known CI/CD failure modes. Known production post-mortems, Stack Overflow threads, and CNCF operational runbooks support these findings. Confidence would be raised with web verification.

---

## Critical Pitfalls

### Pitfall 1: Database Migrations Destroy the Active Environment

**What goes wrong:**
Migrations run against the shared MongoDB instance immediately break the currently-live environment. For example, a migration drops a deprecated collection or renames a field that the live (active) version of the application still depends on. Users immediately see 500 errors even though the "switch" has not happened yet.

**Why it happens:**
Blue-green on a single EC2 instance shares one MongoDB between both environments. Both blue and green containers connect to the same DB. If the migration is applied before the switch, it affects the live environment. If applied after the switch, it means the old environment cannot be used as a rollback target. There is no safe window.

**How to avoid:**
- **Migrations must be backward-compatible for at least two versions.** The old environment must survive after the new environment's migration has run. Rule: migrations must be additive (add fields, add collections) and old code must tolerate new schema, or use feature flags / environment-specific DBs for breaking changes.
- **Run migrations before the switch, but only if the migration is backward-compatible.** Test the migration against a copy of production data first.
- **Prefer approach where migrations run inside the new environment container startup** (via a startup script), so they run against the new code, not the old code.
- **Keep the old environment alive for a rollback window** after the switch. Do not tear it down immediately.

**Warning signs:**
- Migration scripts drop columns, rename fields, or remove collections
- No rollback script for the migration
- Migration assumes the new code version is already live

**Phase to address:**
Phase 2 (Environment Setup / Docker Compose Structure) — must establish migration runbook and backward-compatibility contract before any deployment pipeline is built.

---

### Pitfall 2: Nginx Switch Race Condition Leaves Requests Unrouted

**What goes wrong:**
During `nginx -s reload`, there is a brief window (~100-500ms) where Nginx closes existing connections and re-reads the config. If a health check passes but the Nginx reload fails silently, requests go to a non-existent upstream and users get 502/503 errors. Conversely, if the health check runs against a container that is still starting, it passes too early and the switch sends traffic to a broken environment.

**Why it happens:**
- Nginx reload (`nginx -s reload`) does not guarantee atomic config swap
- The default Nginx health check uses `fail_timeout` and `max_fails` on upstream servers, but does not actively probe a health endpoint
- GitHub Actions may run health checks from outside the EC2 instance (via public IP), hitting the same Nginx being reconfigured, creating a chicken-and-egg problem
- Container may report healthy to Docker but not yet be ready to serve application requests (e.g., MongoDB connection not yet established)

**How to avoid:**
- **Use Docker healthchecks that verify the full stack**, not just the container process. For the Node.js app, the healthcheck must `curl localhost:<port>/health` and confirm MongoDB connectivity, not just `curl localhost:<port>`.
- **Always health-check via `localhost`** from within the EC2 instance (via Ansible or SSH), not from GitHub Actions via the public IP. External health checks hit the same Nginx being reloaded, causing false negatives or positives.
- **Run `nginx -t` before reloading.** Verify config syntax before applying: `nginx -t && nginx -s reload`.
- **Add a pre-switch sanity check:** verify the inactive environment is responding on its internal port (e.g., blue-api:3000) before touching Nginx.
- **Use `nginx reload` instead of `nginx restart`** — restart drops all active connections; reload maintains them during the transition.
- **Introduce a deliberate delay** (e.g., 5-10 seconds) after the Nginx config switch before declaring the switch complete, to catch any immediate failures.

**Warning signs:**
- 502 Bad Gateway immediately after a deployment
- Health check passes but application returns 500
- `nginx -s reload` returns exit code 0 but config is not applied
- GitHub Actions health check from external IP fails during switch but succeeds after

**Phase to address:**
Phase 3 (Nginx Configuration & Switching Logic) — the switching script must include local health checks, config validation, and post-switch verification.

---

### Pitfall 3: Session Loss on Environment Switch

**What goes wrong:**
Users who are logged in or have active sessions lose their session immediately after the Nginx switch. In-memory session stores (e.g., Node.js in-memory session or a memory-backed JWT validation) lose state because the new container has a fresh memory space. Users are unexpectedly logged out or see data loss.

**Why it happens:**
Both blue and green containers are separate processes with separate memory. Sessions stored in-process (or in a container-local Redis/Memory) do not survive the switch. The project description mentions "shared MongoDB" — if sessions are stored in MongoDB this is not a problem, but if sessions are in-memory or use a container-local store, they are lost.

**How to avoid:**
- **Store sessions in MongoDB** (e.g., `connect-mongo`) so they survive environment switches. This is the simplest solution given the shared MongoDB already exists.
- **If using JWT:** ensure JWT validation does not depend on container-local state (signing keys must be in a shared secret store accessible to both environments, not baked into the container image).
- **If using Redis:** use a shared Redis instance across both environments (not container-local).
- **Warn users** of a brief session reset during deployments — acceptable for non-critical apps.
- **Never store sessions in Docker container filesystem** — they are ephemeral.

**Warning signs:**
- Sessions stored in `express-session` with MemoryStore adapter
- JWT signing key embedded in the container image via `ENV`
- User reports "logged out after every deploy"
- No session TTL configured (sessions grow indefinitely)

**Phase to address:**
Phase 1 (Project Foundation) — determine session storage strategy before Docker Compose files are written. Retrofitting session storage is a breaking change.

---

### Pitfall 4: GitHub Actions Concurrent Deployment Overwrites the Same Environment

**What goes wrong:**
Two deployments triggered in quick succession (e.g., a hotfix while a staged rollout is running) both detect the same inactive environment and both try to deploy to it simultaneously. They overwrite each other's container, health checks interleave, and the Nginx switch points to a partially-started container.

**Why it happens:**
The CI/CD pipeline reads the current active environment from a state file or Nginx config, decides which environment is inactive, and deploys to it. There is no locking mechanism. If two workflows run at the same time, they both compute the same inactive environment.

**How to avoid:**
- **Implement a deployment lock using a file on the EC2 instance** (e.g., `/tmp/blue-green-deploy.lock`). Ansible or an SSH script acquires the lock before starting deployment, releases it on completion or failure. If the lock exists, the second deployment fails immediately with a clear message.
- **Set a GitHub Actions concurrency group** on the workflow to cancel or queue in-flight runs: `concurrency: { group: blue-green-deploy, cancel-in-progress: true }`.
- **Store active environment state in a shared location** (e.g., a text file in an S3 bucket, or the Ansible vault) so both the CI/CD and any manual deployments agree on which environment is active.
- **Timeout the lock:** if a deployment crashes holding the lock, the lock file should have a TTL (e.g., created with a timestamp, expired after 10 minutes).

**Warning signs:**
- Docker Compose logs show two `docker compose up` processes for the same environment
- Health check flapping between pass/fail during a deployment
- GitHub Actions run succeeds but the deployed version is not the expected one
- Ansible reports `/opt/blue` directory already has a running container when a new deploy is starting

**Phase to address:**
Phase 4 (CI/CD Pipeline) — locking must be built into the workflow from day one; retrofitting it is messy.

---

### Pitfall 5: CI/CD Pipeline Skips or Mishandles Rollback

**What goes wrong:**
A deployment fails mid-way (e.g., health check never passes, or Nginx switch fails), but the pipeline exits with success or does not have a defined rollback procedure. The system is left in a half-switched state — Nginx points to the new environment but the new environment is broken — and an engineer must manually intervene, often during an incident.

**Why it happens:**
Rollback is treated as "nice to have" and implemented as a manual runbook instead of an automated pipeline step. Engineers are not available during the incident to manually roll back. The old environment may have been torn down already.

**How to avoid:**
- **Rollback must be automated and pipeline-native.** The same pipeline that deploys forward must be able to re-run with a `--rollback` flag or a `ROLLBACK_TO=<version>` input that: (a) switches Nginx back to the old environment, (b) re-starts the old container, (c) verifies the old environment is healthy.
- **Never tear down the old environment immediately after a switch.** Keep it running for a minimum rollback window (e.g., 30 minutes or 3 deployments, whichever is longer).
- **The pipeline must exit with failure** if the health check after the Nginx switch fails, and it must NOT modify the Nginx config on failure — the switch should be atomic (either fully complete or fully reverted).
- **Write the rollback procedure as code, not a runbook.** If you cannot run it in 30 seconds during an incident, it is not a rollback plan.

**Warning signs:**
- No rollback step in the GitHub Actions workflow
- Old environment container is stopped immediately after a successful switch
- Pipeline does not check Nginx config state after a failed deployment
- "Rollback" requires SSH-ing into the instance manually

**Phase to address:**
Phase 4 (CI/CD Pipeline) — define rollback as a first-class pipeline action, not an afterthought.

---

### Pitfall 6: Docker Image Tag `latest` Causes Non-Deterministic Deploys

**What goes wrong:**
Docker Compose pulls `image: node:20` or `image: myapp:latest`. A deployment runs `docker compose pull` before deploying, and gets a newer image that was pushed after the commit being deployed. The wrong version is live. Or worse: `latest` was not updated for the current deployment, so the old version is deployed.

**Why it happens:**
`latest` is a moving target. Developers forget to tag the new image with `latest` after pushing, or another developer pushes a different commit before the pipeline completes. The pipeline has no reproducibility — each run is a gamble.

**How to avoid:**
- **Always use immutable, versioned tags** in Docker Compose: `image: myapp:v1.2.3`. The GitHub Actions pipeline must derive the tag from the Git ref (e.g., `git rev-parse --short HEAD` or a semantic version tag).
- **Pin the image SHA in production** for cryptographic reproducibility: `image: myapp@sha256:abc123...`. GitHub Actions can tag the image with the full SHA at push time.
- **Never use `latest` in a Compose file checked into source control.** It should not exist in the repo's production Compose file at all.

**Warning signs:**
- `image:` field in docker-compose.yml contains `latest` or `main`
- No image tagging step in the CI/CD pipeline
- Pipeline does not record which image SHA was deployed
- "It was deployed but it looks like the old code"

**Phase to address:**
Phase 4 (CI/CD Pipeline) — image tagging and SHA tracking are pipeline foundation.

---

### Pitfall 7: MongoDB Connection String Hard-Coded Inside Container Image

**What goes wrong:**
The MongoDB connection string is baked into the Docker image via `ENV MONGO_URI=...`. When blue and green both start, they read the same env from their baked-in image. If the MongoDB host changes, both environments must be rebuilt rather than updated via environment variable override.

**Why it happens:**
Developers use `ENV` in the Dockerfile for convenience during local development and never refactor it to a runtime variable. The `.env` file is used locally but the image is considered "the source of truth."

**How to avoid:**
- **Use `.env` files for environment-specific configuration** and load them via `docker compose --env-file`. Blue gets `/opt/blue/.env`, green gets `/opt/green/.env`. The image itself contains no environment-specific values.
- **The Dockerfile should have no `ENV` statements for runtime secrets** — only build-time constants (e.g., `NODE_ENV=production`).
- **Store `.env` files on the EC2 instance, not in Git.** The `.env` files contain the MongoDB connection string and other secrets and must not be committed. Use Ansible's `template` or `copy` module to manage them on the instance.

**Warning signs:**
- `ENV MONGO_URI` or `ENV MONGODB_URL` in the Dockerfile
- `.env` files committed to the GitHub repository
- No `.dockerignore` ignoring `.env` files at build time
- Container logs show connection errors because the baked-in URI differs from the actual DB host

**Phase to address:**
Phase 1 (Project Foundation) — define the environment variable strategy before Docker files are written.

---

### Pitfall 8: Ansible Not Idempotent — Re-Running Breaks the Environment

**What goes wrong:**
Running `ansible-playbook site.yml` a second time (e.g., after a failure, or for a second environment) breaks the existing setup — Nginx config gets overwritten with a default, containers are restarted unexpectedly, or services are disabled.

**Why it happens:**
Ansible tasks use `command` or `shell` modules instead of idempotent alternatives (`copy`, `template`, `service`, `docker_compose`). Tasks do not have proper `creates`/`removes` guards. Handlers trigger at the wrong time.

**How to avoid:**
- **Use Ansible modules designed for the resource** instead of raw shell commands: use `docker_container` module instead of `shell: docker run`; use `template` for Nginx configs instead of `copy`; use `systemd` module for service management.
- **Add `creates`/`removes` checks** to shell/command tasks: `- shell: ... creates=/path/to/file`.
- **Write handlers for service reloads**, not immediate restarts. Handlers only trigger if a task actually changes something.
- **Test idempotency by running the playbook twice** on a staging environment before any deployment. The second run must report `changed=0`.
- **Use `check` mode** (`ansible-playbook --check`) to preview what would change before applying.

**Warning signs:**
- `shell:` or `command:` tasks that create files or start services without `creates` guards
- No handlers defined for Nginx reload
- Second playbook run shows "changed" on tasks that should be idempotent
- Docker container starts with `docker run` in a shell task instead of `docker_container` module

**Phase to address:**
Phase 2 (Environment Setup) — Ansible playbooks must be written for idempotency from the start.

---

## Technical Debt Patterns

| Shortcut | Immediate Benefit | Long-term Cost | When Acceptable |
|----------|-------------------|----------------|-----------------|
| Skip health check and rely on "wait 30s" | Faster pipeline | Unknown container startup time; false confidence | Never — even in MVP |
| Use `docker-compose up -d` without health checks | Simpler command | No way to know if container is ready | Never for production |
| Deploy to same environment as active (in-place update) | No extra resources | No rollback path; downtime during deploy | Only for config-only changes |
| Keep old environment up but ignore it | Saves cleanup time | Stale environment consumes resources, confuses debugging | Only during rollback window |
| SSH into EC2 to manually trigger deployment | Faster iteration | No audit trail; non-reproducible; blocks during incidents | Only during initial debugging, never in production |
| Skip rollback testing | Saves time before launch | Rollback procedure unknown; incident response is manual | Never — test rollback before first production deploy |

---

## Integration Gotchas

| Integration | Common Mistake | Correct Approach |
|------------|----------------|------------------|
| GitHub Actions -> EC2 | Using password/key auth that times out or requires manual SSH key setup | Use EC2 Instance Connect or pre-configured SSH key with `StrictHostKeyChecking=no` or known host in `known_hosts` |
| Ansible -> EC2 | Ansible controller node not set up on the instance; requiring laptop to run playbook | Either run Ansible from a local script that SSHs to EC2, or set up a bastion/Ansible controller on the instance |
| Nginx -> Docker containers | Hardcoded upstream IP addresses in Nginx config | Use Docker network DNS names (e.g., `blue-api`) or `localhost` with port mapping; do not use container IPs |
| GitHub Actions health check | Checking the public IP before Nginx has switched | Health check the internal Docker network port (`localhost:3001` for blue, `localhost:3002` for green) from within the EC2 |
| MongoDB connection | Connecting to `localhost:27017` from inside a container | Use Docker network name or host IP; containers cannot reach `localhost` of the host |
| Docker Compose networking | Both blue and green on the same Docker network — port conflict | Assign different internal ports: blue on `127.0.0.1:3001`, green on `127.0.0.1:3002`; expose only Nginx on port 80 |

---

## Performance Traps

| Trap | Symptoms | Prevention | When It Breaks |
|------|----------|------------|----------------|
| Both blue and green running simultaneously | EC2 CPU/memory doubled; performance degradation | Only start the inactive environment during deployment; stop it after rollback window | Always — even for small Node.js apps; EC2 T3 micro will OOM |
| No resource limits on containers | Blue+Green+MongoDB+Nginx compete for RAM; OOM kills | Set `mem_limit` and `cpu_shares` in docker-compose.yml; monitor with `docker stats` | At ~100 concurrent users on a t3.medium |
| Health check polling too frequently | EC2 load from repeated curl requests during deployment | Use exponential backoff in health check script; 5-second interval, max 60 seconds | During every deployment |
| MongoDB becomes the bottleneck | Both blue and green hammering the same MongoDB | Add indexes proactively; monitor slow queries; connection pooling in Mongoose (`maxPoolSize`) | At ~500 concurrent requests across both environments |

---

## Security Mistakes

| Mistake | Risk | Prevention |
|---------|------|------------|
| `.env` files committed to GitHub repository | MongoDB credentials, JWT secrets exposed publicly | Add `.env` to `.gitignore`; use Ansible to manage env files on the instance; never put secrets in Docker images |
| SSH private key stored in GitHub Actions secrets without rotation | Key compromise allows unauthorized EC2 access | Use IAM roles / EC2 Instance Connect instead; rotate keys regularly; use short-lived credentials |
| Nginx config allows direct access to Docker container ports | Users bypass Nginx and hit containers directly | Bind Docker container ports to `127.0.0.1` only, not `0.0.0.0`; Nginx is the only public-facing service |
| No rate limiting on Nginx | Deployment script or attacker can overwhelm the API | Add `limit_req_zone` in Nginx for IP-based rate limiting; protect `/admin` or sensitive endpoints |
| Running containers as root | Container escape gives root on EC2 | Define `USER` in Dockerfile; run as non-root (UID 1000+); verify with `docker inspect` |

---

## UX Pitfalls

| Pitfall | User Impact | Better Approach |
|---------|-------------|-----------------|
| Users see 502 for several seconds during Nginx switch | Apparent downtime; support tickets | Use Nginx `upstream` with `slow_start`; graceful reload instead of restart; advertise a 30-second maintenance window |
| No user-facing deployment status page | Users cannot know if an outage is expected or a bug | At minimum, a `GET /status` endpoint that shows active environment and version; display version number in UI footer |
| API version not exposed in responses | Users cannot tell which environment is serving them | Include `X-App-Version` and `X-Environment` headers in all API responses; show version in frontend footer |
| Deployments happen without user notice during peak traffic | Peak-time deploy causes latency spike | Schedule deployments during low-traffic windows; add a deployment window check in the CI/CD pipeline |

---

## "Looks Done But Isn't" Checklist

- [ ] **Health check:** Returns HTTP 200 but does not verify MongoDB connectivity — the container is running but the app is broken. Add a DB ping to the `/health` endpoint.
- [ ] **Rollback:** Pipeline has a "rollback" step but it has never been tested in staging — it will fail at 2am. Test it before going to production.
- [ ] **Nginx switching:** Uses `nginx restart` instead of `nginx reload` — drops all active connections. Verify the switching script uses `reload`, not `restart`.
- [ ] **Deployment state:** No state file tracking which environment is active — manual deployments and CI/CD disagree about which environment is live. Store active environment in a known file (`/opt/.active-environment`).
- [ ] **Old environment cleanup:** Old container is left running indefinitely — accumulates resources, creates confusion about which is active. Implement an automated cleanup after the rollback window.
- [ ] **Database migration:** Migration is forward-only with no rollback SQL — a failed migration cannot be undone. Always write both forward and rollback migration scripts.
- [ ] **Concurrency protection:** CI/CD has no deployment lock — two concurrent runs can corrupt the deployment. Implement a lock file or GitHub Actions concurrency group.
- [ ] **Environment parity:** Blue and green have slightly different `.env` files — intermittent bugs that only appear in one environment. Use Ansible to ensure both env files are identical except for the `ENVIRONMENT=blue|green` variable.

---

## Recovery Strategies

| Pitfall | Recovery Cost | Recovery Steps |
|---------|---------------|----------------|
| Nginx switch points to broken container | MEDIUM | Immediately run `ansible/playbook.yml --tags switch-back` or equivalent; Nginx switch to the other environment; verify `curl localhost:<old-port>` returns 200 |
| Migration broke the active environment | HIGH | Revert the MongoDB migration (restore from backup or run rollback script); switch Nginx back to old environment; old environment must still be running |
| Concurrent deployment corrupted inactive environment | LOW | Stop all containers in the corrupted environment (`docker compose -f /opt/<env>/docker-compose.yml down`); re-run the full deployment pipeline for that environment |
| Docker image tag collision (wrong version deployed) | LOW | Re-tag the correct image with the expected tag; re-run health check; if Nginx already switched, switch back and forward again |
| Ansible playbook breaks existing setup | MEDIUM | Re-run the playbook — if idempotent, it will converge to the correct state. If not idempotent, manually restore from backup or redeploy the environment from scratch |

---

## Pitfall-to-Phase Mapping

| Pitfall | Prevention Phase | Verification |
|---------|------------------|--------------|
| Database migrations destroying active environment | Phase 2 (Environment Setup) — migration runbook + backward-compatibility contract | Migration tested against live environment with old code running; rollback tested |
| Nginx switch race condition | Phase 3 (Nginx Configuration & Switching) — local health checks, config validation, reload strategy | Deploy to staging; kill the new container mid-startup; verify Nginx does not switch |
| Session loss on environment switch | Phase 1 (Project Foundation) — session storage strategy | Verify sessions survive an environment switch; test with a logged-in user |
| Concurrent deployment overwriting same environment | Phase 4 (CI/CD Pipeline) — deployment lock | Two workflows triggered simultaneously; second should fail immediately with lock error |
| CI/CD skips or mishandles rollback | Phase 4 (CI/CD Pipeline) — automated rollback | Kill the new container 30 seconds after switch; verify pipeline auto-rolls back |
| Docker image tag `latest` causes non-deterministic deploys | Phase 4 (CI/CD Pipeline) — immutable tagging | Pipeline logs show the image SHA; redeploy same SHA produces identical environment |
| MongoDB connection string baked into image | Phase 1 (Project Foundation) — env file strategy | Image rebuilt without `.env`; verify connection works via runtime env |
| Ansible not idempotent | Phase 2 (Environment Setup) — idempotent playbooks | Run playbook twice; second run must show `changed=0` on all tasks |
| Both environments running simultaneously consuming resources | Phase 2 (Environment Setup) — resource limits | Run both environments; verify `docker stats` shows limits applied |
| No state file tracking active environment | Phase 3 (Nginx Configuration & Switching) | Read `/opt/.active-environment` before and after switch; matches actual Nginx config |

---

## Sources

- Docker Compose production patterns — official documentation (MEDIUM confidence — WebSearch unavailable for verification)
- Nginx reload semantics and upstream health check behavior — nginx.org documentation (MEDIUM confidence)
- Blue-green deployment failure post-mortems — various engineering blog posts on blue-green patterns (MEDIUM confidence)
- AWS EC2 Docker deployment known issues — AWS documentation and community forums (MEDIUM confidence)
- GitHub Actions concurrency and locking patterns — GitHub Actions documentation (HIGH confidence)
- Ansible idempotency best practices — Ansible documentation (HIGH confidence)
- Session management in containerized Node.js applications — Mongoose/Express community patterns (MEDIUM confidence)

---

*Pitfalls research for: Blue-Green Deployment on AWS EC2 with Docker Compose + Nginx*
*Researched: 2026-04-01*
