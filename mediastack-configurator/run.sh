#!/usr/bin/env bash
set -e

OPTIONS="/data/options.json"

RADARR_PORT=$(jq -r '.radarr_port'       "$OPTIONS")
SONARR_PORT=$(jq -r '.sonarr_port'       "$OPTIONS")
PROWLARR_PORT=$(jq -r '.prowlarr_port'   "$OPTIONS")
QBIT_PORT=$(jq -r '.qbittorrent_port'    "$OPTIONS")
JELLYFIN_PORT=$(jq -r '.jellyfin_port'   "$OPTIONS")
TIMEOUT=$(jq -r '.service_timeout'       "$OPTIONS")

export RADARR_PORT SONARR_PORT PROWLARR_PORT QBIT_PORT JELLYFIN_PORT TIMEOUT
export QBIT_USER=$(jq -r '.qbittorrent_username' "$OPTIONS")
export QBIT_PASS=$(jq -r '.qbittorrent_password' "$OPTIONS")
export MOVIES_PATH=$(jq -r '.movies_path'        "$OPTIONS")
export TV_PATH=$(jq -r '.tv_path'                "$OPTIONS")

# SUPERVISOR_TOKEN is injected automatically by HA when hassio_api: true
export SUPERVISOR_TOKEN="${SUPERVISOR_TOKEN:-}"

HOST="127.0.0.1"

log_info()    { echo "[INFO]    $1"; }
log_success() { echo "[OK]      $1"; }
log_error()   { echo "[ERROR]   $1"; exit 1; }

wait_for_service() {
    local name="$1" port="$2" elapsed=0 interval=5
    log_info "Waiting for ${name} on port ${port}..."
    until curl -sf --max-time 3 "http://${HOST}:${port}" > /dev/null 2>&1; do
        if [ "$elapsed" -ge "$TIMEOUT" ]; then
            log_error "${name} did not become reachable within ${TIMEOUT}s."
        fi
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done
    log_success "${name} is up (${elapsed}s elapsed)"
}

log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "  Media Stack Configurator starting"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

wait_for_service "Radarr"      "$RADARR_PORT"
wait_for_service "Sonarr"      "$SONARR_PORT"
wait_for_service "Prowlarr"    "$PROWLARR_PORT"
wait_for_service "qBittorrent" "$QBIT_PORT"
wait_for_service "Jellyfin"    "$JELLYFIN_PORT"

log_info "All services reachable. Starting configuration..."
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

bash /configure.sh

log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_success "Media Stack Configurator completed."
log_info "Open Prowlarr and add your indexers."
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
exit 0
