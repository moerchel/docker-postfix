# Dockerfile for a Postfix email relay service
FROM alpine:3.24
LABEL org.opencontainers.image.title="docker-postfix" \
      org.opencontainers.image.description="Postfix SMTP TLS relay" \
      org.opencontainers.image.source="https://github.com/moerchel/docker-postfix" \
      org.opencontainers.image.licenses="GPL-3.0"

# Versions are not pinned on purpose: the weekly rebuild should pick up the
# latest security fixes of the Alpine branch.
# hadolint ignore=DL3018
RUN apk upgrade --no-cache && \
    apk add --no-cache bash ca-certificates cyrus-sasl cyrus-sasl-login cyrus-sasl-crammd5 mailx openssl postfix && \
    newaliases

COPY --chmod=755 run.sh /run.sh

EXPOSE 25

HEALTHCHECK --interval=60s --timeout=10s --start-period=15s --retries=3 \
  CMD ["postfix", "status"]

CMD ["/run.sh"]
