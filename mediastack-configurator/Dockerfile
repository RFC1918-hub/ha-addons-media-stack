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

# Copy the .NET runtime from the Recyclarr image (it's based on dotnet/runtime:10.0-alpine)
COPY --from=recyclarr /usr/share/dotnet /usr/share/dotnet

# Copy Recyclarr app from the official image (binary + managed DLLs live at /app/recyclarr/)
COPY --from=recyclarr /app/recyclarr /opt/recyclarr
RUN ln -s /opt/recyclarr/recyclarr /usr/local/bin/recyclarr

# .NET runtime configuration
ENV DOTNET_ROOT=/usr/share/dotnet \
    DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=false \
    COMPlus_EnableDiagnostics=0

# Copy scripts
COPY run.sh /run.sh
COPY configure.sh /configure.sh

# Make executable
RUN chmod +x /run.sh /configure.sh

CMD ["/run.sh"]
