#!/usr/bin/env bash
set -euo pipefail

SSH_KEY="${SSH_KEY:-$HOME/.ssh/ec2-static-site-key.pem}"
HOST="${HOST:-13.236.205.122}"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

active_slot=$(ssh $SSH_OPTS -i "$SSH_KEY" ubuntu@$HOST \
    "cat /var/run/blue-green-state 2>/dev/null || echo blue")

echo "$active_slot"
