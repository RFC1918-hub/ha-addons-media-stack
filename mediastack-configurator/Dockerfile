ARG BUILD_FROM

# ── Stage 1: grab Recyclarr from its official Docker image ──────
# This avoids .NET runtime issues entirely — the image ships a
# working, pre-configured binary for each arch.
FROM ghcr.io/recyclarr/recyclarr:latest AS recyclarr

# ── Stage 2: main addon image ───────────────────────────────────
FROM ${BUILD_FROM}

# Install dependencies
RUN apk add --no-cache \
    bash \
    curl \
    xmlstarlet \
    jq \
    libstdc++ \
    libgcc \
    icu-libs

# Copy Recyclarr from the official image (includes .NET runtime + all deps)
COPY --from=recyclarr /app /opt/recyclarr
RUN ln -s /opt/recyclarr/recyclarr /usr/local/bin/recyclarr

# .NET needs ICU or this flag to run without it
ENV DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=false

# Copy scripts
COPY run.sh /run.sh
COPY configure.sh /configure.sh

# Make executable
RUN chmod +x /run.sh /configure.sh

CMD ["/run.sh"]
