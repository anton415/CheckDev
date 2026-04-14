#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_DIR="$ROOT_DIR/.local-run"
PID_DIR="$RUN_DIR/pids"
LOG_DIR="$RUN_DIR/logs"
NOTIFICATION_PROFILE="${NOTIFICATION_PROFILE:-develop}"
NOTIFICATION_TG_USERNAME="${NOTIFICATION_TG_USERNAME:-}"
NOTIFICATION_TG_TOKEN="${NOTIFICATION_TG_TOKEN:-}"

mkdir -p "$PID_DIR" "$LOG_DIR"

bash "$ROOT_DIR/create-local-db.sh"

java_home_is_21() {
    local java_home="$1"
    local version_line

    if [[ -z "$java_home" ]] || [[ ! -x "${java_home}/bin/java" ]]; then
        return 1
    fi
    version_line="$("${java_home}/bin/java" -version 2>&1 | head -n 1 || true)"
    [[ "$version_line" == *'"21.'* ]] || [[ "$version_line" == *' 21'* ]]
}

JAVA_HOME_21=""
if java_home_is_21 "${JAVA_HOME:-}"; then
    JAVA_HOME_21="$JAVA_HOME"
else
    JAVA_HOME_21="$(/usr/libexec/java_home -v 21 2>/dev/null || true)"
fi

if [[ -z "$JAVA_HOME_21" ]] || [[ ! -x "${JAVA_HOME_21}/bin/java" ]]; then
    echo "Java 21 not found. Install JDK 21 or export JAVA_HOME to a Java 21 home."
    exit 1
fi

export JAVA_HOME="$JAVA_HOME_21"
export PATH="${JAVA_HOME}/bin:${PATH}"

MAVEN_RUN_ARGS=(
    -DskipTests
    "-Dspring-boot.run.jvmArguments=-Dspring.devtools.restart.enabled=false -Dspring.devtools.livereload.enabled=false"
    spring-boot:run
)

SERVICES=(
    "eureka|services/eureka|9009|/|200|"
    "auth|services/auth|9900|/ping|200|AUTH"
    "desc|services/desc|9902|/category/ping|200|DESC"
    "mock|services/mock|9912|/swagger-ui/index.html|200,401|MOCK"
    "generator|services/generator|9903|/h2-console|200,302,401|GENERATOR"
    "site|services/site|8080|/|200|SITE"
    "notification|services/notification|9920|/swagger-ui/index.html|200|NOTIFICATION"
)

log() {
    printf '[start-local] %s\n' "$1"
}

fail() {
    printf '[start-local] %s\n' "$1" >&2
    exit 1
}

ensure_port_free() {
    local port="$1"
    local listener

    listener="$(lsof -tiTCP:"$port" -sTCP:LISTEN | head -n 1 || true)"
    if [[ -n "$listener" ]]; then
        fail "Port ${port} is already in use by PID ${listener}. Stop the existing process first."
    fi
}

code_allowed() {
    local code="$1"
    local csv="$2"
    local allowed

    OLD_IFS="$IFS"
    IFS=','
    for allowed in $csv; do
        if [[ "$allowed" == "$code" ]]; then
            IFS="$OLD_IFS"
            return 0
        fi
    done
    IFS="$OLD_IFS"
    return 1
}

wait_for_http() {
    local name="$1"
    local port="$2"
    local path="$3"
    local allowed_codes="$4"
    local launcher_pid="$5"
    local deadline code

    deadline=$((SECONDS + 90))
    while (( SECONDS < deadline )); do
        if ! kill -0 "$launcher_pid" 2>/dev/null; then
            log "${name} exited before becoming ready. Last log lines:"
            tail -n 40 "$LOG_DIR/${name}.out" || true
            return 1
        fi
        code="$(curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:${port}${path}" || true)"
        if code_allowed "$code" "$allowed_codes"; then
            return 0
        fi
        sleep 1
    done
    log "Timed out waiting for ${name} on port ${port}. Last log lines:"
    tail -n 40 "$LOG_DIR/${name}.out" || true
    return 1
}

wait_for_listen_pid() {
    local name="$1"
    local port="$2"
    local deadline pid

    deadline=$((SECONDS + 30))
    while (( SECONDS < deadline )); do
        pid="$(lsof -tiTCP:"$port" -sTCP:LISTEN | head -n 1 || true)"
        if [[ -n "$pid" ]]; then
            printf '%s' "$pid"
            return 0
        fi
        sleep 1
    done
    log "Timed out waiting for a listener on port ${port} for ${name}."
    return 1
}

wait_for_eureka_registration() {
    local name="$1"
    local app_name="$2"
    local launcher_pid="$3"
    local deadline

    if [[ -z "$app_name" ]]; then
        return 0
    fi

    deadline=$((SECONDS + 90))
    while (( SECONDS < deadline )); do
        if ! kill -0 "$launcher_pid" 2>/dev/null; then
            log "${name} exited before Eureka registration. Last log lines:"
            tail -n 40 "$LOG_DIR/${name}.out" || true
            return 1
        fi
        if curl -sS "http://127.0.0.1:9009/eureka/apps" | grep -q "<name>${app_name}</name>"; then
            return 0
        fi
        sleep 1
    done
    log "Timed out waiting for ${name} to register in Eureka as ${app_name}. Last log lines:"
    tail -n 40 "$LOG_DIR/${name}.out" || true
    return 1
}

start_service() {
    local name="$1"
    local module_dir="$2"
    local port="$3"
    local path="$4"
    local codes="$5"
    local eureka_name="$6"
    local launcher_pid app_pid
    local -a mvn_args=("${MAVEN_RUN_ARGS[@]}")
    local notification_run_arguments=""

    ensure_port_free "$port"
    if [[ "$name" == "notification" ]]; then
        notification_run_arguments="--spring.profiles.active=${NOTIFICATION_PROFILE}"
        if [[ -n "$NOTIFICATION_TG_USERNAME" ]]; then
            notification_run_arguments+=" --tg.username=${NOTIFICATION_TG_USERNAME}"
        fi
        if [[ -n "$NOTIFICATION_TG_TOKEN" ]]; then
            notification_run_arguments+=" --tg.token=${NOTIFICATION_TG_TOKEN}"
        fi
        mvn_args+=("-Dspring-boot.run.arguments=${notification_run_arguments}")
    fi
    log "Starting ${name}..."
    launcher_pid="$(
        cd "$ROOT_DIR/$module_dir"
        nohup mvn "${mvn_args[@]}" >"$LOG_DIR/${name}.out" 2>&1 < /dev/null &
        printf '%s' "$!"
    )"
    echo "$launcher_pid" >"$PID_DIR/${name}.launcher.pid"

    wait_for_http "$name" "$port" "$path" "$codes" "$launcher_pid"
    app_pid="$(wait_for_listen_pid "$name" "$port")"
    echo "$app_pid" >"$PID_DIR/${name}.app.pid"
    wait_for_eureka_registration "$name" "$eureka_name" "$launcher_pid"
    log "${name} is ready on http://127.0.0.1:${port}${path}"
}

for service in "${SERVICES[@]}"; do
    OLD_IFS="$IFS"
    IFS='|'
    read -r name module_dir port path codes eureka_name <<<"$service"
    IFS="$OLD_IFS"
    start_service "$name" "$module_dir" "$port" "$path" "$codes" "$eureka_name"
done

cat <<EOF
[start-local] Stack is ready.
[start-local] Java: ${JAVA_HOME}
[start-local] Notification profile: ${NOTIFICATION_PROFILE}
[start-local] Logs: ${LOG_DIR}
[start-local] Stop command: bash stop-local.sh
EOF
