#!/usr/bin/env bash

# LOCAL_HOST — used by our curl calls only (we have host_network:true)
LOCAL_HOST="127.0.0.1"
OPTIONS="/data/options.json"

RADARR_URL="http://${LOCAL_HOST}:${RADARR_PORT}"
SONARR_URL="http://${LOCAL_HOST}:${SONARR_PORT}"
PROWLARR_URL="http://${LOCAL_HOST}:${PROWLARR_PORT}"
QBIT_URL="http://${LOCAL_HOST}:${QBIT_PORT}"

# HOST_IP is determined later after SUPERVISOR_TOKEN is available.
# It is used in API *payloads* so that Radarr/Sonarr/Prowlarr (which run
# in isolated containers WITHOUT host_network) can reach each other via
# the real host LAN IP rather than 127.0.0.1 (which is their own loopback).
HOST_IP=""

# ── Logging ──────────────────────────────────────────────────────

log_info()    { echo "[INFO]    $1"; }
log_success() { echo "[OK]      $1"; }
log_error()   { echo "[ERROR]   $1"; exit 1; }
log_warn()    { echo "[WARNING] $1"; }

# ── HTTP helpers ─────────────────────────────────────────────────
# -L = follow redirects (critical — Alexbelgium builds use URL bases
#      like /radarr/ causing 307 redirects on the bare port)

api_get() {
    local url="$1" api_key="$2"
    curl -sfL -H "X-Api-Key: ${api_key}" -H "Content-Type: application/json" "${url}"
}

api_post() {
    local url="$1" api_key="$2" body="$3"
    local response http_code resp_body
    response=$(curl -sL -w "\n%{http_code}" -X POST \
        -H "X-Api-Key: ${api_key}" \
        -H "Content-Type: application/json" \
        -d "${body}" "${url}" 2>/dev/null || true)
    http_code=$(echo "$response" | tail -1)
    resp_body=$(echo "$response" | sed '$d')
    if [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ] 2>/dev/null; then
        echo "$resp_body"
        return 0
    else
        echo "[api_post] HTTP ${http_code} from ${url}" >&2
        echo "[api_post] Response: $(echo "$resp_body" | head -c 500)" >&2
        return 1
    fi
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

log_info "[1/10] Extracting API keys..."

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

# ── Discover host LAN IP for inter-service payloads ──────────────
# Radarr/Sonarr/Prowlarr/qBittorrent run in isolated Docker containers
# WITHOUT host_network, so 127.0.0.1 is THEIR OWN loopback — not the host.
# We must use the host's real LAN IP so they can reach each other.

HOST_IP=$(curl -sf \
    -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
    "http://supervisor/network/info" 2>/dev/null \
    | jq -r '(.data.interfaces // [])[] | select(.primary == true) | (.ipv4.address // [])[0]' 2>/dev/null \
    | cut -d/ -f1)

# Fallback: try hostname -I (works since we have host_network:true)
if [ -z "$HOST_IP" ]; then
    HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
fi

# Last resort fallback
if [ -z "$HOST_IP" ]; then
    HOST_IP="$LOCAL_HOST"
    log_warn "  Could not determine host LAN IP — falling back to 127.0.0.1"
    log_warn "  Inter-service connections (qBittorrent, Prowlarr sync) may fail."
fi

log_info "  Host LAN IP: ${HOST_IP}"

# Build LAN-IP-based URLs for API payloads.
# These are used when we tell one service where to find another — since
# Radarr/Sonarr/Prowlarr/qBittorrent run in isolated containers, they
# must use the real host IP, not 127.0.0.1.
RADARR_EXT_URL="http://${HOST_IP}:${RADARR_PORT}"
SONARR_EXT_URL="http://${HOST_IP}:${SONARR_PORT}"
PROWLARR_EXT_URL="http://${HOST_IP}:${PROWLARR_PORT}"
QBIT_EXT_HOST="${HOST_IP}"

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

# ── Ensure media directories exist ───────────────────────────────
# Radarr/Sonarr validate the path EXISTS before accepting the root folder.
# We have media:rw, so we can create them now.
log_info "  Creating media directories if needed..."
mkdir -p "${MOVIES_PATH}" && log_info "    ${MOVIES_PATH} — OK" || log_warn "    Could not create ${MOVIES_PATH}"
mkdir -p "${TV_PATH}"     && log_info "    ${TV_PATH} — OK"     || log_warn "    Could not create ${TV_PATH}"

# ── Step 2: Radarr root folder ───────────────────────────────────

log_info "[2/10] Configuring Radarr root folder (${MOVIES_PATH})..."
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

log_info "[3/10] Configuring Sonarr root folder (${TV_PATH})..."
existing=$(api_get "${SONARR_URL}/api/v3/rootfolder" "$SONARR_API_KEY")
if echo "$existing" | jq -e --arg p "$TV_PATH" '.[] | select(.path == $p)' > /dev/null 2>&1; then
    log_warn "  Already set — skipping."
else
    api_post "${SONARR_URL}/api/v3/rootfolder" "$SONARR_API_KEY" \
        "{\"path\":\"${TV_PATH}\"}" > /dev/null \
        && log_success "  Set to ${TV_PATH}" \
        || log_warn "  Failed — check Sonarr UI"
fi

# ── Steps 4 & 5: Register qBittorrent ───────────────────────────
#
# Alexbelgium's qBittorrent addon runs qBittorrent's WebUI on an internal
# port (default 8080) but publishes it to host port 8081, while a separate
# VueTorrent SPA frontend is served at host port 8080. We must auto-detect
# which host port has the actual /api/v2/ backend.

# Auto-detect the real qBittorrent API port: the config port serves the
# VueTorrent SPA; the API is typically at config_port+1.
QBIT_API_PORT=""
# Candidates: QBIT_PORT+1 first (Alexbelgium default), then QBIT_PORT itself,
# then a few other common ports.
_qbit_next=$(( QBIT_PORT + 1 ))
for try_port in "${_qbit_next}" "${QBIT_PORT}" 8081 8082 8090; do
    _ver=$(curl -s --max-time 5 \
        "http://${LOCAL_HOST}:${try_port}/api/v2/app/version" 2>/dev/null || true)
    # Valid response is a short version string like "v5.x.y", not HTML
    if [ -n "$_ver" ] && [ "${_ver#<}" = "$_ver" ]; then
        QBIT_API_PORT="$try_port"
        log_info "  qBittorrent API port detected: ${QBIT_API_PORT} (version: ${_ver})"
        break
    fi
    log_info "  Port ${try_port}: no API response (body preview: '${_ver:0:30}')"
done
if [ -z "$QBIT_API_PORT" ]; then
    log_warn "  Could not auto-detect qBittorrent API port — falling back to ${QBIT_PORT}"
    QBIT_API_PORT="$QBIT_PORT"
fi

# URL base detection on the confirmed API port
QBIT_URL_BASE=""
for try_base in "" "/qbittorrent" "/downloads" "/qbt"; do
    probe=$(curl -s --max-time 5 \
        -X POST \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "username=probe&password=probe" \
        "http://${LOCAL_HOST}:${QBIT_API_PORT}${try_base}/api/v2/auth/login" 2>/dev/null || true)
    if [ "$probe" = "Fails." ] || [ "$probe" = "Ok." ]; then
        QBIT_URL_BASE="$try_base"
        log_info "  qBittorrent URL base: '${try_base:-<root>}'"
        break
    fi
done

QBIT_LOGIN_URL="http://${LOCAL_HOST}:${QBIT_API_PORT}${QBIT_URL_BASE}/api/v2/auth/login"
log_info "  qBittorrent login URL: ${QBIT_LOGIN_URL}"

qbit_try_login() {
    local user="$1" pass="$2"
    local result
    result=$(curl -s --max-time 5 \
        -c /tmp/qbit_cookies.txt \
        -X POST \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "username=${user}&password=${pass}" \
        "${QBIT_LOGIN_URL}" 2>/dev/null || true)
    log_info "    → login '${user}':'${pass:+***}' → '${result:0:40}'"
    [ "$result" = "Ok." ]
}

# Also try to read the password from the Alexbelgium addon's own options
QBIT_SLUG="${ALEX_PREFIX}_qbittorrent"
QBIT_ADDON_PASS=""
if [ -n "$SUPERVISOR_TOKEN" ]; then
    QBIT_ADDON_PASS=$(curl -sf \
        -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
        "http://supervisor/addons/${QBIT_SLUG}/info" 2>/dev/null \
        | jq -r '.data.options.password // .data.options.WebUiPassword // .data.options.webui_password // empty' 2>/dev/null || true)
    if [ -n "$QBIT_ADDON_PASS" ]; then
        log_info "  Found password in qBittorrent addon options via Supervisor API"
    fi
fi

log_info "[4-5/10] Probing qBittorrent credentials..."
QBIT_WORKING_USER=""
QBIT_WORKING_PASS=""

# Build candidate list: Supervisor-sourced password first, then configured, then defaults
declare -a TRY_USERS=()
declare -a TRY_PASSES=()
if [ -n "$QBIT_ADDON_PASS" ]; then
    TRY_USERS+=("admin")
    TRY_PASSES+=("$QBIT_ADDON_PASS")
fi
TRY_USERS+=("$QBIT_USER"  "admin"       "admin" "admin" "")
TRY_PASSES+=("$QBIT_PASS" "adminadmin"  "admin" ""      "")

for i in "${!TRY_USERS[@]}"; do
    u="${TRY_USERS[$i]}"
    p="${TRY_PASSES[$i]}"
    if qbit_try_login "$u" "$p"; then
        log_success "  Working credentials found — user: '${u}'"
        [ -n "$p" ] || log_success "  (empty password / auth may be disabled)"
        QBIT_WORKING_USER="$u"
        QBIT_WORKING_PASS="$p"
        break
    fi
done

if [ -z "$QBIT_WORKING_USER" ] && [ -z "$QBIT_WORKING_PASS" ]; then
    # Final check: maybe auth is disabled (any login returns Ok.)
    if qbit_try_login "wronguser" "wrongpass"; then
        log_success "  qBittorrent auth is disabled — no credentials needed"
        QBIT_WORKING_USER="$QBIT_USER"
        QBIT_WORKING_PASS=""
    else
        log_warn "  Could not authenticate to qBittorrent with any known credentials."
        log_warn "  ► Open qBittorrent web UI → Tools → Options → Web UI"
        log_warn "    Either disable authentication, or note the password and set"
        log_warn "    qbittorrent_password in THIS addon's Configuration tab."
        log_warn "  Continuing — registration will fail until credentials are fixed."
        QBIT_WORKING_USER="$QBIT_USER"
        QBIT_WORKING_PASS="$QBIT_PASS"
    fi
fi

register_qbittorrent() {
    local arr_name="$1"
    local arr_url="$2"
    local arr_key="$3"
    local category="$4"
    local endpoint="$5"   # api/v3 for Radarr/Sonarr
    local cat_field="$6"  # movieCategory or tvCategory

    log_info "[${arr_name}] Registering qBittorrent..."
    local existing
    existing=$(api_get "${arr_url}/${endpoint}/downloadclient" "$arr_key")
    if already_exists "$existing" "qBittorrent"; then
        log_warn "  Already registered — skipping."
        return 0
    fi

    local PAYLOAD
    PAYLOAD=$(cat <<EOF
{
  "name": "qBittorrent", "enable": true, "protocol": "torrent", "priority": 1,
  "implementation": "QBittorrent", "configContract": "QBittorrentSettings",
  "fields": [
    {"name": "host",          "value": "${QBIT_EXT_HOST}"},
    {"name": "port",          "value": ${QBIT_API_PORT}},
    {"name": "useSsl",        "value": false},
    {"name": "urlBase",       "value": "${QBIT_URL_BASE}"},
    {"name": "username",      "value": "${QBIT_WORKING_USER}"},
    {"name": "password",      "value": "${QBIT_WORKING_PASS}"},
    {"name": "${cat_field}",  "value": "${category}"},
    {"name": "initialState",  "value": 0}
  ]
}
EOF
)
    if api_post "${arr_url}/${endpoint}/downloadclient" "$arr_key" "$PAYLOAD" > /dev/null; then
        log_success "  Registered."
    else
        log_warn "  Failed to register qBittorrent in ${arr_name}."
        log_warn "  ► Most likely cause: wrong qBittorrent credentials."
        log_warn "  ► Fix: in the Alexbelgium qBittorrent addon go to"
        log_warn "         Configuration → set a WebUI password, then set"
        log_warn "         qbittorrent_password in THIS addon's Configuration"
        log_warn "         tab to the same value and re-run."
        log_warn "  ► Or disable authentication in qBittorrent:"
        log_warn "         Tools → Options → Web UI → uncheck 'Authentication'"
        return 1
    fi
}

log_info "[4/10] Registering qBittorrent in Radarr..."
register_qbittorrent "Radarr" "$RADARR_URL" "$RADARR_API_KEY" "radarr" "api/v3" "movieCategory"

log_info "[5/10] Registering qBittorrent in Sonarr..."
register_qbittorrent "Sonarr" "$SONARR_URL" "$SONARR_API_KEY" "sonarr" "api/v3" "tvCategory"

# ── Step 6: Radarr → Prowlarr ────────────────────────────────────

log_info "[6/10] Registering Radarr in Prowlarr..."
existing=$(api_get "${PROWLARR_URL}/api/v1/applications" "$PROWLARR_API_KEY")
if already_exists "$existing" "Radarr"; then
    log_warn "  Already registered — skipping."
else
    PAYLOAD=$(cat <<EOF
{
  "name": "Radarr", "syncLevel": "addOnly",
  "implementation": "Radarr", "configContract": "RadarrSettings",
  "fields": [
    {"name": "prowlarrUrl",    "value": "${PROWLARR_EXT_URL}"},
    {"name": "baseUrl",        "value": "${RADARR_EXT_URL}"},
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

log_info "[7/10] Registering Sonarr in Prowlarr..."
existing=$(api_get "${PROWLARR_URL}/api/v1/applications" "$PROWLARR_API_KEY")
if already_exists "$existing" "Sonarr"; then
    log_warn "  Already registered — skipping."
else
    PAYLOAD=$(cat <<EOF
{
  "name": "Sonarr", "syncLevel": "addOnly",
  "implementation": "Sonarr", "configContract": "SonarrSettings",
  "fields": [
    {"name": "prowlarrUrl",         "value": "${PROWLARR_EXT_URL}"},
    {"name": "baseUrl",             "value": "${SONARR_EXT_URL}"},
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

verify_download_client() {
    local name="$1" url="$2" api_key="$3"
    log_info "  Verifying ${name} download clients..."
    local response http_code body
    # Use -L to follow redirects, -w to get HTTP status code
    response=$(curl -sL -w "\n%{http_code}" \
        -H "X-Api-Key: ${api_key}" \
        -H "Content-Type: application/json" \
        "${url}/api/v3/downloadclient" 2>/dev/null || true)
    http_code=$(echo "$response" | tail -1)
    body=$(echo "$response" | sed '$d')
    log_info "    HTTP ${http_code} — ${#body} bytes"
    if [ -z "$body" ]; then
        log_warn "    Empty response from ${name}"
        return 1
    fi
    # Check if response is valid JSON array
    if ! echo "$body" | jq -e 'type == "array"' > /dev/null 2>&1; then
        log_warn "    Response is not a JSON array: $(echo "$body" | head -c 200)"
        return 1
    fi
    local count
    count=$(echo "$body" | jq 'length')
    log_info "    ${count} download client(s) registered"
    if echo "$body" | jq -e '.[] | select(.name == "qBittorrent")' > /dev/null 2>&1; then
        log_success "  qBittorrent is registered in ${name}"
        return 0
    else
        # Show what names ARE there
        local names
        names=$(echo "$body" | jq -r '.[].name' 2>/dev/null | tr '\n' ', ')
        log_warn "  qBittorrent not found — registered names: ${names:-none}"
        return 1
    fi
}

log_info "[8/10] Verifying Radarr download client..."
verify_download_client "Radarr" "$RADARR_URL" "$RADARR_API_KEY"

log_info "[9/10] Verifying Sonarr download client..."
verify_download_client "Sonarr" "$SONARR_URL" "$SONARR_API_KEY"

# ── Step 10: Recyclarr — TRaSH Guides quality sync ───────────────

RECYCLARR_ENABLED=$(jq -r '.recyclarr_enabled // true' "$OPTIONS" 2>/dev/null)

if [ "$RECYCLARR_ENABLED" = "true" ]; then
    log_info "[10/10] Running Recyclarr (TRaSH Guides quality sync)..."
    if ! command -v recyclarr > /dev/null 2>&1; then
        log_warn "  Recyclarr binary not found — skipping."
    elif ! recyclarr --version > /dev/null 2>&1; then
        log_warn "  Recyclarr installed but cannot execute (missing runtime?) — skipping."
    else
        # Probe which URL Recyclarr can actually reach for Radarr
        # (curl follows redirects; .NET HttpClient may not, and IPv6/loopback
        #  can behave differently between curl and .NET)
        # Probe which URL Recyclarr can reach.
        # We use curl -L and capture %{url_effective} — the final URL after any
        # 307 redirects — then strip /api/v3/system/status to get the true
        # base_url. .NET HttpClient does not follow redirects, so we must give
        # Recyclarr the already-resolved URL (e.g. including /radarr if set).
        probe_recyclarr_url() {
            local port="$1" api_key="$2" label="$3"
            local tmpbody
            tmpbody=$(mktemp)
            for try_host in "${LOCAL_HOST}" "${HOST_IP}"; do
                local effective
                effective=$(curl -sfL --max-time 5 \
                    -H "X-Api-Key: ${api_key}" \
                    -o "${tmpbody}" \
                    -w "%{url_effective}" \
                    "http://${try_host}:${port}/api/v3/system/status" 2>/dev/null || true)
                if jq -e '.appName' "${tmpbody}" > /dev/null 2>&1; then
                    rm -f "${tmpbody}"
                    # Strip the API path suffix to obtain just the base URL
                    echo "${effective%/api/v3/system/status}"
                    return 0
                fi
                log_info "  ${label} not reachable at ${try_host}:${port} — trying next"
            done
            rm -f "${tmpbody}"
            return 1
        }

        RECYCLARR_RADARR_URL=$(probe_recyclarr_url "$RADARR_PORT" "$RADARR_API_KEY" "Radarr") || true
        RECYCLARR_SONARR_URL=$(probe_recyclarr_url "$SONARR_PORT" "$SONARR_API_KEY" "Sonarr") || true
        log_info "  Recyclarr Radarr URL: ${RECYCLARR_RADARR_URL:-not found}"
        log_info "  Recyclarr Sonarr URL: ${RECYCLARR_SONARR_URL:-not found}"

        if [ -z "$RECYCLARR_RADARR_URL" ] || [ -z "$RECYCLARR_SONARR_URL" ]; then
            log_warn "  Could not determine reachable URL for Radarr/Sonarr — skipping Recyclarr."
        else
            cat > /tmp/recyclarr.yml <<EOF
radarr:
  movies:
    base_url: ${RECYCLARR_RADARR_URL}
    api_key: ${RADARR_API_KEY}
    quality_definition:
      type: movie
    media_naming:
      folder: default
      movie:
        rename: true
        standard: default
sonarr:
  series:
    base_url: ${RECYCLARR_SONARR_URL}
    api_key: ${SONARR_API_KEY}
    quality_definition:
      type: series
    media_naming:
      series: default
      season: default
      episodes:
        rename: true
        standard: default
        daily: default
        anime: default
EOF
            log_info "  Syncing quality definitions and naming scheme from TRaSH Guides..."
            if recyclarr sync --config /tmp/recyclarr.yml 2>&1 | \
                    while IFS= read -r line; do log_info "    ${line}"; done; then
                log_success "  Recyclarr sync completed."
            else
                log_warn "  Recyclarr sync encountered issues — check output above."
                log_warn "  Quality definitions may not be set; configure them manually in Radarr/Sonarr."
            fi
            rm -f /tmp/recyclarr.yml
        fi
    fi
else
    log_info "[10/10] Recyclarr disabled — skipping."
fi

echo ""
log_success "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_success "Configuration complete!"
log_success "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info ""
log_info "Next steps:"
log_info "  1. Open Prowlarr → Indexers → Add your indexers"
log_info "     They will auto-sync to Radarr and Sonarr."
log_info "  2. Open Radarr → Add movies (they download via qBittorrent)"
log_info "  3. Open Sonarr → Add TV shows"
log_info "  4. Open Jellyfin → Add library pointing to /media/movies and /media/tv"