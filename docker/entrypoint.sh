#!/usr/bin/env bash

set -euo pipefail

WAIT_TIMEOUT="${WAIT_TIMEOUT:-180}"
WAIT_INTERVAL="${WAIT_INTERVAL:-2}"

log() {
    printf '[entrypoint] %s\n' "$1"
}

wait_for_tcp_target() {
    local target="$1"
    local host="${target%%:*}"
    local port="${target##*:}"
    local deadline=$((SECONDS + WAIT_TIMEOUT))

    while (( SECONDS < deadline )); do
        if bash -c "exec 3<>/dev/tcp/${host}/${port}" >/dev/null 2>&1; then
            log "TCP target ${target} is reachable."
            return 0
        fi
        sleep "$WAIT_INTERVAL"
    done

    log "Timed out waiting for TCP target ${target}."
    return 1
}

wait_for_http_target() {
    local url="$1"
    local deadline=$((SECONDS + WAIT_TIMEOUT))

    while (( SECONDS < deadline )); do
        if curl -fsS "$url" >/dev/null 2>&1; then
            log "HTTP target ${url} is reachable."
            return 0
        fi
        sleep "$WAIT_INTERVAL"
    done

    log "Timed out waiting for HTTP target ${url}."
    return 1
}

wait_for_eureka_apps() {
    local url="$1"
    local apps_csv="$2"
    local deadline=$((SECONDS + WAIT_TIMEOUT))
    local response
    local app

    while (( SECONDS < deadline )); do
        if response="$(curl -fsS "$url" 2>/dev/null)"; then
            local missing=0
            IFS=',' read -ra apps <<<"$apps_csv"
            for app in "${apps[@]}"; do
                if [[ "$response" != *"<name>${app}</name>"* ]]; then
                    missing=1
                    break
                fi
            done
            if (( missing == 0 )); then
                log "Eureka contains required apps: ${apps_csv}."
                return 0
            fi
        fi
        sleep "$WAIT_INTERVAL"
    done

    log "Timed out waiting for Eureka apps: ${apps_csv}."
    return 1
}

if [[ -n "${WAIT_FOR_TCP:-}" ]]; then
    IFS=',' read -ra tcp_targets <<<"${WAIT_FOR_TCP}"
    for target in "${tcp_targets[@]}"; do
        wait_for_tcp_target "$target"
    done
fi

if [[ -n "${WAIT_FOR_HTTP:-}" ]]; then
    IFS=',' read -ra http_targets <<<"${WAIT_FOR_HTTP}"
    for url in "${http_targets[@]}"; do
        wait_for_http_target "$url"
    done
fi

if [[ -n "${WAIT_FOR_EUREKA_URL:-}" ]] && [[ -n "${WAIT_FOR_EUREKA_APPS:-}" ]]; then
    wait_for_eureka_apps "${WAIT_FOR_EUREKA_URL}" "${WAIT_FOR_EUREKA_APPS}"
fi

exec "$@"
