#!/usr/bin/env bash

set -euo pipefail

APP_DB_USER="${APP_DB_USER:-postgres}"
APP_DB_PASSWORD="${APP_DB_PASSWORD:-password}"
BOOTSTRAP_DB="${BOOTSTRAP_DB:-postgres}"
BOOTSTRAP_PGUSER="${BOOTSTRAP_PGUSER:-${PGUSER:-$(id -un)}}"
DATABASES=(
    "cd_auth"
    "cd_desc"
    "cd_generator"
    "cd_notification"
    "mock"
)

log() {
    printf '[create-local-db] %s\n' "$1"
}

fail() {
    printf '[create-local-db] %s\n' "$1" >&2
    exit 1
}

ensure_command() {
    local command_name="$1"

    if ! command -v "$command_name" >/dev/null 2>&1; then
        fail "Command '${command_name}' not found. Install PostgreSQL client tools first."
    fi
}

ensure_command psql
ensure_command createdb

if ! psql --username="$BOOTSTRAP_PGUSER" --dbname="$BOOTSTRAP_DB" -Atc "SELECT 1" >/dev/null 2>&1; then
    fail "Cannot connect to PostgreSQL database '${BOOTSTRAP_DB}' as '${BOOTSTRAP_PGUSER}'. Export BOOTSTRAP_PGUSER if bootstrap must run under another local PostgreSQL role."
fi

log "Ensuring PostgreSQL role '${APP_DB_USER}' exists."
psql \
    --username="$BOOTSTRAP_PGUSER" \
    --dbname="$BOOTSTRAP_DB" \
    -v ON_ERROR_STOP=1 \
    -v app_db_user="$APP_DB_USER" \
    -v app_db_password="$APP_DB_PASSWORD" <<'SQL'
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'app_db_user', :'app_db_password')
WHERE NOT EXISTS (
    SELECT 1
    FROM pg_roles
    WHERE rolname = :'app_db_user'
)
\gexec

SELECT format('ALTER ROLE %I WITH LOGIN PASSWORD %L', :'app_db_user', :'app_db_password')
\gexec
SQL

for db_name in "${DATABASES[@]}"; do
    if psql --username="$BOOTSTRAP_PGUSER" --dbname="$BOOTSTRAP_DB" -Atc "SELECT 1 FROM pg_database WHERE datname = '${db_name}'" | grep -qx '1'; then
        log "Database '${db_name}' already exists."
    else
        log "Creating database '${db_name}'."
        createdb --username="$BOOTSTRAP_PGUSER" --owner="$APP_DB_USER" --encoding=UTF8 "$db_name"
    fi
    psql --username="$BOOTSTRAP_PGUSER" --dbname="$BOOTSTRAP_DB" -v ON_ERROR_STOP=1 -c "ALTER DATABASE \"${db_name}\" OWNER TO \"${APP_DB_USER}\";" >/dev/null
done

log "Verifying TCP connection for application credentials."
PGPASSWORD="$APP_DB_PASSWORD" \
psql \
    --host=127.0.0.1 \
    --port=5432 \
    --username="$APP_DB_USER" \
    --dbname="$BOOTSTRAP_DB" \
    -Atc "SELECT current_user" >/dev/null

log "Local PostgreSQL bootstrap is complete."
