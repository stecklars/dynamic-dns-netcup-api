FROM php:8-cli-alpine

RUN apk add --no-cache tini

COPY update.php functions.php /app/
COPY docker-entrypoint.sh /app/

RUN chmod +x /app/docker-entrypoint.sh && \
    mkdir -p /app/data

WORKDIR /app

ENTRYPOINT ["/sbin/tini", "--", "/app/docker-entrypoint.sh"]
