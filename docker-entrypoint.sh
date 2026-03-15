#!/bin/sh

# Generate a wrapper config that includes the user's config.php and sets
# Docker-specific defaults (cache file path inside the persistent volume).
cat > /app/config.docker.php <<'CONFIGEOF'
<?php
require '/app/config.php';
if (!defined('CACHE_FILE')) {
    define('CACHE_FILE', '/app/data/cache.json');
}
CONFIGEOF

# If arguments are passed (e.g., --force, --quiet), run in one-shot mode.
if [ $# -gt 0 ] && [ "$1" != "cron" ]; then
    exec php /app/update.php -c /app/config.docker.php "$@"
fi

# Cron mode (default)
CRON_SCHEDULE="${CRON_SCHEDULE:-*/5 * * * *}"

echo "Starting dynamic DNS client for netcup (cron: $CRON_SCHEDULE)"
echo "Press Ctrl+C or stop the container to exit."

# Run once immediately so the user gets feedback on startup.
php /app/update.php -c /app/config.docker.php

# Set up crontab. Output is redirected to Docker's stdout/stderr
# so that 'docker logs' shows the script's output.
echo "$CRON_SCHEDULE php /app/update.php -c /app/config.docker.php >> /proc/1/fd/1 2>> /proc/1/fd/2" | crontab -

# Start crond in the foreground (PID 1).
exec crond -f -l 2
