#!/usr/bin/env bash
set -euo pipefail

# Defaults
SSH_KEY="${SSH_KEY:-$HOME/.ssh/ec2-static-site-key.pem}"
HOST="${HOST:-13.236.205.122}"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

echo "=== Blue-Green Nginx Setup ==="
echo "Host: $HOST"
echo ""

# Deploy Nginx configs to EC2
echo "[1/4] Copying Nginx configs to /etc/nginx/sites-available/..."
ssh $SSH_OPTS -i "$SSH_KEY" ubuntu@$HOST "sudo mkdir -p /etc/nginx/sites-available"
ssh $SSH_OPTS -i "$SSH_KEY" ubuntu@$HOST "sudo chown ubuntu:ubuntu /etc/nginx/sites-available"
ssh $SSH_OPTS -i "$SSH_KEY" ubuntu@$HOST "cat > /etc/nginx/sites-available/blue-green-blue.conf" < nginx/blue-green-blue.conf
ssh $SSH_OPTS -i "$SSH_KEY" ubuntu@$HOST "cat > /etc/nginx/sites-available/blue-green-green.conf" < nginx/blue-green-green.conf
echo "  Configs copied."

# Enable blue-green site
echo "[2/4] Enabling blue-green site via symlink..."
ssh $SSH_OPTS -i "$SSH_KEY" ubuntu@$HOST "sudo ln -sf /etc/nginx/sites-available/blue-green-blue.conf /etc/nginx/sites-enabled/blue-green"
echo "  Symlink created: sites-enabled/blue-green -> blue-green-blue.conf"

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
echo ""
echo "SUCCESS: Blue-green Nginx site is active and routing to blue (port 3001)"
