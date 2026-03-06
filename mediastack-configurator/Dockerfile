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
COPY configure.sh /configure.sh

# Make executable
RUN chmod +x /run.sh /configure.sh

CMD ["/run.sh"]
