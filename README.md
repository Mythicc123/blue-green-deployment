# Blue-Green Deployment System

Zero-downtime deployment for a Node.js Todo API on AWS EC2. Every push to `master` triggers a full pipeline: Docker build → deploy to inactive slot → health check → Nginx switch → smoke test.

**Live pipeline:** https://github.com/Mythicc123/blue-green-deployment/actions

---

## Architecture

```
Internet
   │
   ▼
Nginx (port 80) ─── switches between ───► /opt/blue/  (blue-api container :3001)
   │                                        │
   │                                        └► MongoDB (shared)
   │
   │                                        /opt/green/ (green-api container :3002)
   │                                        │
   └────────────────────────────────────────┘
```

Two Docker Compose environments (`/opt/blue`, `/opt/green`) run simultaneously. Nginx routes traffic to one at a time. Deploying switches the inactive slot, health-checks it, then flips Nginx — zero downtime.

**State:** `/var/run/blue-green-state` contains `blue` or `green` (the currently active slot).

---

## Repository Structure

```
blue-green-deployment/
├── .github/
│   ├── workflows/deploy.yml      # GitHub Actions pipeline
│   └── README-secrets.md         # GitHub Actions secrets setup guide
├── compose/
│   ├── blue/
│   │   ├── docker-compose.yml    # Blue environment (port 3001)
│   │   └── .env                 # Blue env vars
│   └── green/
│       ├── docker-compose.yml    # Green environment (port 3002)
│       └── .env                 # Green env vars
├── nginx/
│   ├── blue-green-blue.conf      # Nginx config pointing to blue (port 3001)
│   └── blue-green-green.conf     # Nginx config pointing to green (port 3002)
├── scripts/
│   ├── deploy.sh                # Pull + start on inactive slot
│   ├── health-check.sh          # Poll health endpoint until healthy
│   ├── switch-nginx.sh          # Switch Nginx symlink + reload
│   ├── run-deploy.sh            # Orchestrator: deploy → health check → switch
│   ├── get-active-slot.sh       # Read /var/run/blue-green-state
│   ├── rollback.sh              # Switch Nginx back to previous slot
│   ├── ec2-lock.sh             # Manual lock diagnostics utility
│   ├── logs.sh                 # Tail container logs
│   ├── setup-envs.sh           # Create /opt directories on EC2
│   └── setup-nginx.sh          # Install Nginx configs on EC2
├── src/                         # Todo API source (Docker build context)
├── Dockerfile                   # Multi-stage Node.js 20 Alpine build
├── package.json
└── package-lock.json
```

---

## How It Works

### CI/CD Pipeline (automated)

Every push to `master` runs the `.github/workflows/deploy.yml` pipeline:

1. **Build & Push** — Docker image built and pushed to Docker Hub with immutable SHA tag (`mythicc123/multi-container-service:sha-<github-sha>`)
2. **Lock** — Atomic mkdir lock acquired at `/tmp/blue-green-deploy.lock` (prevents simultaneous deploys)
3. **Deploy** — Pulls new image to the inactive slot (`/opt/blue` or `/opt/green`)
4. **Health Check** — Polls `http://localhost:<port>/health` until healthy (60s timeout)
5. **Switch** — `ln -sf` swaps Nginx config + `nginx -s reload`
6. **Smoke Test** — GET/POST/PUT/DELETE against public IP
7. **Unlock** — Lock released

### Manual Deployment

```bash
# SSH to EC2
ssh -o StrictHostKeyChecking=no -i ~/.ssh/ec2-static-site-key.pem ubuntu@13.236.205.122

# Run the orchestrator (determines active slot, deploys to inactive, switches)
IMAGE_TAG=sha-<git-sha> bash /tmp/deploy/run-deploy.sh

# Rollback to previous slot (instant — just Nginx switch, no redeploy)
bash scripts/rollback.sh
```

### Manual Lock Management

```bash
# Check lock status
bash scripts/ec2-lock.sh status

# Force-clean a stale lock (TTL expired)
bash scripts/ec2-lock.sh cleanup
```

---

## Requirements

### EC2 Prerequisites

The EC2 instance must have:

- Docker & Docker Compose v2 installed
- Nginx installed and running (not disabled)
- SSH access via `ec2-static-site-key.pem`
- Port 80 (HTTP) open in the security group
- `/opt/blue/` and `/opt/green/` directories created with `docker-compose.yml` + `.env` files

### GitHub Actions Secrets

Configure at **Settings → Secrets and Variables → Actions**:

| Secret | Value |
|--------|-------|
| `EC2_HOST` | `13.236.205.122` |
| `EC2_SSH_KEY` | Full content of `~/.ssh/ec2-static-site-key.pem` (multi-line, unencrypted) |
| `DOCKER_USERNAME` | `mythicc123` |
| `DOCKER_PASSWORD` | Docker Hub password or access token |

See [.github/README-secrets.md](.github/README-secrets.md) for step-by-step setup.

---

## Configuration

### Ports

| Slot | Container Port | Host Port | Nginx health check |
|------|---------------|-----------|--------------------|
| blue | 3000 | 3001 | `http://localhost:3001/health` |
| green | 3000 | 3002 | `http://localhost:3002/health` |

### Nginx Configs

- `/etc/nginx/sites-available/blue-green-blue.conf` — proxies to `localhost:3001`
- `/etc/nginx/sites-available/blue-green-green.conf` — proxies to `localhost:3002`
- Active config symlinked at `/etc/nginx/sites-enabled/blue-green`
- Switched via `ln -sf` + `nginx -s reload` (zero downtime)

### Health Endpoint

`GET /health` returns `{"status":"ok","mongo":"connected"}` when both the app and MongoDB are reachable.

### Todo API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | `/health` | Health check |
| GET | `/todos` | List all todos |
| POST | `/todos` | Create todo (`{"title":"...","completed":false}`) |
| PUT | `/todos/:id` | Update todo |
| DELETE | `/todos/:id` | Delete todo |

---

## Concurrency Control

Two layers prevent simultaneous deployments:

1. **GitHub Actions** — `concurrency: group: ${{ github.repository }}, cancel-in-progress: true` cancels any in-progress run when a new push arrives
2. **EC2 filesystem** — atomic `mkdir` lock at `/tmp/blue-green-deploy.lock` with 10-minute TTL. If a run crashes, the TTL expires and the next run cleans it automatically

---

## IMAGES

### What does NOT change

- **MongoDB** runs in the existing `multi-container-service` deployment (shared between blue and green)
- **EC2 instance** — blue-green runs on the same instance as multi-container-service
- **`latest` tag** is never pushed by CI/CD — only SHA-tagged images

### What DOES change

- **Active slot** (`/var/run/blue-green-state`) — updated after each switch
- **Nginx symlink** — points to blue or green config
- **Inactive slot's image** — updated to the new SHA-tagged image on each deploy

---

## Getting Started

### First-time EC2 setup

```bash
# SSH to EC2
ssh -o StrictHostKeyChecking=no -i ~/.ssh/ec2-static-site-key.pem ubuntu@13.236.205.122

# Create directories
sudo mkdir -p /opt/blue /opt/green

# Copy compose files and .env files to /opt/blue and /opt/green
# (these should be cloned from this repo)

# Install Nginx configs
bash scripts/setup-nginx.sh

# Reload Nginx
sudo nginx -s reload
```

### Trigger a deployment

```bash
# Push to master — pipeline runs automatically
git commit -m "feat: new feature" && git push origin master

# Or trigger manually from GitHub Actions UI
# Actions → "Deploy to EC2 (Blue-Green)" → Run workflow
```

---

## Troubleshooting

### Pipeline fails at lock acquisition

```bash
# Check what's holding the lock
ssh ubuntu@13.236.205.122 "cat /tmp/blue-green-deploy.lock/data"

# Force-clean stale lock
ssh ubuntu@13.236.205.122 "bash /tmp/deploy/ec2-lock.sh cleanup"
```

### Smoke test fails after deploy

```bash
# Check which slot is active
ssh ubuntu@13.236.205.122 "cat /var/run/blue-green-state"

# Check container logs
ssh ubuntu@13.236.205.122 "docker compose -f /opt/blue/docker-compose.yml logs"

# Check Nginx config
ssh ubuntu@13.236.205.122 "sudo nginx -t && readlink /etc/nginx/sites-enabled/blue-green"
```

### Health check times out

```bash
# Check if container is running
ssh ubuntu@13.236.205.122 "docker ps | grep -E 'blue|green'"

# Check MongoDB connectivity
ssh ubuntu@13.236.205.122 "curl http://localhost:3001/health"
```

---

## Reference

This project follows the blue-green deployment pattern described in [Martin Fowler's Bliki](https://martinfowler.com/bliki/BlueGreenDeployment.html).

Inspired by the [Blue-Green Deployment project on roadmap.sh](https://roadmap.sh/projects/blue-green-deployment). [^1]

[^1]: https://roadmap.sh/projects/blue-green-deployment
