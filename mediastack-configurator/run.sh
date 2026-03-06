#!/usr/bin/env bash
set -e

# ─────────────────────────────────────────────
# Media Stack Configurator — run.sh
# Health-checks all services then wires them up
# ─────────────────────────────────────────────

# Load options from HA addon config
RADARR_PORT=$(bashio::config 'radarr_port')
SONARR_PORT=$(bashio::config 'sonarr_port')
PROWLARR_PORT=$(bashio::config 'prowlarr_port')
QBIT_PORT=$(bashio::config 'qbittorrent_port')
JELLYFIN_PORT=$(bashio::config 'jellyfin_port')
TIMEOUT=$(bashio::config 'service_timeout')

export RADARR_PORT SONARR_PORT PROWLARR_PORT QBIT_PORT JELLYFIN_PORT
export QBIT_USER=$(bashio::config 'qbittorrent_username')
export QBIT_PASS=$(bashio::config 'qbittorrent_password')
export MOVIES_PATH=$(bashio::config 'movies_path')
export TV_PATH=$(bashio::config 'tv_path')

HOST="127.0.0.1"

# ── Helpers ──────────────────────────────────

log_info()    { bashio::log.info    "$1"; }
log_success() { bashio::log.green   "$1"; }
log_error()   { bashio::log.error   "$1"; }
log_warn()    { bashio::log.warning "$1"; }

wait_for_service() {
    local name="$1"
    local port="$2"
    local elapsed=0
    local interval=5

    log_info "Waiting for ${name} on port ${port}..."

    until curl -sf --max-time 3 "http://${HOST}:${port}" > /dev/null 2>&1; do
        if [ "$elapsed" -ge "$TIMEOUT" ]; then
            log_error "${name} did not become reachable within ${TIMEOUT}s. Aborting."
            exit 1
        fi
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done

    log_success "${name} is up (${elapsed}s)"
}

# ── Health Checks ────────────────────────────

log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "  Media Stack Configurator starting"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "Checking all services are reachable..."

wait_for_service "Radarr"       "$RADARR_PORT"
wait_for_service "Sonarr"       "$SONARR_PORT"
wait_for_service "Prowlarr"     "$PROWLARR_PORT"
wait_for_service "qBittorrent"  "$QBIT_PORT"
wait_for_service "Jellyfin"     "$JELLYFIN_PORT"

log_info "All services reachable. Starting configuration..."
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── Run Configurator ─────────────────────────

bash /configure.sh

log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_success "Media Stack Configurator completed successfully."
log_info "You can now open Prowlarr and add your indexers."
log_info "They will sync automatically to Radarr and Sonarr."
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

exit 0
