# Stack Research: Blue-Green Deployment on Single EC2 Instance with Docker

**Domain:** Zero-downtime deployment infrastructure
**Researched:** 2026-04-01
**Confidence:** MEDIUM-HIGH

> **Research caveat:** Context7, Exa, Brave Search, and Firecrawl are not available in this environment. Findings rely on training knowledge of well-established, stable patterns. Key facts (Nginx upstream switching mechanics, Docker Compose v2 file format) have been stable for years and are unlikely to have changed. Confidence is rated MEDIUM-HIGH because the core patterns are textbook-grade and version-invariant.

---

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

---

## Installation

### On EC2 (one-time)

```bash
# Install Docker Compose v2 (if not already present)
apt-get update && apt-get install -y docker.io docker-compose-v2 httpie jq nginx

# Create blue and green directories
mkdir -p /opt/blue /opt/green

# Verify nginx is running (not disabled)
systemctl enable nginx
systemctl start nginx
```

### In GitHub Actions (workflow dependencies)

```yaml
# No extra packages needed in runner
# Docker and git are pre-installed on ubuntu-latest runners
# Only add: httpie and jq if using a custom container for health checks
- name: Install dependencies
  run: sudo apt-get update && sudo apt-get install -y httpie jq
```

---

## Alternatives Considered

| Recommended | Alternative | When to Use Alternative |
|-------------|-------------|-------------------------|
| Nginx file-swap switching | Socket activation ( systemd socket-based) | Socket activation is more complex and not needed for two-environment blue-green |
| File-based Nginx switching | Consul-template or confd | These add a daemon and external dependency. For single EC2 with two environments, atomic file swap is simpler and sufficient |
| Docker Compose v2 | Kubernetes | Overkill for single-instance brownfield; the existing Docker Compose setup is the right abstraction |
| GitHub Actions | Jenkins, GitLab CI | Jenkins requires a persistent server. GitHub Actions matches the existing project's CI choice |
| Terraform data-only | Terraform-managed EC2 for blue-green | Creates a new instance. Since the requirement is same-instance, data blocks are correct |
| `docker/login-action` | `azure/docker-login` | `azure/docker-login` is deprecated; `docker/login-action` is the official replacement |

---

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

---

## Stack Patterns by Variant

### Variant: Two-Environment Blue-Green on Same EC2

- **Nginx config:** Two files in `/etc/nginx/sites-available/`, swapped via `mv`
- **Docker:** Two compose directories `/opt/blue` and `/opt/green`, each with its own `docker-compose.yml` and `.env`
- **Health check:** Poll `http://localhost:<slot_port>/health` until healthy, then switch
- **Why this pattern:** Simplest possible implementation for same-instance constraint. Avoids systemd socket activation, container orchestrators, and service meshes — all of which add complexity without benefit here

**Directory layout:**

```
/etc/nginx/sites-available/
    blue         # upstream { server 127.0.0.1:3001; }  (blue slot)
    green        # upstream { server 127.0.0.1:3002; }  (green slot)
    active       # symlink: points to whichever slot is live (blue or green)

/etc/nginx/sites-enabled/
    default      # deleted or empty
    active -> /etc/nginx/sites-available/active

/opt/
    blue/
        docker-compose.yml    # api service: port 3001, image: ${DOCKER_IMAGE}
        .env                 # DEPLOY_SLOT=blue, SLOT_PORT=3001
    green/
        docker-compose.yml   # api service: port 3002, image: ${DOCKER_IMAGE}
        .env                 # DEPLOY_SLOT=green, SLOT_PORT=3002

/var/run/
    blue-green-state         # plain text: "blue" or "green" — tracks active slot
```

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

---

## Version Compatibility

| Package A | Compatible With | Notes |
|-----------|-----------------|-------|
| Nginx 1.24 (Ubuntu 22.04) | Docker Compose v2, GitHub Actions | `nginx -s reload` is present since 0.8.52 |
| Docker Compose v2 | Ubuntu 22.04, Docker 24+ | `docker compose` (no hyphen) is the correct command |
| GitHub Actions `appleboy/ssh-agent-action` v0.1.0+ | ubuntu-latest runner | Requires `WEBHOOK_SECRET` or private key in secrets |
| Terraform >= 1.5.0 | AWS provider ~5.0, existing S3 backend | Data-only usage; no breaking changes to data sources |
| Node.js 20 LTS | Docker base image `node:20-alpine` | Alpine base keeps image size minimal |
| MongoDB 7 | Node.js 20, Mongoose 7.x | Unchanged from multi-container-service |

---

## Nginx Switching Strategy (Detailed)

This is the critical mechanism for zero-downtime. Two equivalent approaches:

### Approach A: Atomic File Swap (Recommended)

```
1. Write new config to /etc/nginx/sites-available/green
2. Run: ln -sf /etc/nginx/sites-available/green /etc/nginx/sites-available/active
3. Run: nginx -t && nginx -s reload
```

Nginx reads the symlink target at reload time. The swap is atomic at the filesystem level. In-flight requests to the old upstream complete normally (Nginx keeps old workers alive until they finish). New requests immediately hit the new upstream.

**Why `ln -sf` instead of `mv`:** `ln -sf` atomically updates the symlink in place. `mv` also works but `ln -sf` is more idiomatic for this pattern.

### Approach B: Inline Config with `include` (Alternative)

Have a single Nginx config that `include`s a file, and swap that included file:

```
upstream api_backend {
    include /etc/nginx/upstream.conf;
}
```

Swap `/etc/nginx/upstream.conf` between `server 127.0.0.1:3001;` and `server 127.0.0.1:3002;`, then `nginx -s reload`.

**Why Approach A is preferred:** It keeps blue and green configs self-contained and makes it trivially obvious which slot is active (`cat /etc/nginx/sites-enabled/active`). Approach B requires understanding the include chain.

### Port Assignment

| Slot | Internal Port | External (for health check) |
|------|--------------|------------------------------|
| blue | 3001 | localhost:3001 |
| green | 3002 | localhost:3002 |

Ports must differ. Using the same port for both would require stopping one before starting the other (breaking zero-downtime).

---

## CI/CD Workflow Structure (GitHub Actions)

### Stages (in order)

```
1. Build & Test     — docker build, unit tests
2. Build Image     — docker compose build, docker compose push to registry
3. Deploy to inactive slot — SSH to EC2, docker compose -f /opt/<inactive>/docker-compose.yml up -d
4. Health check     — Poll http://localhost:<inactive_port>/health, max 60s
5. Switch Nginx     — mv symlink, nginx -s reload
6. Update state     — Write "green" or "blue" to /var/run/blue-green-state
7. Optional teardown — docker compose down on old slot (or keep running for instant rollback)
```

### Rollback Path

If health check fails after step 4:
- Do NOT switch Nginx
- Report failure in CI
- Old slot remains active (traffic unchanged)
- Developer investigates

If switch succeeds but new version is bad:
- CI or manual: swap active symlink back to previous slot, `nginx -s reload`
- No redeploy needed — old container is still running

---

## Terraform: Data-Only Usage

Since the EC2 instance, security group, VPC, and key pair are already managed by `multi-container-service`, Terraform in this project is read-only:

```hcl
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "ap-southeast-2"
}

# Reuse existing VPC
data "aws_vpc" "default" {
  default = true
}

# Reuse existing subnet (from multi-container-service)
data "aws_subnet" "app" {
  id = "subnet-0169389af48015c56"
}

# Reuse existing security group
data "aws_security_group" "app" {
  id = "sg-0af639883552f9a6a"
}

# Reuse existing key pair
data "aws_key_pair" "app" {
  key_name = "ec2-static-site-key"
}
```

**No resources are created.** Output values (e.g., `data.aws_instance.app_server.public_ip`) may be useful for documentation or validation in future phases.

---

## Sources

> **Confidence note:** All sources below are based on training knowledge. No web-based verification was performed due to tool unavailability in this environment.

- Nginx `nginx -s reload` behavior — [nginx.org/docs](https://nginx.org/en/docs/control.html) — Reliability: HIGH (stable documentation)
- Docker Compose v2 command reference — [docs.docker.com/compose](https://docs.docker.com/compose/reference/) — Reliability: HIGH (stable spec)
- GitHub Actions `docker/login-action` — [github.com/docker/login-action](https://github.com/docker/login-action) — Reliability: HIGH (official action)
- GitHub Actions `appleboy/ssh-agent-action` — [github.com/appleboy/ssh-agent-action](https://github.com/appleboy/ssh-agent-action) — Reliability: MEDIUM-HIGH (widely used community action)
- Blue-green deployment pattern — Martin Fowler (martinfowler.com/bliki/BlueGreenDeployment.html) — Reliability: HIGH (canonical source)
- Terraform data sources — [registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources) — Reliability: HIGH

---
*Stack research for: Blue-Green Deployment on Single EC2 with Docker*
*Researched: 2026-04-01*
