#!/usr/bin/env bash
set -e

# ─────────────────────────────────────────────────────────────────
# Media Stack Configurator — configure.sh
#
# Wires together:
#   - qBittorrent → Radarr  (download client)
#   - qBittorrent → Sonarr  (download client)
#   - Radarr      → Prowlarr (application sync)
#   - Sonarr      → Prowlarr (application sync)
#   - /media/movies → Radarr root folder
#   - /media/tv     → Sonarr root folder
# ─────────────────────────────────────────────────────────────────

HOST="127.0.0.1"

RADARR_URL="http://${HOST}:${RADARR_PORT}"
SONARR_URL="http://${HOST}:${SONARR_PORT}"
PROWLARR_URL="http://${HOST}:${PROWLARR_PORT}"
QBIT_URL="http://${HOST}:${QBIT_PORT}"

# ── Helpers ───────────────────────────────────────────────────────

log_info()    { echo "[INFO]   "    "$1"; }
log_success() { echo "[OK]     "   "$1"; }
log_error()   { echo "[ERROR]  "   "$1"; exit 1; }
log_warn()    { echo "[WARN]   " "$1"; }

api_get() {
    local url="$1"
    local api_key="$2"
    curl -sf \
        -H "X-Api-Key: ${api_key}" \
        -H "Content-Type: application/json" \
        "${url}"
}

api_post() {
    local url="$1"
    local api_key="$2"
    local body="$3"
    curl -sf \
        -X POST \
        -H "X-Api-Key: ${api_key}" \
        -H "Content-Type: application/json" \
        -d "${body}" \
        "${url}"
}

already_exists() {
    # Returns 0 (true) if $2 is found in JSON array field 'name' from $1
    local json="$1"
    local name="$2"
    echo "$json" | jq -e --arg n "$name" '.[] | select(.name == $n)' > /dev/null 2>&1
}

# ── Step 1: Extract API Keys ─────────────────────────────────────

log_info "[1/9] Extracting API keys from service configs..."

find_config() {
    local service="$1"
    local config_file
    # Alexbelgium addons store configs under /addon_configs/<slug>_<service>/
    config_file=$(find /addon_configs -name "config.xml" 2>/dev/null \
        | grep -i "${service}" | head -n 1)
    echo "$config_file"
}

extract_api_key() {
    local config_path="$1"
    if [ -z "$config_path" ] || [ ! -f "$config_path" ]; then
        return 1
    fi
    xmlstarlet sel -t -v "//ApiKey" "$config_path" 2>/dev/null
}

RADARR_CONFIG=$(find_config "radarr")
SONARR_CONFIG=$(find_config "sonarr")
PROWLARR_CONFIG=$(find_config "prowlarr")

RADARR_API_KEY=$(extract_api_key "$RADARR_CONFIG") \
    || log_error "Could not find Radarr config.xml. Is the Radarr addon installed and started?"

SONARR_API_KEY=$(extract_api_key "$SONARR_CONFIG") \
    || log_error "Could not find Sonarr config.xml. Is the Sonarr addon installed and started?"

PROWLARR_API_KEY=$(extract_api_key "$PROWLARR_CONFIG") \
    || log_error "Could not find Prowlarr config.xml. Is the Prowlarr addon installed and started?"

log_success "  Radarr API key:   ${RADARR_API_KEY:0:8}..."
log_success "  Sonarr API key:   ${SONARR_API_KEY:0:8}..."
log_success "  Prowlarr API key: ${PROWLARR_API_KEY:0:8}..."

# ── Step 2: Set Radarr Root Folder ───────────────────────────────

log_info "[2/9] Configuring Radarr root folder (${MOVIES_PATH})..."

existing_radarr_folders=$(api_get "${RADARR_URL}/api/v3/rootfolder" "$RADARR_API_KEY")

if echo "$existing_radarr_folders" | jq -e --arg p "$MOVIES_PATH" '.[] | select(.path == $p)' > /dev/null 2>&1; then
    log_warn "  Radarr root folder already set — skipping."
else
    api_post "${RADARR_URL}/api/v3/rootfolder" "$RADARR_API_KEY" \
        "{\"path\": \"${MOVIES_PATH}\"}" > /dev/null
    log_success "  Radarr root folder set to ${MOVIES_PATH}"
fi

# ── Step 3: Set Sonarr Root Folder ───────────────────────────────

log_info "[3/9] Configuring Sonarr root folder (${TV_PATH})..."

existing_sonarr_folders=$(api_get "${SONARR_URL}/api/v3/rootfolder" "$SONARR_API_KEY")

if echo "$existing_sonarr_folders" | jq -e --arg p "$TV_PATH" '.[] | select(.path == $p)' > /dev/null 2>&1; then
    log_warn "  Sonarr root folder already set — skipping."
else
    api_post "${SONARR_URL}/api/v3/rootfolder" "$SONARR_API_KEY" \
        "{\"path\": \"${TV_PATH}\"}" > /dev/null
    log_success "  Sonarr root folder set to ${TV_PATH}"
fi

# ── Step 4: Register qBittorrent in Radarr ───────────────────────

log_info "[4/9] Registering qBittorrent as download client in Radarr..."

existing_radarr_clients=$(api_get "${RADARR_URL}/api/v3/downloadclient" "$RADARR_API_KEY")

if already_exists "$existing_radarr_clients" "qBittorrent"; then
    log_warn "  qBittorrent already registered in Radarr — skipping."
else
    QBIT_RADARR_PAYLOAD=$(cat <<EOF
{
  "name": "qBittorrent",
  "enable": true,
  "protocol": "torrent",
  "priority": 1,
  "implementation": "QBittorrent",
  "configContract": "QBittorrentSettings",
  "fields": [
    {"name": "host",     "value": "${HOST}"},
    {"name": "port",     "value": ${QBIT_PORT}},
    {"name": "username", "value": "${QBIT_USER}"},
    {"name": "password", "value": "${QBIT_PASS}"},
    {"name": "tvCategory",    "value": "radarr"},
    {"name": "recentTvPriority",  "value": 0},
    {"name": "olderTvPriority",   "value": 0},
    {"name": "initialState",      "value": 0}
  ]
}
EOF
)
    api_post "${RADARR_URL}/api/v3/downloadclient" "$RADARR_API_KEY" "$QBIT_RADARR_PAYLOAD" > /dev/null
    log_success "  qBittorrent registered in Radarr."
fi

# ── Step 5: Register qBittorrent in Sonarr ───────────────────────

log_info "[5/9] Registering qBittorrent as download client in Sonarr..."

existing_sonarr_clients=$(api_get "${SONARR_URL}/api/v3/downloadclient" "$SONARR_API_KEY")

if already_exists "$existing_sonarr_clients" "qBittorrent"; then
    log_warn "  qBittorrent already registered in Sonarr — skipping."
else
    QBIT_SONARR_PAYLOAD=$(cat <<EOF
{
  "name": "qBittorrent",
  "enable": true,
  "protocol": "torrent",
  "priority": 1,
  "implementation": "QBittorrent",
  "configContract": "QBittorrentSettings",
  "fields": [
    {"name": "host",     "value": "${HOST}"},
    {"name": "port",     "value": ${QBIT_PORT}},
    {"name": "username", "value": "${QBIT_USER}"},
    {"name": "password", "value": "${QBIT_PASS}"},
    {"name": "tvCategory",    "value": "sonarr"},
    {"name": "recentTvPriority",  "value": 0},
    {"name": "olderTvPriority",   "value": 0},
    {"name": "initialState",      "value": 0}
  ]
}
EOF
)
    api_post "${SONARR_URL}/api/v3/downloadclient" "$SONARR_API_KEY" "$QBIT_SONARR_PAYLOAD" > /dev/null
    log_success "  qBittorrent registered in Sonarr."
fi

# ── Step 6: Register Radarr in Prowlarr ──────────────────────────

log_info "[6/9] Registering Radarr as an application in Prowlarr..."

existing_prowlarr_apps=$(api_get "${PROWLARR_URL}/api/v1/applications" "$PROWLARR_API_KEY")

if already_exists "$existing_prowlarr_apps" "Radarr"; then
    log_warn "  Radarr already registered in Prowlarr — skipping."
else
    RADARR_APP_PAYLOAD=$(cat <<EOF
{
  "name": "Radarr",
  "syncLevel": "addOnly",
  "implementation": "Radarr",
  "configContract": "RadarrSettings",
  "fields": [
    {"name": "prowlarrUrl", "value": "${PROWLARR_URL}"},
    {"name": "baseUrl",     "value": "${RADARR_URL}"},
    {"name": "apiKey",      "value": "${RADARR_API_KEY}"},
    {"name": "syncCategories", "value": [2000, 2010, 2020, 2030, 2040, 2045, 2050, 2060]}
  ]
}
EOF
)
    api_post "${PROWLARR_URL}/api/v1/applications" "$PROWLARR_API_KEY" "$RADARR_APP_PAYLOAD" > /dev/null
    log_success "  Radarr registered in Prowlarr."
fi

# ── Step 7: Register Sonarr in Prowlarr ──────────────────────────

log_info "[7/9] Registering Sonarr as an application in Prowlarr..."

if already_exists "$existing_prowlarr_apps" "Sonarr"; then
    log_warn "  Sonarr already registered in Prowlarr — skipping."
else
    SONARR_APP_PAYLOAD=$(cat <<EOF
{
  "name": "Sonarr",
  "syncLevel": "addOnly",
  "implementation": "Sonarr",
  "configContract": "SonarrSettings",
  "fields": [
    {"name": "prowlarrUrl", "value": "${PROWLARR_URL}"},
    {"name": "baseUrl",     "value": "${SONARR_URL}"},
    {"name": "apiKey",      "value": "${SONARR_API_KEY}"},
    {"name": "syncCategories",       "value": [5000, 5010, 5020, 5030, 5040, 5045, 5050]},
    {"name": "animeSyncCategories",  "value": [5070]}
  ]
}
EOF
)
    api_post "${PROWLARR_URL}/api/v1/applications" "$PROWLARR_API_KEY" "$SONARR_APP_PAYLOAD" > /dev/null
    log_success "  Sonarr registered in Prowlarr."
fi

# ── Step 8: Verify Radarr can see qBittorrent ────────────────────

log_info "[8/9] Testing Radarr → qBittorrent connection..."

TEST_RESULT=$(api_get "${RADARR_URL}/api/v3/downloadclient/test" "$RADARR_API_KEY" 2>/dev/null || echo "[]")
if echo "$TEST_RESULT" | jq -e '.[] | select(.isValid == false)' > /dev/null 2>&1; then
    log_warn "  Radarr download client test returned warnings — check Radarr UI."
else
    log_success "  Radarr → qBittorrent connection looks good."
fi

# ── Step 9: Verify Sonarr can see qBittorrent ────────────────────

log_info "[9/9] Testing Sonarr → qBittorrent connection..."

TEST_RESULT=$(api_get "${SONARR_URL}/api/v3/downloadclient/test" "$SONARR_API_KEY" 2>/dev/null || echo "[]")
if echo "$TEST_RESULT" | jq -e '.[] | select(.isValid == false)' > /dev/null 2>&1; then
    log_warn "  Sonarr download client test returned warnings — check Sonarr UI."
else
    log_success "  Sonarr → qBittorrent connection looks good."
fi

# ── Done ──────────────────────────────────────────────────────────

log_success ""
log_success "Configuration complete! Summary:"
log_success "  ✓ Radarr root folder  → ${MOVIES_PATH}"
log_success "  ✓ Sonarr root folder  → ${TV_PATH}"
log_success "  ✓ qBittorrent wired   → Radarr + Sonarr"
log_success "  ✓ Radarr synced       → Prowlarr"
log_success "  ✓ Sonarr synced       → Prowlarr"
log_success ""
log_success "Next step: Open Prowlarr and add your indexers."
log_success "They will automatically sync to Radarr and Sonarr."
