#!/bin/sh
set -eu

APP_DIR="${APP_DIR:-/app}"
CONFIG_PATH="$APP_DIR/config.php"
DOCKER_CONFIG_PATH="$APP_DIR/config.docker.php"
DATA_DIR="$APP_DIR/data"

mkdir -p "$DATA_DIR"

# Generate a wrapper config that includes the user's config.php and sets
# Docker-specific defaults (cache file path inside the persistent volume).
cat > "$DOCKER_CONFIG_PATH" <<CONFIGEOF
<?php
require '$CONFIG_PATH';
if (!defined('CACHE_FILE')) {
    define('CACHE_FILE', '$DATA_DIR/cache.json');
}
CONFIGEOF

# Check for --run-once flag and remove it from the argument list.
# Remaining arguments (e.g., --quiet, --force) are passed to update.php
# in both one-shot and cron mode.
RUN_ONCE=false
ARGS=""
for arg in "$@"; do
    if [ "$arg" = "--run-once" ]; then
        RUN_ONCE=true
    else
        ARGS="$ARGS $arg"
    fi
done

# One-shot mode: run once and exit.
if [ "$RUN_ONCE" = "true" ]; then
    exec php "$APP_DIR/update.php" -c "$DOCKER_CONFIG_PATH" $ARGS
fi

# Cron mode (default)
CRON_SCHEDULE="${CRON_SCHEDULE:-*/5 * * * *}"

echo "Starting dynamic DNS client for netcup (cron: $CRON_SCHEDULE)"
echo "Press Ctrl+C or stop the container to exit."

# Run once immediately so the user gets feedback on startup.
if ! php "$APP_DIR/update.php" -c "$DOCKER_CONFIG_PATH" $ARGS; then
    echo "Initial run failed. Exiting."
    exit 1
fi

# Set up crontab. Output is redirected to Docker's stdout/stderr
# so that 'docker logs' shows the script's output.
echo "$CRON_SCHEDULE php $APP_DIR/update.php -c $DOCKER_CONFIG_PATH $ARGS >> /proc/1/fd/1 2>> /proc/1/fd/2" | crontab -

# Start crond in the foreground (PID 1).
exec crond -f -l 2
