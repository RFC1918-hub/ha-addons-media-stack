ARG BUILD_FROM
FROM ${BUILD_FROM}

# Install dependencies
RUN apk add --no-cache \
    bash \
    curl \
    xmlstarlet \
    jq \
    xz

# Install Recyclarr (TRaSH Guides quality sync)
# Uses musl builds — required for Alpine Linux (musl libc)
# Extracts ALL files (.NET host + .dll + deps) into /opt/recyclarr/
# Skipped gracefully on unsupported arches (e.g. i386)
RUN set -e; \
    case "$(uname -m)" in \
        x86_64)        RARCH="x64"   ;; \
        aarch64)       RARCH="arm64" ;; \
        armv7l|armv6l) RARCH="arm"   ;; \
        *) echo "Unsupported arch for Recyclarr: $(uname -m) — skipping" && exit 0 ;; \
    esac; \
    RVER=$(curl -fsSL "https://api.github.com/repos/recyclarr/recyclarr/releases/latest" \
        | jq -r .tag_name); \
    echo "Downloading Recyclarr ${RVER} musl/${RARCH}..."; \
    curl -fL --retry 3 \
        "https://github.com/recyclarr/recyclarr/releases/download/${RVER}/recyclarr-linux-musl-${RARCH}.tar.xz" \
        -o /tmp/recyclarr.tar.xz; \
    mkdir -p /opt/recyclarr; \
    tar -xJf /tmp/recyclarr.tar.xz -C /opt/recyclarr; \
    rm /tmp/recyclarr.tar.xz; \
    chmod +x /opt/recyclarr/recyclarr; \
    ln -s /opt/recyclarr/recyclarr /usr/local/bin/recyclarr; \
    recyclarr --version

# Copy scripts
COPY run.sh /run.sh
COPY configure.sh /configure.sh

# Make executable
RUN chmod +x /run.sh /configure.sh

CMD ["/run.sh"]
