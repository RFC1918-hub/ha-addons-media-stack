#!/usr/bin/env bash

HOST="127.0.0.1"

RADARR_URL="http://${HOST}:${RADARR_PORT}"
SONARR_URL="http://${HOST}:${SONARR_PORT}"
PROWLARR_URL="http://${HOST}:${PROWLARR_PORT}"
QBIT_URL="http://${HOST}:${QBIT_PORT}"

log_info()    { echo "[INFO]    $1"; }
log_success() { echo "[OK]      $1"; }
log_error()   { echo "[ERROR]   $1"; exit 1; }
log_warn()    { echo "[WARNING] $1"; }

api_get() {
    local url="$1" api_key="$2"
    curl -sf -H "X-Api-Key: ${api_key}" -H "Content-Type: application/json" "${url}"
}

api_post() {
    local url="$1" api_key="$2" body="$3"
    curl -sf -X POST \
        -H "X-Api-Key: ${api_key}" \
        -H "Content-Type: application/json" \
        -d "${body}" "${url}"
}

already_exists() {
    echo "$1" | jq -e --arg n "$2" '.[] | select(.name == $n)' > /dev/null 2>&1
}

# ── Step 1: Auto-extract API keys ────────────────────────────────

log_info "[1/9] Auto-extracting API keys via Supervisor API..."

# The Supervisor token is injected as an env var by HA
SUPERVISOR_TOKEN="${SUPERVISOR_TOKEN:-}"
if [ -z "$SUPERVISOR_TOKEN" ]; then
    log_error "SUPERVISOR_TOKEN not available. Make sure hassio_api: true is set in config.yaml"
fi

# List all installed addons to find the right slugs
ADDONS=$(curl -sf \
    -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
    "http://supervisor/addons" 2>/dev/null)

log_info "  Installed addons:"
echo "$ADDONS" | jq -r '.data.addons[] | "\(.slug) - \(.name)"' 2>/dev/null || log_warn "  Could not list addons"

# Find slugs dynamically by name match
RADARR_SLUG=$(echo "$ADDONS"   | jq -r '.data.addons[] | select(.name | test("(?i)radarr"))   | .slug' | head -1)
SONARR_SLUG=$(echo "$ADDONS"   | jq -r '.data.addons[] | select(.name | test("(?i)sonarr"))   | .slug' | head -1)
PROWLARR_SLUG=$(echo "$ADDONS" | jq -r '.data.addons[] | select(.name | test("(?i)prowlarr")) | .slug' | head -1)

log_info "  Radarr slug:   ${RADARR_SLUG:-NOT FOUND}"
log_info "  Sonarr slug:   ${SONARR_SLUG:-NOT FOUND}"
log_info "  Prowlarr slug: ${PROWLARR_SLUG:-NOT FOUND}"

# Get config path for each addon via Supervisor API
get_addon_config_path() {
    local slug="$1"
    curl -sf \
        -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
        "http://supervisor/addons/${slug}/info" 2>/dev/null \
        | jq -r '.data.config_path // empty'
}

extract_api_key_from_xml() {
    local config_path="$1"
    local xml_file="${config_path}/config.xml"
    if [ ! -f "$xml_file" ]; then
        # Try one level deeper — some addons use a subdir
        xml_file=$(find "$config_path" -name "config.xml" 2>/dev/null | head -1)
    fi
    [ -z "$xml_file" ] && return 1
    xmlstarlet sel -t -v "//ApiKey" "$xml_file" 2>/dev/null
}

RADARR_CONFIG_PATH=$(get_addon_config_path "$RADARR_SLUG")
SONARR_CONFIG_PATH=$(get_addon_config_path "$SONARR_SLUG")
PROWLARR_CONFIG_PATH=$(get_addon_config_path "$PROWLARR_SLUG")

log_info "  Radarr config path:   ${RADARR_CONFIG_PATH:-NOT FOUND}"
log_info "  Sonarr config path:   ${SONARR_CONFIG_PATH:-NOT FOUND}"
log_info "  Prowlarr config path: ${PROWLARR_CONFIG_PATH:-NOT FOUND}"

RADARR_API_KEY=$(extract_api_key_from_xml "$RADARR_CONFIG_PATH")
SONARR_API_KEY=$(extract_api_key_from_xml "$SONARR_CONFIG_PATH")
PROWLARR_API_KEY=$(extract_api_key_from_xml "$PROWLARR_CONFIG_PATH")

# Validate we got keys
[ -z "$RADARR_API_KEY" ]   && log_error "Could not extract Radarr API key. Check supervisor logs."
[ -z "$SONARR_API_KEY" ]   && log_error "Could not extract Sonarr API key. Check supervisor logs."
[ -z "$PROWLARR_API_KEY" ] && log_error "Could not extract Prowlarr API key. Check supervisor logs."

log_success "  Radarr API key:   ${RADARR_API_KEY:0:8}..."
log_success "  Sonarr API key:   ${SONARR_API_KEY:0:8}..."
log_success "  Prowlarr API key: ${PROWLARR_API_KEY:0:8}..."

# ── Step 2: Radarr root folder ───────────────────────────────────

log_info "[2/9] Configuring Radarr root folder (${MOVIES_PATH})..."
existing=$(api_get "${RADARR_URL}/api/v3/rootfolder" "$RADARR_API_KEY")
if echo "$existing" | jq -e --arg p "$MOVIES_PATH" '.[] | select(.path == $p)' > /dev/null 2>&1; then
    log_warn "  Already set — skipping."
else
    api_post "${RADARR_URL}/api/v3/rootfolder" "$RADARR_API_KEY" \
        "{\"path\":\"${MOVIES_PATH}\"}" > /dev/null \
        && log_success "  Set to ${MOVIES_PATH}" \
        || log_warn "  Failed — check Radarr UI"
fi

# ── Step 3: Sonarr root folder ───────────────────────────────────

log_info "[3/9] Configuring Sonarr root folder (${TV_PATH})..."
existing=$(api_get "${SONARR_URL}/api/v3/rootfolder" "$SONARR_API_KEY")
if echo "$existing" | jq -e --arg p "$TV_PATH" '.[] | select(.path == $p)' > /dev/null 2>&1; then
    log_warn "  Already set — skipping."
else
    api_post "${SONARR_URL}/api/v3/rootfolder" "$SONARR_API_KEY" \
        "{\"path\":\"${TV_PATH}\"}" > /dev/null \
        && log_success "  Set to ${TV_PATH}" \
        || log_warn "  Failed — check Sonarr UI"
fi

# ── Step 4: qBittorrent → Radarr ────────────────────────────────

log_info "[4/9] Registering qBittorrent in Radarr..."
existing=$(api_get "${RADARR_URL}/api/v3/downloadclient" "$RADARR_API_KEY")
if already_exists "$existing" "qBittorrent"; then
    log_warn "  Already registered — skipping."
else
    PAYLOAD=$(cat <<EOF
{
  "name": "qBittorrent", "enable": true, "protocol": "torrent", "priority": 1,
  "implementation": "QBittorrent", "configContract": "QBittorrentSettings",
  "fields": [
    {"name": "host",                "value": "${HOST}"},
    {"name": "port",                "value": ${QBIT_PORT}},
    {"name": "username",            "value": "${QBIT_USER}"},
    {"name": "password",            "value": "${QBIT_PASS}"},
    {"name": "movieCategory",       "value": "radarr"},
    {"name": "recentMoviePriority", "value": 0},
    {"name": "olderMoviePriority",  "value": 0},
    {"name": "initialState",        "value": 0}
  ]
}
EOF
)
    api_post "${RADARR_URL}/api/v3/downloadclient" "$RADARR_API_KEY" "$PAYLOAD" > /dev/null \
        && log_success "  Registered." || log_warn "  Failed — check Radarr UI"
fi

# ── Step 5: qBittorrent → Sonarr ────────────────────────────────

log_info "[5/9] Registering qBittorrent in Sonarr..."
existing=$(api_get "${SONARR_URL}/api/v3/downloadclient" "$SONARR_API_KEY")
if already_exists "$existing" "qBittorrent"; then
    log_warn "  Already registered — skipping."
else
    PAYLOAD=$(cat <<EOF
{
  "name": "qBittorrent", "enable": true, "protocol": "torrent", "priority": 1,
  "implementation": "QBittorrent", "configContract": "QBittorrentSettings",
  "fields": [
    {"name": "host",             "value": "${HOST}"},
    {"name": "port",             "value": ${QBIT_PORT}},
    {"name": "username",         "value": "${QBIT_USER}"},
    {"name": "password",         "value": "${QBIT_PASS}"},
    {"name": "tvCategory",       "value": "sonarr"},
    {"name": "recentTvPriority", "value": 0},
    {"name": "olderTvPriority",  "value": 0},
    {"name": "initialState",     "value": 0}
  ]
}
EOF
)
    api_post "${SONARR_URL}/api/v3/downloadclient" "$SONARR_API_KEY" "$PAYLOAD" > /dev/null \
        && log_success "  Registered." || log_warn "  Failed — check Sonarr UI"
fi

# ── Step 6: Radarr → Prowlarr ────────────────────────────────────

log_info "[6/9] Registering Radarr in Prowlarr..."
existing=$(api_get "${PROWLARR_URL}/api/v1/applications" "$PROWLARR_API_KEY")
if already_exists "$existing" "Radarr"; then
    log_warn "  Already registered — skipping."
else
    PAYLOAD=$(cat <<EOF
{
  "name": "Radarr", "syncLevel": "addOnly",
  "implementation": "Radarr", "configContract": "RadarrSettings",
  "fields": [
    {"name": "prowlarrUrl",    "value": "${PROWLARR_URL}"},
    {"name": "baseUrl",        "value": "${RADARR_URL}"},
    {"name": "apiKey",         "value": "${RADARR_API_KEY}"},
    {"name": "syncCategories", "value": [2000,2010,2020,2030,2040,2045,2050,2060]}
  ]
}
EOF
)
    api_post "${PROWLARR_URL}/api/v1/applications" "$PROWLARR_API_KEY" "$PAYLOAD" > /dev/null \
        && log_success "  Registered." || log_warn "  Failed — check Prowlarr UI"
fi

# ── Step 7: Sonarr → Prowlarr ────────────────────────────────────

log_info "[7/9] Registering Sonarr in Prowlarr..."
existing=$(api_get "${PROWLARR_URL}/api/v1/applications" "$PROWLARR_API_KEY")
if already_exists "$existing" "Sonarr"; then
    log_warn "  Already registered — skipping."
else
    PAYLOAD=$(cat <<EOF
{
  "name": "Sonarr", "syncLevel": "addOnly",
  "implementation": "Sonarr", "configContract": "SonarrSettings",
  "fields": [
    {"name": "prowlarrUrl",         "value": "${PROWLARR_URL}"},
    {"name": "baseUrl",             "value": "${SONARR_URL}"},
    {"name": "apiKey",              "value": "${SONARR_API_KEY}"},
    {"name": "syncCategories",      "value": [5000,5010,5020,5030,5040,5045,5050]},
    {"name": "animeSyncCategories", "value": [5070]}
  ]
}
EOF
)
    api_post "${PROWLARR_URL}/api/v1/applications" "$PROWLARR_API_KEY" "$PAYLOAD" > /dev/null \
        && log_success "  Registered." || log_warn "  Failed — check Prowlarr UI"
fi

# ── Steps 8 & 9: Connection tests ────────────────────────────────

log_info "[8/9] Testing Radarr → qBittorrent..."
api_get "${RADARR_URL}/api/v3/downloadclient/test" "$RADARR_API_KEY" > /dev/null \
    && log_success "  OK" || log_warn "  Inconclusive — verify in Radarr UI"

log_info "[9/9] Testing Sonarr → qBittorrent..."
api_get "${SONARR_URL}/api/v3/downloadclient/test" "$SONARR_API_KEY" > /dev/null \
    && log_success "  OK" || log_warn "  Inconclusive — verify in Sonarr UI"

echo ""
log_success "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_success "Done! Open Prowlarr and add your indexers."
log_success "They will sync to Radarr and Sonarr automatically."
log_success "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
