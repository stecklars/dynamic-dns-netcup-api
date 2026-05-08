FROM php:8-cli-alpine

RUN apk add --no-cache tini tzdata

COPY update.php functions.php healthcheck.php /app/
COPY docker-entrypoint.sh /app/

RUN chmod +x /app/docker-entrypoint.sh && \
    mkdir -p /app/data

WORKDIR /app

HEALTHCHECK --interval=1m --timeout=10s --start-period=5m --retries=3 CMD ["php", "/app/healthcheck.php"]

ENTRYPOINT ["/sbin/tini", "--", "/app/docker-entrypoint.sh"]
