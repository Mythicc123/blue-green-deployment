#!/usr/bin/env bash
set -euo pipefail

TARGET="${1:-}"

if [[ -z "$TARGET" ]] || [[ "$TARGET" != "blue" && "$TARGET" != "green" ]]; then
    echo "Usage: $0 <blue|green>"
    echo "  Switches Nginx to the target slot and updates the state file."
    exit 1
fi

SSH_KEY="${SSH_KEY:-$HOME/.ssh/ec2-static-site-key.pem}"
HOST="${HOST:-13.236.205.122}"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

echo "=== Blue-Green Nginx Switch ==="
echo "Host: $HOST"
echo "Target: $TARGET"

# Execute all steps via single SSH heredoc
ssh $SSH_OPTS -i "$SSH_KEY" ubuntu@$HOST bash -s -- "$TARGET" << 'REMOTE'
set -euo pipefail

target="$1"

echo "[1/5] Switching symlink to blue-green-${target}.conf..."
sudo ln -sf /etc/nginx/sites-available/blue-green-${target}.conf /etc/nginx/sites-enabled/blue-green

echo "[2/5] Validating Nginx configuration..."
sudo nginx -t

echo "[3/5] Reloading Nginx..."
sudo nginx -s reload

echo "[4/5] Updating state file..."
echo "$target" | sudo tee /var/run/blue-green-state > /dev/null

echo "[5/5] Verifying..."
symlink=$(readlink /etc/nginx/sites-enabled/blue-green)
state=$(cat /var/run/blue-green-state)
echo "  Symlink: $symlink"
echo "  State:   $state"

if [[ "$symlink" == *"$target"* ]] && [[ "$state" == "$target" ]]; then
    echo "SUCCESS: Switched to $target"
else
    echo "ERROR: Verification failed - symlink or state mismatch"
    exit 1
fi
REMOTE

echo "SUCCESS: Switched to $TARGET"
