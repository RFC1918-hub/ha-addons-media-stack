ARG BUILD_FROM
FROM ${BUILD_FROM}

# Install dependencies
RUN apk add --no-cache \
    bash \
    curl \
    xmlstarlet \
    jq \
    xz \
    gcompat \
    libstdc++

# .NET self-contained apps need this to avoid requiring ICU libraries
ENV DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=true

# Install Recyclarr (TRaSH Guides quality sync)
# Uses self-contained (glibc) build — gcompat provides glibc shim on Alpine
# Extracts ALL files (.NET host + runtime + deps) into /opt/recyclarr/
# Skipped gracefully on unsupported arches (e.g. i386, armhf)
RUN set -e; \
    case "$(uname -m)" in \
        x86_64)        RARCH="x64"   ;; \
        aarch64)       RARCH="arm64" ;; \
        *) echo "Unsupported arch for Recyclarr: $(uname -m) — skipping" && exit 0 ;; \
    esac; \
    RVER=$(curl -fsSL "https://api.github.com/repos/recyclarr/recyclarr/releases/latest" \
        | jq -r .tag_name); \
    echo "Downloading Recyclarr ${RVER} self-contained/${RARCH}..."; \
    curl -fL --retry 3 \
        "https://github.com/recyclarr/recyclarr/releases/download/${RVER}/recyclarr-linux-${RARCH}.tar.xz" \
        -o /tmp/recyclarr.tar.xz; \
    mkdir -p /opt/recyclarr; \
    tar -xJf /tmp/recyclarr.tar.xz -C /opt/recyclarr; \
    rm /tmp/recyclarr.tar.xz; \
    chmod +x /opt/recyclarr/recyclarr; \
    ln -s /opt/recyclarr/recyclarr /usr/local/bin/recyclarr; \
    echo "Recyclarr installed ($(ls /opt/recyclarr | wc -l) files)"

# Copy scripts
COPY run.sh /run.sh
COPY configure.sh /configure.sh

# Make executable
RUN chmod +x /run.sh /configure.sh

CMD ["/run.sh"]
