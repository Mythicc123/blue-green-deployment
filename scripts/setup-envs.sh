#!/usr/bin/env bash
set -euo pipefail

# Defaults - can be overridden via environment variables
SSH_KEY="${SSH_KEY:-$HOME/.ssh/ec2-static-site-key.pem}"
HOST="${HOST:-13.236.205.122}"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

echo "=== Blue-Green Environment Setup ==="
echo "Host: $HOST"
echo ""

# Create directories
echo "[1/6] Creating directories on EC2..."
ssh $SSH_OPTS -i "$SSH_KEY" ubuntu@$HOST "sudo mkdir -p /opt/blue /opt/green && sudo chown ubuntu:ubuntu /opt/blue /opt/green"
echo "  Directories created."

# Copy blue compose files
echo "[2/6] Deploying blue environment to /opt/blue..."
ssh $SSH_OPTS -i "$SSH_KEY" ubuntu@$HOST "cat > /opt/blue/docker-compose.yml" < compose/blue/docker-compose.yml
ssh $SSH_OPTS -i "$SSH_KEY" ubuntu@$HOST "cat > /opt/blue/.env" < compose/blue/.env
echo "  Blue files deployed."

# Copy green compose files
echo "[3/6] Deploying green environment to /opt/green..."
ssh $SSH_OPTS -i "$SSH_KEY" ubuntu@$HOST "cat > /opt/green/docker-compose.yml" < compose/green/docker-compose.yml
ssh $SSH_OPTS -i "$SSH_KEY" ubuntu@$HOST "cat > /opt/green/.env" < compose/green/.env
echo "  Green files deployed."

# Pull and start blue
echo "[4/6] Starting blue environment on port 3001..."
ssh $SSH_OPTS -i "$SSH_KEY" ubuntu@$HOST "cd /opt/blue && DOCKER_IMAGE=\$(grep DOCKER_IMAGE /opt/blue/.env | cut -d= -f2) docker compose pull && docker compose up -d"
echo "  Blue started."

# Pull and start green
echo "[5/6] Starting green environment on port 3002..."
ssh $SSH_OPTS -i "$SSH_KEY" ubuntu@$HOST "cd /opt/green && DOCKER_IMAGE=\$(grep DOCKER_IMAGE /opt/green/.env | cut -d= -f2) docker compose pull && docker compose up -d"
echo "  Green started."

# Wait for containers to be ready
echo "[6/6] Waiting for containers to start (30s)..."
sleep 30

# Verify blue
echo ""
echo "=== Verification ==="
echo "Checking blue (port 3001)..."
BLUE_STATUS=$(ssh $SSH_OPTS -i "$SSH_KEY" ubuntu@$HOST "curl -sf http://localhost:3001/health || echo FAILED")
echo "  Blue /health: $BLUE_STATUS"

# Verify green
echo "Checking green (port 3002)..."
GREEN_STATUS=$(ssh $SSH_OPTS -i "$SSH_KEY" ubuntu@$HOST "curl -sf http://localhost:3002/health || echo FAILED")
echo "  Green /health: $GREEN_STATUS"

# Show running containers
echo ""
echo "Running containers:"
ssh $SSH_OPTS -i "$SSH_KEY" ubuntu@$HOST "docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' | grep -E 'blue-api|green-api|multi-container'"

echo ""
if [[ "$BLUE_STATUS" == *"ok"* ]] && [[ "$GREEN_STATUS" == *"ok"* ]]; then
    echo "SUCCESS: Both environments are healthy!"
    exit 0
else
    echo "WARNING: One or more environments may not be healthy. Check logs with:"
    echo "  ssh -i $SSH_KEY ubuntu@$HOST 'docker compose -f /opt/blue/docker-compose.yml logs'"
    echo "  ssh -i $SSH_KEY ubuntu@$HOST 'docker compose -f /opt/green/docker-compose.yml logs'"
    exit 1
fi
