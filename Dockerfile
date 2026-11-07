# Dockerfile for a Postfix email relay service
FROM alpine:3.23
LABEL org.opencontainers.image.title="docker-postfix" \
      org.opencontainers.image.description="Postfix SMTP TLS relay" \
      org.opencontainers.image.source="https://github.com/moerchel/docker-postfix" \
      org.opencontainers.image.licenses="GPL-3.0"

RUN apk upgrade --no-cache && \
    apk add --no-cache bash ca-certificates cyrus-sasl cyrus-sasl-login cyrus-sasl-crammd5 mailx postfix && \
    newaliases

COPY --chmod=755 run.sh /run.sh

EXPOSE 25

HEALTHCHECK --interval=60s --timeout=10s --start-period=15s --retries=3 \
  CMD postfix status || exit 1

CMD ["/run.sh"]
