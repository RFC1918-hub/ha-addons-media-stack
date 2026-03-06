ARG BUILD_FROM
FROM ${BUILD_FROM}

# Install dependencies
RUN apk add --no-cache \
    bash \
    curl \
    xmlstarlet \
    jq

# Install Recyclarr (TRaSH Guides quality sync)
# Skipped gracefully on unsupported arches (e.g. i386)
RUN set -e; \
    case "$(uname -m)" in \
        x86_64)        RARCH="x64"   ;; \
        aarch64)       RARCH="arm64" ;; \
        armv7l|armv6l) RARCH="arm"   ;; \
        *) echo "Unsupported arch for Recyclarr: $(uname -m) — skipping" && exit 0 ;; \
    esac; \
    RVER=$(curl -sfL "https://api.github.com/repos/recyclarr/recyclarr/releases/latest" \
        | jq -r .tag_name); \
    echo "Downloading Recyclarr ${RVER} for ${RARCH}..."; \
    curl -sfL \
        "https://github.com/recyclarr/recyclarr/releases/download/${RVER}/recyclarr-linux-${RARCH}.tar.gz" \
        | tar -xz -C /usr/local/bin recyclarr; \
    chmod +x /usr/local/bin/recyclarr; \
    recyclarr --version

# Copy scripts
COPY run.sh /run.sh
COPY configure.sh /configure.sh

# Make executable
RUN chmod +x /run.sh /configure.sh

CMD ["/run.sh"]
