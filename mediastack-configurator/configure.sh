#!/usr/bin/env bash

HOST="127.0.0.1"
OPTIONS="/data/options.json"

RADARR_URL="http://${HOST}:${RADARR_PORT}"
SONARR_URL="http://${HOST}:${SONARR_PORT}"
PROWLARR_URL="http://${HOST}:${PROWLARR_PORT}"
QBIT_URL="http://${HOST}:${QBIT_PORT}"

# ── Logging ──────────────────────────────────────────────────────

log_info()    { echo "[INFO]    $1"; }
log_success() { echo "[OK]      $1"; }
log_error()   { echo "[ERROR]   $1"; exit 1; }
log_warn()    { echo "[WARNING] $1"; }

# ── HTTP helpers ─────────────────────────────────────────────────

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

# ── API Key extraction (multi-strategy) ──────────────────────────
#
# Tries these methods in order:
#   1. Manual key from addon options (always wins if provided)
#   2. Scrape from *arr web UI HTML (window.Radarr = {"apiKey":"..."})
#   3. Try /initialize.js endpoint
#   4. Try /initialize.json endpoint
#   5. Read config.xml from filesystem (/addon_configs/{slug}/...)
#
# Falls back to clear error message telling user to set the key
# manually in addon options.

ALEX_PREFIX="dad6a9e6"

extract_api_key() {
    local service_name="$1"
    local service_url="$2"
    local manual_key="$3"
    local slug="$4"
    local key="" response=""

    # NOTE: All log output in this function goes to stderr (>&2)
    # because stdout is used to return the API key via echo.

    # ── Strategy 1: Manual key from addon options ────────────────
    if [ -n "$manual_key" ] && [ "$manual_key" != "null" ]; then
        echo "    → Using manually provided key" >&2
        echo "$manual_key"
        return 0
    fi

    # ── Strategy 2: Scrape from web UI HTML ──────────────────────
    #    Modern *arr apps embed: window.Radarr = {"apiKey":"<hex>", ...}
    response=$(curl -sf -L --max-time 10 "${service_url}/" 2>/dev/null || true)
    if [ -n "$response" ]; then
        echo "    → Web UI returned ${#response} bytes" >&2
        # Show first 500 chars for debugging
        echo "    → HTML preview: $(echo "$response" | head -c 500 | tr '\n' ' ')" >&2
        # Primary pattern: "apiKey":"<hex>"
        key=$(echo "$response" | grep -oE '"apiKey":"[a-fA-F0-9]+"' | head -1 | sed 's/"apiKey":"//;s/"//')
        if [ -n "$key" ]; then
            echo "    → Extracted from web UI HTML" >&2
            echo "$key"
            return 0
        fi
        # Alt: apiKey in single quotes or with spaces
        key=$(echo "$response" | grep -oE "apiKey['\"]?[: ]*['\"]?[a-fA-F0-9]{20,}" | head -1 | grep -oE '[a-fA-F0-9]{20,}')
        if [ -n "$key" ]; then
            echo "    → Extracted from web UI HTML (alt pattern)" >&2
            echo "$key"
            return 0
        fi
    else
        echo "    → Web UI returned empty response from ${service_url}/" >&2
    fi

    # ── Strategy 3: /initialize.js ───────────────────────────────
    response=$(curl -sf -L --max-time 10 "${service_url}/initialize.js" 2>/dev/null || true)
    if [ -n "$response" ]; then
        echo "    → initialize.js returned ${#response} bytes" >&2
        key=$(echo "$response" | grep -oE '"apiKey":"[a-fA-F0-9]+"' | head -1 | sed 's/"apiKey":"//;s/"//')
        if [ -n "$key" ]; then
            echo "    → Extracted from initialize.js" >&2
            echo "$key"
            return 0
        fi
    else
        echo "    → initialize.js empty or not found" >&2
    fi

    # ── Strategy 4: /initialize.json ─────────────────────────────
    response=$(curl -sf -L --max-time 10 "${service_url}/initialize.json" 2>/dev/null || true)
    if [ -n "$response" ]; then
        echo "    → initialize.json returned ${#response} bytes" >&2
        key=$(echo "$response" | jq -r '.apiKey // empty' 2>/dev/null)
        if [ -n "$key" ]; then
            echo "    → Extracted from initialize.json" >&2
            echo "$key"
            return 0
        fi
    else
        echo "    → initialize.json empty or not found" >&2
    fi

    # ── Strategy 5: API endpoint without auth (some builds) ──────
    #    Try /api/v3/system/status and /api/v1/system/status — some
    #    *arr builds allow unauthenticated access from localhost.
    for api_ver in v3 v1; do
        response=$(curl -sf -L --max-time 10 "${service_url}/api/${api_ver}/system/status" 2>/dev/null || true)
        if [ -n "$response" ]; then
            echo "    → /api/${api_ver}/system/status returned data" >&2
            break
        fi
    done

    # ── Strategy 6: Supervisor API — read addon info/stats ───────
    if [ -n "$SUPERVISOR_TOKEN" ] && [ -n "$slug" ]; then
        # Try to get the addon's webui URL or other info
        local addon_info
        addon_info=$(curl -sf \
            -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
            "http://supervisor/addons/${slug}/info" 2>/dev/null || true)
        if [ -n "$addon_info" ]; then
            echo "    → Supervisor addon info keys: $(echo "$addon_info" | jq -r '.data | keys[]' 2>/dev/null | tr '\n' ', ')" >&2
            # Check if there's an options field that might contain the API key
            local options_key
            options_key=$(echo "$addon_info" | jq -r '.data.options.ApiKey // .data.options.apiKey // .data.options.api_key // empty' 2>/dev/null)
            if [ -n "$options_key" ]; then
                echo "    → Extracted from Supervisor addon options" >&2
                echo "$options_key"
                return 0
            fi
        fi
    fi

    # ── Strategy 7: Read config.xml from filesystem ──────────────
    if [ -n "$slug" ]; then
        local search_dirs=(
            "/addon_configs/${slug}"
            "/config/addons_config/${slug}"
            "/share/${slug}"
            "/data/addons/${slug}"
            "/config/${slug}"
        )
        for base_dir in "${search_dirs[@]}"; do
            if [ -d "$base_dir" ]; then
                echo "    → Searching ${base_dir} for config.xml..." >&2
                local xml_file
                xml_file=$(find "$base_dir" -name "config.xml" -type f 2>/dev/null | head -1)
                if [ -n "$xml_file" ]; then
                    key=$(xmlstarlet sel -t -v "//ApiKey" "$xml_file" 2>/dev/null)
                    if [ -n "$key" ]; then
                        echo "    → Extracted from ${xml_file}" >&2
                        echo "$key"
                        return 0
                    fi
                fi
            fi
        done
        echo "    → No config.xml found in any search path" >&2
    fi

    # ── All strategies failed ────────────────────────────────────
    echo "    → All auto-extraction methods failed for ${service_name}" >&2
    return 1
}

# ── Step 1: Extract API keys ─────────────────────────────────────

log_info "[1/9] Extracting API keys..."

# Discover addon slugs via Supervisor API (single call)
ADDON_LIST=""
if [ -n "$SUPERVISOR_TOKEN" ]; then
    ADDON_LIST=$(curl -sf \
        -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
        "http://supervisor/addons" 2>/dev/null)
    if [ -n "$ADDON_LIST" ]; then
        log_info "  Installed addons:"
        echo "$ADDON_LIST" | jq -r '.data.addons[] | "    \(.slug)  \(.name)  [\(.state)]"' 2>/dev/null || true
    else
        log_warn "  Could not list addons from Supervisor API"
    fi
else
    log_warn "  SUPERVISOR_TOKEN not set — slug discovery disabled"
fi

find_slug() {
    local pattern="$1" fallback="$2"
    local slug=""
    if [ -n "$ADDON_LIST" ]; then
        # First: match name AND Alexbelgium slug prefix
        slug=$(echo "$ADDON_LIST" | jq -r --arg pat "$pattern" --arg pfx "${ALEX_PREFIX}_" \
            '.data.addons[] | select((.name | test($pat; "i")) and (.slug | startswith($pfx))) | .slug' \
            | head -1)
        # Second: just match name (non-Alexbelgium installs)
        if [ -z "$slug" ]; then
            slug=$(echo "$ADDON_LIST" | jq -r --arg pat "$pattern" \
                '.data.addons[] | select(.name | test($pat; "i")) | .slug' | head -1)
        fi
    fi
    echo "${slug:-$fallback}"
}

RADARR_SLUG=$(find_slug "radarr" "${ALEX_PREFIX}_radarr_nas")
SONARR_SLUG=$(find_slug "sonarr" "${ALEX_PREFIX}_sonarr_nas")
PROWLARR_SLUG=$(find_slug "prowlarr" "${ALEX_PREFIX}_prowlarr")

log_info "  Resolved slugs:"
log_info "    Radarr:   ${RADARR_SLUG}"
log_info "    Sonarr:   ${SONARR_SLUG}"
log_info "    Prowlarr: ${PROWLARR_SLUG}"

# Debug: list what is visible in /addon_configs/
if [ -d "/addon_configs" ]; then
    log_info "  Directories in /addon_configs/:"
    ls -1 /addon_configs/ 2>/dev/null | while read -r d; do log_info "    ${d}"; done
else
    log_warn "  /addon_configs/ not mounted"
fi

# Read manual API keys from addon options (empty = not set)
MANUAL_RADARR_KEY=$(jq -r '.radarr_api_key // empty' "$OPTIONS" 2>/dev/null)
MANUAL_SONARR_KEY=$(jq -r '.sonarr_api_key // empty' "$OPTIONS" 2>/dev/null)
MANUAL_PROWLARR_KEY=$(jq -r '.prowlarr_api_key // empty' "$OPTIONS" 2>/dev/null)

log_info "  Extracting Radarr API key..."
RADARR_API_KEY=$(extract_api_key "Radarr" "$RADARR_URL" "$MANUAL_RADARR_KEY" "$RADARR_SLUG") || RADARR_API_KEY=""
if [ -z "$RADARR_API_KEY" ]; then
    log_error "Could not extract Radarr API key. Set radarr_api_key in addon Configuration tab."
fi

log_info "  Extracting Sonarr API key..."
SONARR_API_KEY=$(extract_api_key "Sonarr" "$SONARR_URL" "$MANUAL_SONARR_KEY" "$SONARR_SLUG") || SONARR_API_KEY=""
if [ -z "$SONARR_API_KEY" ]; then
    log_error "Could not extract Sonarr API key. Set sonarr_api_key in addon Configuration tab."
fi

log_info "  Extracting Prowlarr API key..."
PROWLARR_API_KEY=$(extract_api_key "Prowlarr" "$PROWLARR_URL" "$MANUAL_PROWLARR_KEY" "$PROWLARR_SLUG") || PROWLARR_API_KEY=""
if [ -z "$PROWLARR_API_KEY" ]; then
    log_error "Could not extract Prowlarr API key. Set prowlarr_api_key in addon Configuration tab."
fi

log_success "  All API keys obtained:"
log_success "    Radarr:   ${RADARR_API_KEY:0:8}..."
log_success "    Sonarr:   ${SONARR_API_KEY:0:8}..."
log_success "    Prowlarr: ${PROWLARR_API_KEY:0:8}..."

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
    {"name": "useSsl",              "value": false},
    {"name": "urlBase",             "value": ""},
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
    {"name": "useSsl",           "value": false},
    {"name": "urlBase",          "value": ""},
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

# ── Steps 8 & 9: Verification ───────────────────────────────────

log_info "[8/9] Verifying Radarr download client..."
existing=$(api_get "${RADARR_URL}/api/v3/downloadclient" "$RADARR_API_KEY")
if echo "$existing" | jq -e '.[] | select(.name == "qBittorrent")' > /dev/null 2>&1; then
    log_success "  qBittorrent is registered in Radarr"
else
    log_warn "  qBittorrent not found in Radarr — check Radarr UI"
fi

log_info "[9/9] Verifying Sonarr download client..."
existing=$(api_get "${SONARR_URL}/api/v3/downloadclient" "$SONARR_API_KEY")
if echo "$existing" | jq -e '.[] | select(.name == "qBittorrent")' > /dev/null 2>&1; then
    log_success "  qBittorrent is registered in Sonarr"
else
    log_warn "  qBittorrent not found in Sonarr — check Sonarr UI"
fi

echo ""
log_success "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_success "Done! Open Prowlarr and add your indexers."
log_success "They will sync to Radarr and Sonarr automatically."
log_success "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"