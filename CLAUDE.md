<!-- GSD:project-start source:PROJECT.md -->
## Project

Project not yet initialized. Run /gsd:new-project to set up.
<!-- GSD:project-end -->

<!-- GSD:stack-start source:research/STACK.md -->
## Technology Stack

## Recommended Stack
### Core Technologies
| Technology | Version | Purpose | Why Recommended |
|------------|---------|---------|-----------------|
| Nginx | 1.24+ (Ubuntu 22.04 default) | Traffic switching between blue/green | Industry standard for zero-downtime switching via `nginx -s reload`; replaces entire upstream block atomically with `mv`; `proxy_connect_timeout 0` avoids dropped connections during reload |
| Docker Compose | v2 (standalone `docker compose`) | Container orchestration per environment | V2 uses Compose Specification (no version key needed). Each environment (`/opt/blue`, `/opt/green`) is a self-contained compose directory. `docker compose up -d --wait` is the canonical health-wait command |
| GitHub Actions | Latest (workflows) | CI/CD pipeline | Official `azure/docker-login` equivalent replaced by `docker/login-action`; `appleboy/ssh-agent-action` for remote SSH commands |
| Terraform | >= 1.5.0 (data-only) | Infra discovery, not provisioning | Existing EC2 instance, SG, VPC, key pair are referenced via `data` blocks. Terraform does zero resource creation. Remote state backend reuses `mythicc-multi-container-tf-state` S3 bucket |
| Node.js | 20.x LTS (unchanged) | Application runtime | Matches existing multi-container-service. No change needed for blue-green |
### Supporting Libraries
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| `docker/login-action` | v3 | Authenticate to Docker Hub / ECR in CI | Always — required for `docker compose push` in GitHub Actions |
| `appleboy/ssh-agent-action` | v0.1.0+ | Run SSH commands remotely in CI | Always — deploys to EC2, runs health checks |
| `awslabs/amazon-ecr-credential-helper` | latest | ECR credential fetching | Only if pushing to ECR instead of Docker Hub |
| `httpie` | latest (via apt) | HTTP health check in CI | Preferred over `curl` for cleaner JSON output and exit codes; `curl` is acceptable fallback |
| `jq` | latest (via apt) | Parse JSON health check responses in CI | Required for asserting `health.status == "ok"` in shell scripts |
### Development Tools
| Tool | Purpose | Notes |
|------|---------|-------|
| `docker compose` (v2) | Local environment validation | `docker compose -f docker-compose.blue.yml config --quiet` validates file syntax |
| `ssh` | Manual deployment, rollback | `ssh -o StrictHostKeyChecking=no -i ec2-static-site-key.pem ubuntu@13.236.205.122` |
| `nginx -t` | Validate config before reload | Always run before `nginx -s reload` |
| `docker compose ps` | Verify container health locally | Check `Status` column shows `(healthy)` before switching |
## Installation
### On EC2 (one-time)
# Install Docker Compose v2 (if not already present)
# Create blue and green directories
# Verify nginx is running (not disabled)
### In GitHub Actions (workflow dependencies)
# No extra packages needed in runner
# Docker and git are pre-installed on ubuntu-latest runners
# Only add: httpie and jq if using a custom container for health checks
- name: Install dependencies
## Alternatives Considered
| Recommended | Alternative | When to Use Alternative |
|-------------|-------------|-------------------------|
| Nginx file-swap switching | Socket activation ( systemd socket-based) | Socket activation is more complex and not needed for two-environment blue-green |
| File-based Nginx switching | Consul-template or confd | These add a daemon and external dependency. For single EC2 with two environments, atomic file swap is simpler and sufficient |
| Docker Compose v2 | Kubernetes | Overkill for single-instance brownfield; the existing Docker Compose setup is the right abstraction |
| GitHub Actions | Jenkins, GitLab CI | Jenkins requires a persistent server. GitHub Actions matches the existing project's CI choice |
| Terraform data-only | Terraform-managed EC2 for blue-green | Creates a new instance. Since the requirement is same-instance, data blocks are correct |
| `docker/login-action` | `azure/docker-login` | `azure/docker-login` is deprecated; `docker/login-action` is the official replacement |
## What NOT to Use
| Avoid | Why | Use Instead |
|-------|-----|-------------|
| `nginx -s stop` + `nginx` | Drops in-flight requests during reload | `nginx -s reload` — graceful, zero-downtime |
| `docker-compose` (v1, hyphenated) | Deprecated; removed from most distributions | `docker compose` (v2, space) |
| `upstream` block with `server` IPs that differ per slot | Requires pre-defined ports per environment | Single port (e.g., 3000) per environment; Nginx swaps the entire upstream block via `mv` |
| `service nginx restart` | Kills all Nginx workers immediately, dropping connections | `service nginx reload` or `nginx -s reload` |
| `aws_ebs_csi_driver` or Kubernetes-native tools | Overkill; the existing Docker setup is the right level | Stick with Docker Compose on the existing instance |
| Terraform to create a separate EC2 for green | Violates the same-instance constraint | Use Docker Compose directories on the existing instance |
| Blue-green with a shared container name | MongoDB container name conflict if both run simultaneously | Each environment is a separate `docker compose -f <dir>/docker-compose.yml` with no shared volume conflicts |
| Hardcoding `blue` or `green` in docker-compose filenames | Makes automation harder | Use `docker-compose.blue.yml` and `docker-compose.green.yml` with an environment variable `DEPLOY_SLOT` |
## Stack Patterns by Variant
### Variant: Two-Environment Blue-Green on Same EC2
- **Nginx config:** Two files in `/etc/nginx/sites-available/`, swapped via `mv`
- **Docker:** Two compose directories `/opt/blue` and `/opt/green`, each with its own `docker-compose.yml` and `.env`
- **Health check:** Poll `http://localhost:<slot_port>/health` until healthy, then switch
- **Why this pattern:** Simplest possible implementation for same-instance constraint. Avoids systemd socket activation, container orchestrators, and service meshes — all of which add complexity without benefit here
### Variant: Shared MongoDB (from multi-container-service)
- MongoDB runs in the existing `/opt/multi-container-service` or equivalent via `systemd` or the original docker-compose
- Both blue and green containers connect to `MONGO_URL=mongodb://10.0.1.XXX:27017/todos` (the host's Docker bridge IP)
- Do NOT run MongoDB in both blue and green — it would create port 27017 conflicts and data inconsistency
- **Migration path:** If MongoDB needs to move into blue-green later, move it to a third slot or into blue, then reference it from both
### Variant: No Shared MongoDB (each slot is fully isolated)
- Each slot has its own `docker-compose.yml` with a `mongo` service
- Pros: Full isolation, no cross-slot dependency
- Cons: Wastes memory/CPU on a single EC2; database data is not shared between slots
- **Recommendation:** Use shared MongoDB from the existing deployment for v1
## Version Compatibility
| Package A | Compatible With | Notes |
|-----------|-----------------|-------|
| Nginx 1.24 (Ubuntu 22.04) | Docker Compose v2, GitHub Actions | `nginx -s reload` is present since 0.8.52 |
| Docker Compose v2 | Ubuntu 22.04, Docker 24+ | `docker compose` (no hyphen) is the correct command |
| GitHub Actions `appleboy/ssh-agent-action` v0.1.0+ | ubuntu-latest runner | Requires `WEBHOOK_SECRET` or private key in secrets |
| Terraform >= 1.5.0 | AWS provider ~5.0, existing S3 backend | Data-only usage; no breaking changes to data sources |
| Node.js 20 LTS | Docker base image `node:20-alpine` | Alpine base keeps image size minimal |
| MongoDB 7 | Node.js 20, Mongoose 7.x | Unchanged from multi-container-service |
## Nginx Switching Strategy (Detailed)
### Approach A: Atomic File Swap (Recommended)
### Approach B: Inline Config with `include` (Alternative)
### Port Assignment
| Slot | Internal Port | External (for health check) |
|------|--------------|------------------------------|
| blue | 3001 | localhost:3001 |
| green | 3002 | localhost:3002 |
## CI/CD Workflow Structure (GitHub Actions)
### Stages (in order)
### Rollback Path
- Do NOT switch Nginx
- Report failure in CI
- Old slot remains active (traffic unchanged)
- Developer investigates
- CI or manual: swap active symlink back to previous slot, `nginx -s reload`
- No redeploy needed — old container is still running
## Terraform: Data-Only Usage
# Reuse existing VPC
# Reuse existing subnet (from multi-container-service)
# Reuse existing security group
# Reuse existing key pair
## Sources
- Nginx `nginx -s reload` behavior — [nginx.org/docs](https://nginx.org/en/docs/control.html) — Reliability: HIGH (stable documentation)
- Docker Compose v2 command reference — [docs.docker.com/compose](https://docs.docker.com/compose/reference/) — Reliability: HIGH (stable spec)
- GitHub Actions `docker/login-action` — [github.com/docker/login-action](https://github.com/docker/login-action) — Reliability: HIGH (official action)
- GitHub Actions `appleboy/ssh-agent-action` — [github.com/appleboy/ssh-agent-action](https://github.com/appleboy/ssh-agent-action) — Reliability: MEDIUM-HIGH (widely used community action)
- Blue-green deployment pattern — Martin Fowler (martinfowler.com/bliki/BlueGreenDeployment.html) — Reliability: HIGH (canonical source)
- Terraform data sources — [registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources) — Reliability: HIGH
<!-- GSD:stack-end -->

<!-- GSD:conventions-start source:CONVENTIONS.md -->
## Conventions

Conventions not yet established. Will populate as patterns emerge during development.
<!-- GSD:conventions-end -->

<!-- GSD:architecture-start source:ARCHITECTURE.md -->
## Architecture

Architecture not yet mapped. Follow existing patterns found in the codebase.
<!-- GSD:architecture-end -->

<!-- GSD:workflow-start source:GSD defaults -->
## GSD Workflow Enforcement

Before using Edit, Write, or other file-changing tools, start work through a GSD command so planning artifacts and execution context stay in sync.

Use these entry points:
- `/gsd:quick` for small fixes, doc updates, and ad-hoc tasks
- `/gsd:debug` for investigation and bug fixing
- `/gsd:execute-phase` for planned phase work

Do not make direct repo edits outside a GSD workflow unless the user explicitly asks to bypass it.
<!-- GSD:workflow-end -->



<!-- GSD:profile-start -->
## Developer Profile

> Profile not yet configured. Run `/gsd:profile-user` to generate your developer profile.
> This section is managed by `generate-claude-profile` -- do not edit manually.
<!-- GSD:profile-end -->
