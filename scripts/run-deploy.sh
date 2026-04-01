#!/usr/bin/env bash
set -euo pipefail

IMAGE_TAG="${IMAGE_TAG:-latest}"

SSH_KEY="${SSH_KEY:-$HOME/.ssh/ec2-static-site-key.pem}"
HOST="${HOST:-13.236.205.122}"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

echo "=== Blue-Green Deployment Pipeline ==="
echo "Image tag: $IMAGE_TAG"
echo "Host: $HOST"
echo ""

# Determine active and inactive slots
active_slot=$(./get-active-slot.sh)

if [[ "$active_slot" == "blue" ]]; then
    inactive_slot="green"
else
    inactive_slot="blue"
fi

echo "Active slot:   $active_slot"
echo "Inactive slot: $inactive_slot"
echo ""

# Step 1: Deploy
echo "[Step 1/4] Deploying to inactive slot ($inactive_slot)..."
if ! ./deploy.sh; then
    echo "DEPLOY FAILED"
    exit 1
fi
echo ""

# Step 2: Health check
echo "[Step 2/4] Waiting for health ($inactive_slot, 60s timeout)..."
if ! ./health-check.sh "$inactive_slot"; then
    echo "HEALTH CHECK FAILED"
    exit 1
fi
echo ""

# Step 3: Switch Nginx
echo "[Step 3/4] Switching Nginx to $inactive_slot..."
if ! ./switch-nginx.sh "$inactive_slot"; then
    echo "SWITCH FAILED"
    exit 1
fi
echo ""

# Step 4: Verify public health
echo "[Step 4/4] Verifying public health..."
sleep 2
if ! curl -sf "http://$HOST/health" | grep -q '"status":"ok"'; then
    echo "PUBLIC HEALTH FAILED"
    exit 1
fi

echo ""
echo "=== Deployment complete ==="
echo "Active slot: $inactive_slot"
echo "Previous slot: $active_slot (still running, use ./switch-nginx.sh $active_slot to switch back)"
exit 0
