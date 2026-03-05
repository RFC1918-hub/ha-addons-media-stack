ARG BUILD_FROM
FROM ${BUILD_FROM}

# Install dependencies
RUN apk add --no-cache \
    bash \
    curl \
    xmlstarlet \
    jq

# Copy scripts
COPY run.sh /run.sh
COPY scripts/configure.sh /scripts/configure.sh

# Make executable
RUN chmod +x /run.sh /scripts/configure.sh

CMD ["/run.sh"]
