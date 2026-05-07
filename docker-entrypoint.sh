#!/bin/sh
set -eu

APP_DIR="${APP_DIR:-/app}"
CONFIG_PATH="$APP_DIR/config.php"
DOCKER_CONFIG_PATH="$APP_DIR/config.docker.php"
DATA_DIR="$APP_DIR/data"
HEALTHCHECK_PATH="$APP_DIR/healthcheck.php"

mkdir -p "$DATA_DIR"

# Escape a string value for safe inclusion in a PHP single-quoted string.
# In PHP single-quoted strings, only \\ and \' are special, so we escape
# backslashes first and then single quotes.
escape_php_single() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e "s/'/\\\\'/g"
}

# Convert an env var value to a PHP boolean literal ("true" or "false").
# Accepts true/false/1/0/yes/no/on/off, case-insensitive. Returns 1 if
# the value is unrecognised so the caller can produce a contextual error.
# LC_ALL=C pins tr to ASCII so non-default locales (e.g. tr_TR) don't
# mis-fold "I" / "i".
env_to_php_bool() {
    case "$(printf '%s' "$1" | LC_ALL=C tr 'A-Z' 'a-z')" in
        true|1|yes|on)
            echo "true"
            ;;
        false|0|no|off)
            echo "false"
            ;;
        *)
            return 1
            ;;
    esac
}

# Validate a non-negative decimal integer. POSIX case glob rejects empty
# input, leading zeros (so values aren't silently parsed as PHP octal),
# and any character that isn't a digit — including newlines, which would
# otherwise let an attacker inject PHP into the unquoted emission below.
validate_uint() {
    case "$1" in
        '' | 0?* | *[!0-9]*)
            return 1
            ;;
    esac
    return 0
}

# Single-quote a value for safe inclusion in a /bin/sh command line.
# Inner single quotes are replaced with '\'' so the result, when re-parsed
# by sh, reproduces the input byte-for-byte.
shell_quote() {
    case "$1" in
        *\'*)
            printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
            ;;
        *)
            printf "'%s'" "$1"
            ;;
    esac
}

# Generate $CONFIG_PATH from environment variables. Required: CUSTOMERNR,
# APIKEY, APIPASSWORD, DOMAINLIST. Optional: USE_IPV4, USE_IPV6, CHANGE_TTL
# (booleans), IPV4_ADDRESS_URL[_FALLBACK], IPV6_ADDRESS_URL[_FALLBACK],
# RETRY_SLEEP, JITTER_MAX.
generate_config_from_env() {
    missing=""
    [ -n "${CUSTOMERNR:-}" ] || missing="$missing CUSTOMERNR"
    [ -n "${APIKEY:-}" ] || missing="$missing APIKEY"
    [ -n "${APIPASSWORD:-}" ] || missing="$missing APIPASSWORD"
    [ -n "${DOMAINLIST:-}" ] || missing="$missing DOMAINLIST"
    if [ -n "$missing" ]; then
        echo "Missing required environment variable(s):$missing" >&2
        echo "Either mount a config.php at $CONFIG_PATH or provide CUSTOMERNR, APIKEY, APIPASSWORD, and DOMAINLIST as environment variables." >&2
        exit 1
    fi

    # Error messages don't echo the offending value: env vars sometimes
    # hold credentials that get pasted into the wrong slot, and we don't
    # want them landing in `docker logs`.
    if ! use_ipv4_php=$(env_to_php_bool "${USE_IPV4:-true}"); then
        echo "Invalid USE_IPV4 value. Expected true/false/1/0/yes/no/on/off." >&2
        exit 1
    fi
    if ! use_ipv6_php=$(env_to_php_bool "${USE_IPV6:-false}"); then
        echo "Invalid USE_IPV6 value. Expected true/false/1/0/yes/no/on/off." >&2
        exit 1
    fi
    if ! change_ttl_php=$(env_to_php_bool "${CHANGE_TTL:-true}"); then
        echo "Invalid CHANGE_TTL value. Expected true/false/1/0/yes/no/on/off." >&2
        exit 1
    fi

    if [ -n "${RETRY_SLEEP:-}" ] && ! validate_uint "$RETRY_SLEEP"; then
        echo "Invalid RETRY_SLEEP value. Expected a non-negative decimal integer (no leading zeros)." >&2
        exit 1
    fi
    if [ -n "${JITTER_MAX:-}" ] && ! validate_uint "$JITTER_MAX"; then
        echo "Invalid JITTER_MAX value. Expected a non-negative decimal integer (no leading zeros)." >&2
        exit 1
    fi

    {
        echo "<?php"
        echo "// Generated from environment variables by docker-entrypoint.sh"
        printf "define('CUSTOMERNR', '%s');\n" "$(escape_php_single "$CUSTOMERNR")"
        printf "define('APIKEY', '%s');\n" "$(escape_php_single "$APIKEY")"
        printf "define('APIPASSWORD', '%s');\n" "$(escape_php_single "$APIPASSWORD")"
        printf "define('DOMAINLIST', '%s');\n" "$(escape_php_single "$DOMAINLIST")"
        echo "define('USE_IPV4', $use_ipv4_php);"
        echo "define('USE_IPV6', $use_ipv6_php);"
        echo "define('CHANGE_TTL', $change_ttl_php);"
        api_url="${APIURL:-https://ccp.netcup.net/run/webservice/servers/endpoint.php?JSON}"
        printf "define('APIURL', '%s');\n" "$(escape_php_single "$api_url")"

        if [ -n "${IPV4_ADDRESS_URL:-}" ]; then
            printf "define('IPV4_ADDRESS_URL', '%s');\n" "$(escape_php_single "$IPV4_ADDRESS_URL")"
        fi
        if [ -n "${IPV4_ADDRESS_URL_FALLBACK:-}" ]; then
            printf "define('IPV4_ADDRESS_URL_FALLBACK', '%s');\n" "$(escape_php_single "$IPV4_ADDRESS_URL_FALLBACK")"
        fi
        if [ -n "${IPV6_ADDRESS_URL:-}" ]; then
            printf "define('IPV6_ADDRESS_URL', '%s');\n" "$(escape_php_single "$IPV6_ADDRESS_URL")"
        fi
        if [ -n "${IPV6_ADDRESS_URL_FALLBACK:-}" ]; then
            printf "define('IPV6_ADDRESS_URL_FALLBACK', '%s');\n" "$(escape_php_single "$IPV6_ADDRESS_URL_FALLBACK")"
        fi
        if [ -n "${RETRY_SLEEP:-}" ]; then
            echo "define('RETRY_SLEEP', $RETRY_SLEEP);"
        fi
        if [ -n "${JITTER_MAX:-}" ]; then
            echo "define('JITTER_MAX', $JITTER_MAX);"
        fi
    } > "$CONFIG_PATH"

    # The generated file holds API credentials in plaintext. Restrict it
    # to the container's primary user even though the default Dockerfile
    # runs as root — anyone adding a USER directive later inherits the
    # secure default.
    chmod 600 "$CONFIG_PATH"

    echo "Loading config from environment variables (wrote $CONFIG_PATH)."
}

# Use a mounted config.php if present, otherwise generate one from env vars.
if [ -f "$CONFIG_PATH" ]; then
    echo "Loading config from $CONFIG_PATH."
else
    generate_config_from_env
fi

# Generate a wrapper config that includes the user's config.php and sets
# Docker-specific defaults (cache file path inside the persistent volume).
# Paths are routed through escape_php_single because $APP_DIR is
# user-controlled (env var) — a bare single quote in there would otherwise
# break out of the surrounding PHP single-quoted string.
ESC_CONFIG_PATH=$(escape_php_single "$CONFIG_PATH")
ESC_DATA_DIR=$(escape_php_single "$DATA_DIR")
cat > "$DOCKER_CONFIG_PATH" <<CONFIGEOF
<?php
require '$ESC_CONFIG_PATH';
if (!defined('CACHE_FILE')) {
    define('CACHE_FILE', '$ESC_DATA_DIR/cache.json');
}
CONFIGEOF
chmod 600 "$DOCKER_CONFIG_PATH"

# Strip --run-once from the positional params using rotate-and-filter so
# the remaining "$@" preserves argument boundaries (a flag value with a
# space or a single quote survives intact).
RUN_ONCE=false
remaining=$#
while [ "$remaining" -gt 0 ]; do
    if [ "$1" = "--run-once" ]; then
        RUN_ONCE=true
    else
        set -- "$@" "$1"
    fi
    shift
    remaining=$((remaining - 1))
done

# One-shot mode: run once and exit. Pass argv through quoted so shell
# word-splitting can't merge or split the user's flags.
if [ "$RUN_ONCE" = "true" ]; then
    exec php "$APP_DIR/update.php" -c "$DOCKER_CONFIG_PATH" "$@"
fi

# Cron mode (default)
CRON_SCHEDULE="${CRON_SCHEDULE:-*/5 * * * *}"

echo "Starting dynamic DNS client for netcup (cron: $CRON_SCHEDULE)"
echo "Press Ctrl+C or stop the container to exit."

# Run once immediately so the user gets feedback on startup. Args go
# through quoted; the entrypoint's own env (incl. TZ) is inherited.
if ! php "$APP_DIR/update.php" -c "$DOCKER_CONFIG_PATH" "$@" || \
   ! DATA_DIR="$DATA_DIR" php "$HEALTHCHECK_PATH" --mark-success; then
    echo "Initial run failed. Exiting."
    exit 1
fi

# Build a single-quoted, sh-safe form of the remaining args for the cron
# command line (which is re-parsed by /bin/sh when crond fires it).
ARGS_BAKED=""
for arg in "$@"; do
    ARGS_BAKED="$ARGS_BAKED $(shell_quote "$arg")"
done

# Busybox crond does not propagate the entrypoint shell's env to scheduled
# jobs, so TZ would silently revert to UTC for log/heartbeat timestamps.
# Forward it inline if the operator set it.
TZ_PREFIX=""
if [ -n "${TZ:-}" ]; then
    TZ_PREFIX="TZ=$(shell_quote "$TZ") "
fi

# Set up crontab. Output is redirected to Docker's stdout/stderr
# so that 'docker logs' shows the script's output.
echo "$CRON_SCHEDULE ${TZ_PREFIX}php $APP_DIR/update.php -c $DOCKER_CONFIG_PATH$ARGS_BAKED >> /proc/1/fd/1 2>> /proc/1/fd/2 && DATA_DIR=$DATA_DIR ${TZ_PREFIX}php $HEALTHCHECK_PATH --mark-success >> /proc/1/fd/1 2>> /proc/1/fd/2" | crontab -

# Start crond in the foreground (PID 1).
exec crond -f -l 2
