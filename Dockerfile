FROM php:8-cli-alpine

COPY update.php functions.php /app/
COPY docker-entrypoint.sh /app/

RUN chmod +x /app/docker-entrypoint.sh && \
    mkdir -p /app/data

WORKDIR /app

ENTRYPOINT ["/app/docker-entrypoint.sh"]
