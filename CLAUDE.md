# blue-green-deployment — CLAUDE.md

Zero-downtime blue-green deployment on EC2 using Docker, Nginx, and GitHub Actions. Maintained by Mythicc123. Default branch: **master**. Fully complete portfolio project.

## What it does

Deploys a Dockerised application to EC2 with zero downtime by:

1. Building a new Docker image (SHA-tagged)
2. Starting the new container alongside the existing one
3. Running a health check against the new container
4. Atomically switching Nginx upstream to the new container
5. Running a smoke test to verify the switch
6. Stopping and removing the old container
7. On any failure: rolling back to the previous container

## Architecture

- **Compute:** EC2 (ap-southeast-2)
- **Reverse proxy:** Nginx — upstream config swapped atomically during deployment
- **Containers:** Docker, SHA-tagged images (never use `:latest`)
- **CI/CD:** GitHub Actions
- **Locking:** Atomic filesystem lock to prevent concurrent deployments
- **Rollback:** Automatic on health check or smoke test failure

## Key Files

```
.github/
└── workflows/
    └── deploy.yml     # Full pipeline: build → deploy → health check → switch → smoke test
deploy.sh              # Main deployment script — atomic swap logic lives here
nginx/
└── upstream.conf      # Nginx upstream config — rewritten during blue-green switch
```

## Commands

```bash
# Run deployment manually (from EC2)
./deploy.sh

# Check which container is currently active
docker ps

# Check Nginx upstream
cat nginx/upstream.conf

# Roll back manually
./rollback.sh   # if exists, otherwise restart previous container manually
```

> **If modifying the deployment script:**
> - The filesystem lock is critical — do not remove or weaken it. Concurrent deploys corrupt the Nginx config.
> - SHA-tagged images are mandatory — the rollback logic depends on knowing the exact previous image digest
> - Health check must pass before Nginx switch — never skip it
> - Smoke test runs after switch — if it fails, the rollback fires automatically

> **If modifying the Nginx config:**
> - `nginx/upstream.conf` is rewritten by `deploy.sh` — manual edits will be overwritten on next deploy
> - Test Nginx config with: `nginx -t` before reloading
> - Reload (not restart) Nginx to apply upstream changes with zero dropped connections: `nginx -s reload`

## Gotchas

- Default branch is `master`, not `main`
- This project is fully complete — don't add features unless asked. The value is in its clean, readable implementation.
- SHA-tagged images only — `:latest` breaks rollback
- The atomic lock file path is hardcoded in `deploy.sh` — don't move it without updating the script
- Portfolio project: interviewers will read `deploy.sh`. Keep it clean and well-commented.
