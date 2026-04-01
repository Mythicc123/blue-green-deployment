#!/usr/bin/env bash
set -euo pipefail

# Arguments
TARGET="${1:-}"

if [[ -z "$TARGET" ]]; then
    echo "Usage: $0 <blue|green>"
    echo "  Switches the active blue-green environment."
    exit 1
fi

if [[ "$TARGET" != "blue" ]] && [[ "$TARGET" != "green" ]]; then
    echo "Error: TARGET must be 'blue' or 'green', got '$TARGET'"
    exit 1
fi

# Defaults
SSH_KEY="${SSH_KEY:-$HOME/.ssh/ec2-static-site-key.pem}"
HOST="${HOST:-13.236.205.122}"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

echo "=== Switching to $TARGET ==="
echo "Host: $HOST"

# Validate config exists
echo "[1/4] Validating target config exists..."
ssh $SSH_OPTS -i "$SSH_KEY" ubuntu@$HOST "test -f /etc/nginx/sites-available/blue-green-${TARGET}.conf"
echo "  Config file exists."

# Switch symlink
echo "[2/4] Switching symlink to blue-green-${TARGET}.conf..."
ssh $SSH_OPTS -i "$SSH_KEY" ubuntu@$HOST "sudo ln -sf /etc/nginx/sites-available/blue-green-${TARGET}.conf /etc/nginx/sites-enabled/blue-green"
echo "  Symlink updated."

# Validate Nginx config
echo "[3/4] Validating Nginx configuration..."
ssh $SSH_OPTS -i "$SSH_KEY" ubuntu@$HOST "sudo nginx -t"
echo "  Config test passed."

# Reload Nginx
echo "[4/4] Reloading Nginx..."
ssh $SSH_OPTS -i "$SSH_KEY" ubuntu@$HOST "sudo nginx -s reload"
echo "  Nginx reloaded."

# Verify
echo ""
echo "=== Verification ==="
symlink=$(ssh $SSH_OPTS -i "$SSH_KEY" ubuntu@$HOST "readlink /etc/nginx/sites-enabled/blue-green")
echo "Active config: $symlink"

health=$(ssh $SSH_OPTS -i "$SSH_KEY" ubuntu@$HOST "curl -sf http://localhost/health")
echo "Health check: $health"
echo ""
echo "SUCCESS: Switched to $TARGET environment"
