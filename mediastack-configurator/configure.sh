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
    curl -sf -X POST -H "X-Api-Key: ${api_key}" -H "Content-Type: application/json" -d "${body}" "${url}"
}

already_exists() {
    echo "$1" | jq -e --arg n "$2" '.[] | select(.name == $n)' > /dev/null 2>&1
}

# ── Step 1: Validate API keys ────────────────────────────────────

log_info "[1/9] Validating API keys..."

test_api_key() {
    local name="$1" url="$2" key="$3"
    local result
    result=$(curl -sf -H "X-Api-Key: ${key}" "${url}/api/v3/system/status" 2>/dev/null)
    if [ -z "$result" ]; then
        log_error "${name} API key rejected or service not responding. Check the key in your addon config."
    fi
    log_success "  ${name} API key valid."
}

# Prowlarr uses v1
test_prowlarr_key() {
    local key="$1"
    local result
    result=$(curl -sf -H "X-Api-Key: ${key}" "${PROWLARR_URL}/api/v1/system/status" 2>/dev/null)
    if [ -z "$result" ]; then
        log_error "Prowlarr API key rejected. Check the key in your addon config."
    fi
    log_success "  Prowlarr API key valid."
}

test_api_key "Radarr"   "$RADARR_URL"   "$RADARR_API_KEY"
test_api_key "Sonarr"   "$SONARR_URL"   "$SONARR_API_KEY"
test_prowlarr_key "$PROWLARR_API_KEY"

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
  "name": "qBittorrent",
  "enable": true,
  "protocol": "torrent",
  "priority": 1,
  "implementation": "QBittorrent",
  "configContract": "QBittorrentSettings",
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
  "name": "qBittorrent",
  "enable": true,
  "protocol": "torrent",
  "priority": 1,
  "implementation": "QBittorrent",
  "configContract": "QBittorrentSettings",
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
  "name": "Radarr",
  "syncLevel": "addOnly",
  "implementation": "Radarr",
  "configContract": "RadarrSettings",
  "fields": [
    {"name": "prowlarrUrl",     "value": "${PROWLARR_URL}"},
    {"name": "baseUrl",         "value": "${RADARR_URL}"},
    {"name": "apiKey",          "value": "${RADARR_API_KEY}"},
    {"name": "syncCategories",  "value": [2000,2010,2020,2030,2040,2045,2050,2060]}
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
  "name": "Sonarr",
  "syncLevel": "addOnly",
  "implementation": "Sonarr",
  "configContract": "SonarrSettings",
  "fields": [
    {"name": "prowlarrUrl",          "value": "${PROWLARR_URL}"},
    {"name": "baseUrl",              "value": "${SONARR_URL}"},
    {"name": "apiKey",               "value": "${SONARR_API_KEY}"},
    {"name": "syncCategories",       "value": [5000,5010,5020,5030,5040,5045,5050]},
    {"name": "animeSyncCategories",  "value": [5070]}
  ]
}
EOF
)
    api_post "${PROWLARR_URL}/api/v1/applications" "$PROWLARR_API_KEY" "$PAYLOAD" > /dev/null \
        && log_success "  Registered." || log_warn "  Failed — check Prowlarr UI"
fi

# ── Step 8 & 9: Connection tests ─────────────────────────────────

log_info "[8/9] Testing Radarr → qBittorrent..."
api_get "${RADARR_URL}/api/v3/downloadclient/test" "$RADARR_API_KEY" > /dev/null \
    && log_success "  OK" || log_warn "  Test inconclusive — verify in Radarr UI"

log_info "[9/9] Testing Sonarr → qBittorrent..."
api_get "${SONARR_URL}/api/v3/downloadclient/test" "$SONARR_API_KEY" > /dev/null \
    && log_success "  OK" || log_warn "  Test inconclusive — verify in Sonarr UI"

# ── Summary ──────────────────────────────────────────────────────

echo ""
log_success "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_success "Configuration complete!"
log_success "  ✓ Radarr root folder  → ${MOVIES_PATH}"
log_success "  ✓ Sonarr root folder  → ${TV_PATH}"
log_success "  ✓ qBittorrent         → Radarr + Sonarr"
log_success "  ✓ Radarr + Sonarr     → Prowlarr"
log_success "Next: Open Prowlarr and add your indexers."
log_success "They will sync automatically to Radarr and Sonarr."
log_success "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
