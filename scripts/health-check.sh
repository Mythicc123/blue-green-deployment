#!/usr/bin/env bash
set -euo pipefail

slot="${1:-}"
timeout="${2:-60}"
interval="${3:-3}"

if [[ -z "$slot" ]] || [[ "$slot" != "blue" && "$slot" != "green" ]]; then
    echo "Usage: $0 <blue|green> [timeout] [interval]"
    echo "  timeout  - seconds to wait for health (default: 60)"
    echo "  interval - seconds between polls (default: 3)"
    exit 1
fi

case "$slot" in
    blue)  port=3001;  url="http://localhost:3001/health" ;;
    green) port=3002;  url="http://localhost:3002/health" ;;
esac

SSH_KEY="${SSH_KEY:-$HOME/.ssh/ec2-static-site-key.pem}"
HOST="${HOST:-13.236.205.122}"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

waited=0

echo "Polling $url (timeout: ${timeout}s, interval: ${interval}s)..."

while true; do
    response=$(ssh $SSH_OPTS -i "$SSH_KEY" ubuntu@$HOST \
        "curl -sf '$url'" 2>/dev/null) && \
        echo "$response" | grep -q '"status":"ok"'

    if [[ $? -eq 0 ]]; then
        echo "PASS: Health check passed after ${waited}s"
        echo "$response"
        exit 0
    fi

    if [[ $waited -ge $timeout ]]; then
        echo "FAIL: Health check timed out after ${timeout}s"
        exit 1
    fi

    echo "  [${waited}s] Not ready yet..."
    sleep "$interval"
    waited=$((waited + interval))
done
