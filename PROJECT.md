# Project: Blue-Green Deployment System

**Based on:** multi-container-service (https://github.com/Mythicc123/multi-container-service)

**Last updated:** 2026-04-01

---

## What This Is

A blue-green deployment system that deploys a new version of the multi-container-service application in a separate container environment and switches traffic to the new version only when it is verified healthy. The system runs on the same EC2 instance as multi-container-service, using separate Docker Compose directories (`/opt/blue` and `/opt/green`) with Nginx switching between them.

## Core Value

Zero-downtime deployments — users experience no interruption when a new version is released. The old version stays running until the new version is confirmed healthy.

## Project Type

Brownfield extension of multi-container-service. The base application (Node.js/Express Todo API + MongoDB) is already built and deployed.

## Constraints

- **Infrastructure:** AWS EC2 in ap-southeast-2 (same instance as multi-container-service at 13.236.205.122)
- **SSH access:** Use existing `ec2-static-site-key` key pair (private key at `/c/Users/fiefi/.ssh/ec2-static-site-key.pem`)
- **Same EC2 instance:** Blue and green both run on the existing instance (same Docker host, different directories)
- **No new domain:** Access via EC2 public IP only
- **No separate infrastructure:** Reuse existing EC2 instance, security group, and VPC
- **Own CI/CD:** Separate GitHub Actions workflow, not integrated with multi-container-service pipeline

## Tech Stack (Inherited from multi-container-service)

- **Application:** Node.js 20, Express, Mongoose ODM, MongoDB 7
- **Containerization:** Docker, Docker Compose
- **Reverse Proxy:** Nginx (switches between /opt/blue and /opt/green)
- **IaC:** Terraform (AWS EC2) + Ansible
- **CI/CD:** GitHub Actions (separate pipeline)
- **Monitoring:** Basic (health check endpoints, container logs, Nginx logs)

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Same EC2 instance | Simpler than provisioning separate instances; Docker Compose dirs provide isolation | — Pending |
| Separate CI/CD pipeline | Clean separation of concerns; blue-green is its own project | — Pending |
| Basic monitoring | Sufficient for v1; Prometheus/Grafana deferred | — Pending |
| IP address only | Faster to set up; domain/R53 can be added later | — Pending |
| Reuse existing SSH key | Avoid creating new key pairs; same access as multi-container-service | — Pending |
| Terraform with remote state | Same S3 backend as multi-container-service (mythicc-multi-container-tf-state) | — Pending |

## Architecture

```
EC2 Instance (13.236.205.122)
├── /opt/blue/           (Blue environment: docker-compose.yml + .env)
│   └── blue-api (Docker container)
├── /opt/green/           (Green environment: docker-compose.yml + .env)
│   └── green-api (Docker container)
├── Nginx (port 80)       (Switches between blue and green)
│   └── /etc/nginx/sites-available/blue-green
└── MongoDB (port 27017) (Shared, from multi-container-service)
```

Traffic flow:
1. User request → Nginx (port 80)
2. Nginx → active environment (blue OR green)
3. Active environment → Node.js API → MongoDB

Deployment flow:
1. Deploy new version to inactive environment (blue if green active, vice versa)
2. Health check the new environment
3. Switch Nginx config to point to new environment
4. Reload Nginx (zero downtime)
5. Old environment can be torn down or kept for instant rollback

## Evolution

This document evolves at phase transitions and milestone boundaries.

**After each phase transition** (via `/gsd:transition`):
1. Requirements invalidated? → Move to Out of Scope with reason
2. Requirements validated? → Move to Validated with phase reference
3. New requirements emerged? → Add to Active
4. Decisions to log? → Add to Key Decisions
5. "What This Is" still accurate? → Update if drifted

**After each milestone** (via `/gsd:complete-milestone`):
1. Full review of all sections
2. Core Value check — still the right priority?
3. Audit Out of Scope — reasons still valid?
4. Update Context with current state
