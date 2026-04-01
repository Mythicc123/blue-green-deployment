#!/usr/bin/env bash
set -euo pipefail

# Defaults - can be overridden via environment variables
SSH_KEY="${SSH_KEY:-$HOME/.ssh/ec2-static-site-key.pem}"
HOST="${HOST:-13.236.205.122}"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

echo "=== Rolling back: detecting active slot ==="
active_slot=$(ssh $SSH_OPTS -i "$SSH_KEY" ubuntu@$HOST "cat /var/run/blue-green-state 2>/dev/null || echo blue")
echo "  Active slot: $active_slot"

# Compute rollback target
if [[ "$active_slot" == "blue" ]]; then
    rollback_slot="green"
    old_port=3001
    new_port=3002
else
    rollback_slot="blue"
    old_port=3002
    new_port=3001
fi

echo ""
echo "=== Rolling back: $active_slot -> $rollback_slot ==="
echo "  Active slot ($active_slot) is running on port $old_port"
echo "  Rolling back to $rollback_slot on port $new_port"

# Execute rollback on remote host
ssh $SSH_OPTS -i "$SSH_KEY" ubuntu@$HOST 'sudo tee /tmp/rollback-remote.sh' << 'REMOTE'
set -euo pipefail

active_slot=$(cat /var/run/blue-green-state 2>/dev/null || echo blue)

if [[ "$active_slot" == "blue" ]]; then
    rollback_slot="green"
    old_port=3001
else
    rollback_slot="blue"
    old_port=3002
fi

echo "Switching Nginx from $active_slot to $rollback_slot..."

# Switch symlink
sudo ln -sf /etc/nginx/sites-available/blue-green-${rollback_slot}.conf /etc/nginx/sites-enabled/blue-green

# Validate Nginx config
sudo nginx -t

# Reload Nginx
sudo nginx -s reload

# Update state file AFTER successful reload
echo "$rollback_slot" | sudo tee /var/run/blue-green-state > /dev/null

# Verify
echo ""
echo "Active slot: $(cat /var/run/blue-green-state)"
REMOTE

echo ""
echo "SUCCESS: Rolled back to $rollback_slot"
echo "Previous slot ($active_slot) is still running at port $old_port"
