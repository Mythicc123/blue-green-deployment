#!/usr/bin/env bash
set -euo pipefail

# Defaults - can be overridden via environment variables
SSH_KEY="${SSH_KEY:-$HOME/.ssh/ec2-static-site-key.pem}"
HOST="${HOST:-13.236.205.122}"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

# Parse arguments
target="all"
lines=100
follow=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        blue|green|nginx|all) target="$1"; shift ;;
        -f|--follow) follow=true; shift ;;
        -n|--lines)
            lines="${2:-100}"; shift 2 ;;
        -h|--help)
            echo "Usage: $0 [blue|green|nginx|all] [-f] [-n lines]"
            echo ""
            echo "Targets:"
            echo "  blue    - Show blue container logs"
            echo "  green   - Show green container logs"
            echo "  nginx   - Show Nginx access and error logs"
            echo "  all     - Show all logs (default)"
            echo ""
            echo "Options:"
            echo "  -f, --follow   Follow mode (tail -f equivalent)"
            echo "  -n, --lines N  Number of lines to show (default: 100)"
            echo ""
            echo "Examples:"
            echo "  $0 blue              # last 100 lines of blue logs"
            echo "  $0 green -n 500      # last 500 lines of green logs"
            echo "  $0 nginx             # last 100 lines of nginx logs"
            echo "  $0 all -n 200        # last 200 lines of all logs"
            echo "  $0 nginx -f           # follow nginx logs in real time"
            echo "  $0 blue -f           # follow blue logs in real time"
            exit 0 ;;
        *) echo "Usage: $0 [blue|green|nginx|all] [-f] [-n lines]"; exit 1 ;;
    esac
done

# Helper to run SSH command
run_ssh() {
    ssh $SSH_OPTS -i "$SSH_KEY" ubuntu@$HOST "$1"
}

# Nginx line count default (smaller than container)
nginx_lines=50

show_blue() {
    if [[ "$follow" == "true" ]]; then
        echo "=== Following Blue Container Logs ==="
        run_ssh "cd /opt/blue && docker compose logs -f"
    else
        echo "=== Blue Container Logs (last $lines lines) ==="
        run_ssh "docker compose -f /opt/blue/docker-compose.yml logs --tail=$lines"
    fi
}

show_green() {
    if [[ "$follow" == "true" ]]; then
        echo "=== Following Green Container Logs ==="
        run_ssh "cd /opt/green && docker compose logs -f"
    else
        echo "=== Green Container Logs (last $lines lines) ==="
        run_ssh "docker compose -f /opt/green/docker-compose.yml logs --tail=$lines"
    fi
}

show_nginx() {
    if [[ "$follow" == "true" ]]; then
        echo "=== Following Nginx Logs ==="
        run_ssh "sudo tail -f /var/log/nginx/access.log /var/log/nginx/error.log"
    else
        echo "=== Nginx Access Logs (last $nginx_lines lines) ==="
        run_ssh "sudo tail -n $nginx_lines /var/log/nginx/access.log"
        echo ""
        echo "=== Nginx Error Logs (last $nginx_lines lines) ==="
        run_ssh "sudo tail -n $nginx_lines /var/log/nginx/error.log"
    fi
}

case "$target" in
    blue)   show_blue ;;
    green)  show_green ;;
    nginx)  show_nginx ;;
    all)
        show_blue
        echo ""
        show_green
        echo ""
        show_nginx
        ;;
esac
