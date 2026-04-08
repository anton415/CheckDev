#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PID_DIR="$ROOT_DIR/.local-run/pids"

log() {
    printf '[stop-local] %s\n' "$1"
}

kill_pid_file() {
    local pid_file="$1"
    local pid

    if [[ ! -f "$pid_file" ]]; then
        return 0
    fi

    pid="$(cat "$pid_file")"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        sleep 1
        if kill -0 "$pid" 2>/dev/null; then
            kill -9 "$pid" 2>/dev/null || true
        fi
        log "Stopped PID ${pid} from $(basename "$pid_file")"
    fi
    rm -f "$pid_file"
}

kill_port_listener() {
    local name="$1"
    local port="$2"
    local pid

    pid="$(lsof -tiTCP:"$port" -sTCP:LISTEN | head -n 1 || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        sleep 1
        if kill -0 "$pid" 2>/dev/null; then
            kill -9 "$pid" 2>/dev/null || true
        fi
        log "Stopped PID ${pid} on port ${port} for ${name}"
    fi
}

SERVICES=(
    "notification|9920"
    "site|8080"
    "generator|9903"
    "mock|9912"
    "desc|9902"
    "auth|9900"
    "eureka|9009"
)

for service in "${SERVICES[@]}"; do
    OLD_IFS="$IFS"
    IFS='|'
    read -r name port <<<"$service"
    IFS="$OLD_IFS"
    kill_pid_file "$PID_DIR/${name}.app.pid"
    kill_pid_file "$PID_DIR/${name}.launcher.pid"
    kill_port_listener "$name" "$port"
done

find "$PID_DIR" -type f -name '*.pid' -delete 2>/dev/null || true
log "Local stack stopped."
