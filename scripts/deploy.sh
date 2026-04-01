#!/usr/bin/env bash
set -euo pipefail

# Defaults - can be overridden via environment variables
SSH_KEY="${SSH_KEY:-$HOME/.ssh/ec2-static-site-key.pem}"
HOST="${HOST:-13.236.205.122}"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

echo "=== Blue-Green Deployment ==="
echo "Host: $HOST"

# Determine active slot
active_slot=$(ssh $SSH_OPTS -i "$SSH_KEY" ubuntu@$HOST \
    "cat /var/run/blue-green-state 2>/dev/null || echo blue")

# Compute inactive slot
if [[ "$active_slot" == "blue" ]]; then
    inactive_slot="green"
else
    inactive_slot="blue"
fi

case "$inactive_slot" in
    blue)  port=3001 ;;
    green) port=3002 ;;
esac

echo "Active slot: $active_slot"
echo "Deploying to inactive slot: $inactive_slot (port $port)"

# Deploy via SSH heredoc: pass slot/port as arguments to avoid local expansion
ssh $SSH_OPTS -i "$SSH_KEY" ubuntu@$HOST bash -s -- "$inactive_slot" "$port" << 'REMOTE'
set -euo pipefail

inactive_slot="$1"
port="$2"

cd /opt/"$inactive_slot"

DOCKER_IMAGE=$(grep DOCKER_IMAGE .env | cut -d= -f2)
echo "Pulling image: $DOCKER_IMAGE"

if ! docker compose pull; then
    echo "ERROR: docker compose pull failed"
    exit 1
fi

if ! docker compose up -d; then
    echo "ERROR: docker compose up failed"
    exit 1
fi

echo "Deployed to $inactive_slot (port $port)"
REMOTE

echo "SUCCESS: Deployment to $inactive_slot complete"
