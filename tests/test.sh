#!/bin/bash
#
# Test script for dynamic-dns-netcup-api
#
# Tests cover:
#   1.  PHP syntax validation
#   2.  CLI option handling (--version, --help, -v, -h, -4, -6, -c)
#   3.  Invalid IP arguments via CLI
#   4.  Config file loading errors
#   5.  IPv4 address validation (isIPV4Valid)
#   6.  IPv6 address validation (isIPV6Valid)
#   7.  DOMAINLIST parsing (getDomains) — modern and legacy formats
#   8.  Full update flow — happy path (IP unchanged)
#   9.  Full update flow — IP changed (triggers DNS update)
#   10. Full update flow — DNS record creation (no existing record)
#   11. Full update flow — duplicate A records (error)
#   12. Full update flow — TTL change (CHANGE_TTL=true)
#   13. Full update flow — API session expiry & re-login (4001 workaround)
#   13a. Full update flow — refreshed API session reused for later requests
#   14. Full update flow — multiple domains in one run
#   15. Full update flow — wildcard (*) and root (@) subdomains
#   16. Full update flow — manually provided IPv4
#   17. Full update flow — IPv4 + IPv6 combined
#   18. Full update flow — quiet mode
#   19. Full update flow — API login failure
#   19a. Full update flow — invalid JSON from API fails cleanly
#   19b. Full update flow — malformed JSON payload fails cleanly
#   20. Full update flow — garbage IP from primary, fallback succeeds
#   21. Full update flow — manually provided IPv6
#   22. Full update flow — IPv6 changed (AAAA update)
#   23. Full update flow — AAAA record creation
#   24. Full update flow — duplicate AAAA records (error)
#   25. Full update flow — both IPv4 and IPv6 disabled (error)
#   26. Full update flow — both IPv4 IP services fail (error)
#   27. Full update flow — both IPv6 IP services fail (error)
#   28. Full update flow — quiet mode: errors still shown
#   29. Full update flow — TTL update failure (non-fatal, continues)
#   30. Full update flow — infoDnsZone failure (error)
#   31. Full update flow — infoDnsRecords failure (error)
#   32. Full update flow — updateDnsRecords failure (error)
#   33. Full update flow — logout failure (error)
#   34. Full update flow — AAAA updateDnsRecords failure (error)
#   35. Full update flow — quiet mode suppresses [WARNING]
#   36. Full update flow — TTL already optimal (CHANGE_TTL=true, no-op)
#   37. Full update flow — jitter disabled warning
#   38. Full update flow — jitter enabled (logs delay)
#   39. Full update flow — cache hit (skips API)
#   40. Full update flow — cache miss (proceeds with update)
#   41. Full update flow — --force bypasses cache
#   42. Full update flow — cache file written after success
#   43. Full update flow — cache with IPv4+IPv6
#   44. Full update flow — no cache file (first run)
#   45. Full update flow — config change invalidates cache
#   45a. Full update flow — env-mode entrypoint generates config and runs update.php end-to-end
#   46. Docker entrypoint — startup failure exits before scheduling cron
#   47. Docker entrypoint — startup success records heartbeat, schedules cron, and starts crond
#   48. Docker healthcheck — mark-success writes heartbeat file
#   49. Docker healthcheck — healthy before the next scheduled run is due
#   50. Docker healthcheck — unhealthy when a scheduled run is overdue
#   51. Docker healthcheck — weekday-only schedules stay healthy over the weekend
#   52. Docker image — Dockerfile defines a HEALTHCHECK command
#   53. Docker entrypoint — env-mode generates config.php from environment variables
#   54. Docker entrypoint — env-mode missing required variables fails fast
#   55. Docker entrypoint — env-mode accepts boolean variants (true/yes/1/on, false/no/0/off)
#   56. Docker entrypoint — env-mode rejects invalid boolean and non-numeric values
#   57. Docker entrypoint — env-mode escapes special characters in string values
#   58. Docker entrypoint — env-mode applies optional URL/numeric overrides
#   59. Docker entrypoint — env-mode omits unset optional values from generated config
#   60. Docker entrypoint — env-mode mounted config.php takes precedence over env vars
#   61. Docker entrypoint — env-mode generated config supports legacy/case-insensitive booleans
#   62. Docker entrypoint — wrapper config escapes APP_DIR (no PHP injection via path)
#   63. Docker entrypoint — env-mode validation errors do not leak the offending value
#   64. Docker compose — shipped docker-compose.yml (and env-var alternative) parses cleanly
#   65. Docker entrypoint — TZ env var is forwarded into the cron command
#   66. Docker entrypoint — args with embedded spaces survive the cron command
#   67. Docker entrypoint — env-mode generated config files are mode 0600
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PASS=0
FAIL=0
SKIP=0
MOCK_PID=""
MOCK_PORT=18741
MOCK_SERVER="$SCRIPT_DIR/test_mock_server.py"
TEST_CONFIG="$SCRIPT_DIR/config.test.php"

# Config file used by run_php / run_php_custom helpers for unit-testing
# individual functions. functions.php always loads a config via the -c CLI
# flag; this provides all required constants with dummy values.
UNIT_CONFIG="$SCRIPT_DIR/config.unit.php"
cat > "$UNIT_CONFIG" <<'PHPEOF'
<?php
define('CUSTOMERNR', '12345');
define('APIKEY', 'test');
define('APIPASSWORD', 'test');
define('APIURL', 'http://localhost');
define('USE_IPV4', true);
define('USE_IPV6', false);
define('CHANGE_TTL', false);
define('DOMAINLIST', 'example.com: @');
define('IPV4_ADDRESS_URL', 'http://localhost');
define('IPV4_ADDRESS_URL_FALLBACK', 'http://localhost');
define('IPV6_ADDRESS_URL', 'http://localhost');
define('IPV6_ADDRESS_URL_FALLBACK', 'http://localhost');
PHPEOF

# ---------------------------------------------------------------------------
# Test helpers
# ---------------------------------------------------------------------------

pass() {
    PASS=$((PASS + 1))
    echo "  PASS: $1"
}

fail() {
    FAIL=$((FAIL + 1))
    echo "  FAIL: $1"
}

skip() {
    SKIP=$((SKIP + 1))
    echo "  SKIP: $1"
}

# Assert that a command exits with the expected exit code.
assert_exit_code() {
    local description="$1"
    local expected="$2"
    shift 2
    "$@" > /dev/null 2>&1
    local actual=$?
    if [ "$actual" -eq "$expected" ]; then
        pass "$description"
    else
        fail "$description (expected exit $expected, got $actual)"
    fi
}

# Assert that a command's combined stdout+stderr contains a string.
# Uses grep -F (fixed string) with -- to handle patterns starting with '-'.
assert_output_contains() {
    local description="$1"
    local expected="$2"
    shift 2
    local output
    output=$("$@" 2>&1)
    if echo "$output" | grep -qF -- "$expected"; then
        pass "$description"
    else
        fail "$description (expected output to contain '$expected')"
    fi
}

# Run a PHP expression with functions.php loaded.
# Reads from stdin and passes -c <config> -q via CLI args so that getopt()
# inside functions.php picks them up. The -q flag enables quiet mode to
# suppress log output that would pollute test results.
run_php() {
    php -- -c "$UNIT_CONFIG" -q <<INNEREOF 2>/dev/null
<?php
require '$PROJECT_DIR/functions.php';
$1
INNEREOF
}

# Run a PHP expression with a custom config file.
# Writes a temporary config, runs the code, then cleans up.
# $1: PHP code for the config file body (define() statements)
# $2: PHP code to execute after loading functions.php
run_php_custom() {
    local config_code="$1"
    local test_code="$2"
    local tmp_config="${UNIT_CONFIG}.custom.php"
    cat > "$tmp_config" <<CFGEOF
<?php
$config_code
CFGEOF
    php -- -c "$tmp_config" -q <<INNEREOF 2>/dev/null
<?php
require '$PROJECT_DIR/functions.php';
$test_code
INNEREOF
    rm -f "$tmp_config"
}

# ---------------------------------------------------------------------------
# Mock server management
# ---------------------------------------------------------------------------

# Start the Python mock HTTP server in the background.
# It simulates both the IP-lookup services and the netcup CCP DNS API.
start_mock_server() {
    python3 "$MOCK_SERVER" "$MOCK_PORT" &
    MOCK_PID=$!

    # Wait for the server to be ready (up to 3 seconds)
    for i in $(seq 1 30); do
        if curl -s "http://localhost:$MOCK_PORT/health" > /dev/null 2>&1; then
            return 0
        fi
        sleep 0.1
    done
    echo "ERROR: Mock server failed to start"
    exit 1
}

# Reset mock server state between stateful tests.
reset_mock_server() {
    curl -s "http://localhost:$MOCK_PORT/reset" > /dev/null 2>&1
}

# Stop the mock server and clean up temp files.
cleanup() {
    if [ -n "$MOCK_PID" ] && kill -0 "$MOCK_PID" 2>/dev/null; then
        kill "$MOCK_PID" 2>/dev/null
        wait "$MOCK_PID" 2>/dev/null || true
    fi
    rm -f "$TEST_CONFIG" "$UNIT_CONFIG" "${UNIT_CONFIG}".*.php "$SCRIPT_DIR/cache.test.json"
}
trap cleanup EXIT

# Write a test config.php pointing at the mock server.
# Accepts an API path variant (default: /api) and optional override defines.
# Overrides replace the default values for USE_IPV4, USE_IPV6, CHANGE_TTL,
# and DOMAINLIST. Pass them as a single string of PHP define() statements.
# Usage: write_mock_config [api_path] [override_defines]
write_mock_config() {
    local api_path="${1:-/api}"
    local overrides="${2:-}"

    # Defaults that can be overridden
    local use_ipv4="true"
    local use_ipv6="false"
    local change_ttl="false"
    local domainlist="example.com: @"

    # Parse overrides to extract values (simple grep approach)
    if echo "$overrides" | grep -q "USE_IPV4"; then
        use_ipv4=$(echo "$overrides" | grep -oP "define\('USE_IPV4',\s*\K[^)]+")
    fi
    if echo "$overrides" | grep -q "USE_IPV6"; then
        use_ipv6=$(echo "$overrides" | grep -oP "define\('USE_IPV6',\s*\K[^)]+")
    fi
    if echo "$overrides" | grep -q "CHANGE_TTL"; then
        change_ttl=$(echo "$overrides" | grep -oP "define\('CHANGE_TTL',\s*\K[^)]+")
    fi
    if echo "$overrides" | grep -q "DOMAINLIST"; then
        domainlist=$(echo "$overrides" | grep -oP "define\('DOMAINLIST',\s*'\K[^']+")
    fi

    cat > "$TEST_CONFIG" <<PHPEOF
<?php
define('CUSTOMERNR', '12345');
define('APIKEY', 'testkey');
define('APIPASSWORD', 'testpass');
define('APIURL', 'http://localhost:$MOCK_PORT$api_path');
define('USE_IPV4', $use_ipv4);
define('USE_IPV6', $use_ipv6);
define('CHANGE_TTL', $change_ttl);
define('DOMAINLIST', '$domainlist');
define('IPV4_ADDRESS_URL', 'http://localhost:$MOCK_PORT/ipv4');
define('IPV4_ADDRESS_URL_FALLBACK', 'http://localhost:$MOCK_PORT/ipv4');
define('IPV6_ADDRESS_URL', 'http://localhost:$MOCK_PORT/ipv6');
define('IPV6_ADDRESS_URL_FALLBACK', 'http://localhost:$MOCK_PORT/ipv6');
define('RETRY_SLEEP', 0);
define('JITTER_MAX', 0);
define('CACHE_FILE', '/dev/null');
PHPEOF
}

# Run update.php with the test config and capture output + exit code.
# Sets $output and $exit_code for subsequent assertions.
run_update() {
    local extra_args="${*:-}"
    output=$(php "$PROJECT_DIR/update.php" -c "$TEST_CONFIG" $extra_args 2>&1) && exit_code=$? || exit_code=$?
}

# Assert that $output (from run_update) contains a string.
assert_output() {
    local description="$1"
    local expected="$2"
    if echo "$output" | grep -qF -- "$expected"; then
        pass "$description"
    else
        fail "$description (expected output to contain '$expected')"
    fi
}

# Assert that $output does NOT contain a string.
assert_output_missing() {
    local description="$1"
    local unexpected="$2"
    if echo "$output" | grep -qF -- "$unexpected"; then
        fail "$description (output should not contain '$unexpected')"
    else
        pass "$description"
    fi
}

# Assert that $output contains a string an exact number of times.
assert_output_count() {
    local description="$1"
    local expected="$2"
    local count_expected="$3"
    local count_actual
    count_actual=$(printf '%s' "$output" | grep -oF -- "$expected" | wc -l | tr -d '[:space:]')
    if [ "$count_actual" -eq "$count_expected" ]; then
        pass "$description"
    else
        fail "$description (expected $count_expected occurrence(s) of '$expected', got $count_actual)"
    fi
}

# Assert that $exit_code (from run_update) equals expected.
assert_run_exit() {
    local description="$1"
    local expected="$2"
    if [ "$exit_code" -eq "$expected" ]; then
        pass "$description"
    else
        fail "$description (expected exit $expected, got $exit_code)"
    fi
}

# Run the Docker healthcheck script and capture output + exit code.
# Reads env vars from the current shell scope:
#   HEALTHCHECK_APP_DIR
#   HEALTHCHECK_DATA_DIR
#   HEALTHCHECK_FILE
#   HEALTHCHECK_SCHEDULE
#   HEALTHCHECK_NOW
#   HEALTHCHECK_GRACE
#   HEALTHCHECK_TZ
run_healthcheck() {
    local extra_args="${*:-}"
    healthcheck_output=$(
        env \
            APP_DIR="$HEALTHCHECK_APP_DIR" \
            DATA_DIR="$HEALTHCHECK_DATA_DIR" \
            HEALTHCHECK_FILE="$HEALTHCHECK_FILE" \
            CRON_SCHEDULE="$HEALTHCHECK_SCHEDULE" \
            HEALTHCHECK_NOW="$HEALTHCHECK_NOW" \
            HEALTHCHECK_GRACE_SECONDS="$HEALTHCHECK_GRACE" \
            TZ="$HEALTHCHECK_TZ" \
            php "$PROJECT_DIR/healthcheck.php" $extra_args 2>&1
    ) && healthcheck_exit_code=$? || healthcheck_exit_code=$?
}

assert_healthcheck_exit() {
    local description="$1"
    local expected="$2"
    if [ "$healthcheck_exit_code" -eq "$expected" ]; then
        pass "$description"
    else
        fail "$description (expected exit $expected, got $healthcheck_exit_code)"
    fi
}

assert_healthcheck_output() {
    local description="$1"
    local expected="$2"
    if echo "$healthcheck_output" | grep -qF -- "$expected"; then
        pass "$description"
    else
        fail "$description (expected output to contain '$expected')"
    fi
}



# ===========================================================================
# 1. SYNTAX CHECKS
# ===========================================================================

echo ""
echo "=== 1. Syntax checks ==="

# Verify both PHP files parse without syntax errors.
assert_exit_code "functions.php has valid syntax" 0 php -l "$PROJECT_DIR/functions.php"
assert_exit_code "update.php has valid syntax" 0 php -l "$PROJECT_DIR/update.php"

# ===========================================================================
# 2. CLI OPTIONS
# ===========================================================================

echo ""
echo "=== 2. CLI options ==="

# --version / -v should print the version string and exit cleanly.
assert_exit_code "--version exits 0" 0 php "$PROJECT_DIR/update.php" --version
assert_output_contains "--version shows version number" "6.2" php "$PROJECT_DIR/update.php" --version
assert_exit_code "-v exits 0" 0 php "$PROJECT_DIR/update.php" -v

# --help / -h should print usage information and exit cleanly.
assert_exit_code "--help exits 0" 0 php "$PROJECT_DIR/update.php" --help
assert_output_contains "--help shows options table" "--quiet" php "$PROJECT_DIR/update.php" --help
assert_output_contains "--help shows force option" "--force" php "$PROJECT_DIR/update.php" --help
assert_exit_code "-h exits 0" 0 php "$PROJECT_DIR/update.php" -h

# ===========================================================================
# 3. INVALID IP ARGUMENTS
# ===========================================================================

echo ""
echo "=== 3. Invalid IP arguments ==="

# Providing an invalid IPv4 or IPv6 address via CLI should fail immediately
# with exit code 1, before any API calls are made.
assert_exit_code "-4 with garbage text exits 1" 1 php "$PROJECT_DIR/update.php" -4 "not-an-ip"
assert_exit_code "-4 with out-of-range octets exits 1" 1 php "$PROJECT_DIR/update.php" -4 "999.999.999.999"
assert_exit_code "-6 with garbage text exits 1" 1 php "$PROJECT_DIR/update.php" -6 "not-an-ipv6"
assert_output_contains "-4 invalid shows error message" "is invalid. Exiting" php "$PROJECT_DIR/update.php" -4 "bad"
assert_output_contains "-6 invalid shows error message" "is invalid. Exiting" php "$PROJECT_DIR/update.php" -6 "bad"

# ===========================================================================
# 4. CONFIG LOADING
# ===========================================================================

echo ""
echo "=== 4. Config loading ==="

# A non-existent config path should fail with exit 1 and a helpful error.
assert_exit_code "missing config file exits 1" 1 php "$PROJECT_DIR/update.php" -c "/nonexistent/config.php"
assert_output_contains "missing config shows error" "Could not open config.php" \
    php "$PROJECT_DIR/update.php" -c "/nonexistent/config.php"

# ===========================================================================
# 5. IPv4 VALIDATION (isIPV4Valid)
# ===========================================================================

echo ""
echo "=== 5. IPv4 validation ==="

# Valid IPv4 addresses
run_php 'echo isIPV4Valid("1.2.3.4") ? "OK" : "FAIL";' | grep -q "OK" \
    && pass "1.2.3.4 is valid" || fail "1.2.3.4 is valid"
run_php 'echo isIPV4Valid("255.255.255.255") ? "OK" : "FAIL";' | grep -q "OK" \
    && pass "255.255.255.255 is valid" || fail "255.255.255.255 is valid"
run_php 'echo isIPV4Valid("0.0.0.0") ? "OK" : "FAIL";' | grep -q "OK" \
    && pass "0.0.0.0 is valid" || fail "0.0.0.0 is valid"
run_php 'echo isIPV4Valid("192.168.1.1") ? "OK" : "FAIL";' | grep -q "OK" \
    && pass "192.168.1.1 is valid" || fail "192.168.1.1 is valid"
run_php 'echo isIPV4Valid("10.0.0.1") ? "OK" : "FAIL";' | grep -q "OK" \
    && pass "10.0.0.1 is valid" || fail "10.0.0.1 is valid"

# Invalid IPv4 addresses
run_php 'echo isIPV4Valid("999.999.999.999") ? "FAIL" : "OK";' | grep -q "OK" \
    && pass "999.999.999.999 is invalid" || fail "999.999.999.999 is invalid"
run_php 'echo isIPV4Valid("1.2.3") ? "FAIL" : "OK";' | grep -q "OK" \
    && pass "1.2.3 (incomplete) is invalid" || fail "1.2.3 (incomplete) is invalid"
run_php 'echo isIPV4Valid("") ? "FAIL" : "OK";' | grep -q "OK" \
    && pass "empty string is invalid IPv4" || fail "empty string is invalid IPv4"
run_php 'echo isIPV4Valid("abc") ? "FAIL" : "OK";' | grep -q "OK" \
    && pass "abc is invalid IPv4" || fail "abc is invalid IPv4"
run_php 'echo isIPV4Valid("::1") ? "FAIL" : "OK";' | grep -q "OK" \
    && pass "::1 (IPv6) is not valid IPv4" || fail "::1 (IPv6) is not valid IPv4"
run_php 'echo isIPV4Valid("1.2.3.4.5") ? "FAIL" : "OK";' | grep -q "OK" \
    && pass "1.2.3.4.5 (too many octets) is invalid" || fail "1.2.3.4.5 (too many octets) is invalid"
run_php 'echo isIPV4Valid(" 1.2.3.4") ? "FAIL" : "OK";' | grep -q "OK" \
    && pass "leading space is invalid IPv4" || fail "leading space is invalid IPv4"

# ===========================================================================
# 6. IPv6 VALIDATION (isIPV6Valid)
# ===========================================================================

echo ""
echo "=== 6. IPv6 validation ==="

# Valid IPv6 addresses
run_php 'echo isIPV6Valid("::1") ? "OK" : "FAIL";' | grep -q "OK" \
    && pass "::1 is valid" || fail "::1 is valid"
run_php 'echo isIPV6Valid("2001:db8::1") ? "OK" : "FAIL";' | grep -q "OK" \
    && pass "2001:db8::1 is valid" || fail "2001:db8::1 is valid"
run_php 'echo isIPV6Valid("fe80::1") ? "OK" : "FAIL";' | grep -q "OK" \
    && pass "fe80::1 is valid" || fail "fe80::1 is valid"
run_php 'echo isIPV6Valid("::ffff:192.0.2.1") ? "OK" : "FAIL";' | grep -q "OK" \
    && pass "::ffff:192.0.2.1 (mapped IPv4) is valid IPv6" || fail "::ffff:192.0.2.1 (mapped IPv4) is valid IPv6"

# Invalid IPv6 addresses
run_php 'echo isIPV6Valid("1.2.3.4") ? "FAIL" : "OK";' | grep -q "OK" \
    && pass "1.2.3.4 (IPv4) is not valid IPv6" || fail "1.2.3.4 (IPv4) is not valid IPv6"
run_php 'echo isIPV6Valid("") ? "FAIL" : "OK";' | grep -q "OK" \
    && pass "empty string is invalid IPv6" || fail "empty string is invalid IPv6"
run_php 'echo isIPV6Valid("gggg::1") ? "FAIL" : "OK";' | grep -q "OK" \
    && pass "gggg::1 (invalid hex) is invalid" || fail "gggg::1 (invalid hex) is invalid"

# ===========================================================================
# 7. DOMAINLIST PARSING (getDomains)
# ===========================================================================

echo ""
echo "=== 7. getDomains() ==="

# --- Modern DOMAINLIST format ---

# Simple single-domain, single-subdomain config
run_php '
    $result = getDomains();
    if ($result === ["example.com" => ["@"]]) { echo "OK"; } else { echo "FAIL"; var_dump($result); }
' | grep -q "OK" && pass "parses simple DOMAINLIST" || fail "parses simple DOMAINLIST"

# Multiple domains, each with multiple subdomains
run_php_custom \
    "define('CUSTOMERNR','1'); define('APIKEY','k'); define('APIPASSWORD','p');
     define('APIURL','http://x'); define('USE_IPV4',true); define('USE_IPV6',false);
     define('CHANGE_TTL',false);
     define('DOMAINLIST','first.com: @, www; second.com: mail, *');
     define('IPV4_ADDRESS_URL','http://x'); define('IPV4_ADDRESS_URL_FALLBACK','http://x');
     define('IPV6_ADDRESS_URL','http://x'); define('IPV6_ADDRESS_URL_FALLBACK','http://x');" \
    '
    $result = getDomains();
    $expected = ["first.com" => ["@", "www"], "second.com" => ["mail", "*"]];
    if ($result === $expected) { echo "OK"; } else { echo "FAIL"; var_dump($result); }
' | grep -q "OK" && pass "parses multi-domain DOMAINLIST" || fail "parses multi-domain DOMAINLIST"

# Extra whitespace should be stripped
run_php_custom \
    "define('CUSTOMERNR','1'); define('APIKEY','k'); define('APIPASSWORD','p');
     define('APIURL','http://x'); define('USE_IPV4',true); define('USE_IPV6',false);
     define('CHANGE_TTL',false);
     define('DOMAINLIST','  example.com :  @ ,  www  ');
     define('IPV4_ADDRESS_URL','http://x'); define('IPV4_ADDRESS_URL_FALLBACK','http://x');
     define('IPV6_ADDRESS_URL','http://x'); define('IPV6_ADDRESS_URL_FALLBACK','http://x');" \
    '
    $result = getDomains();
    $expected = ["example.com" => ["@", "www"]];
    if ($result === $expected) { echo "OK"; } else { echo "FAIL"; var_dump($result); }
' | grep -q "OK" && pass "handles whitespace in DOMAINLIST" || fail "handles whitespace in DOMAINLIST"

# Trailing semicolons should be ignored rather than creating an empty domain
run_php_custom \
    "define('CUSTOMERNR','1'); define('APIKEY','k'); define('APIPASSWORD','p');
     define('APIURL','http://x'); define('USE_IPV4',true); define('USE_IPV6',false);
     define('CHANGE_TTL',false);
     define('DOMAINLIST','example.com: @;');
     define('IPV4_ADDRESS_URL','http://x'); define('IPV4_ADDRESS_URL_FALLBACK','http://x');
     define('IPV6_ADDRESS_URL','http://x'); define('IPV6_ADDRESS_URL_FALLBACK','http://x');" \
    '
    $result = getDomains();
    $expected = ["example.com" => ["@"]];
    if ($result === $expected) { echo "OK"; } else { echo "FAIL"; var_dump($result); }
' | grep -q "OK" && pass "ignores trailing semicolon in DOMAINLIST" || fail "ignores trailing semicolon in DOMAINLIST"

# Duplicate domain entries should be merged instead of overwritten
run_php_custom \
    "define('CUSTOMERNR','1'); define('APIKEY','k'); define('APIPASSWORD','p');
     define('APIURL','http://x'); define('USE_IPV4',true); define('USE_IPV6',false);
     define('CHANGE_TTL',false);
     define('DOMAINLIST','example.com: @; example.com: www, @');
     define('IPV4_ADDRESS_URL','http://x'); define('IPV4_ADDRESS_URL_FALLBACK','http://x');
     define('IPV6_ADDRESS_URL','http://x'); define('IPV6_ADDRESS_URL_FALLBACK','http://x');" \
    '
    $result = getDomains();
    $expected = ["example.com" => ["@", "www"]];
    if ($result === $expected) { echo "OK"; } else { echo "FAIL"; var_dump($result); }
' | grep -q "OK" && pass "merges duplicate domain entries in DOMAINLIST" || fail "merges duplicate domain entries in DOMAINLIST"

# Missing ':' separator should exit with a config error.
local_config="${UNIT_CONFIG}.domainlist1.php"
cat > "$local_config" <<'DOMEOF'
<?php
define('CUSTOMERNR','1'); define('APIKEY','k'); define('APIPASSWORD','p');
define('APIURL','http://x'); define('USE_IPV4',true); define('USE_IPV6',false);
define('CHANGE_TTL',false);
define('DOMAINLIST','example.com');
define('IPV4_ADDRESS_URL','http://x'); define('IPV4_ADDRESS_URL_FALLBACK','http://x');
define('IPV6_ADDRESS_URL','http://x'); define('IPV6_ADDRESS_URL_FALLBACK','http://x');
DOMEOF
php -- -c "$local_config" -q <<DOMAINPHP > /dev/null 2>&1
<?php
require '$PROJECT_DIR/functions.php';
getDomains();
echo "SHOULD_NOT_REACH";
DOMAINPHP
if [ $? -ne 0 ]; then
    pass "DOMAINLIST entry without separator exits with error"
else
    fail "DOMAINLIST entry without separator exits with error"
fi

# Empty host list should exit with a config error.
local_config="${UNIT_CONFIG}.domainlist2.php"
cat > "$local_config" <<'DOMEOF'
<?php
define('CUSTOMERNR','1'); define('APIKEY','k'); define('APIPASSWORD','p');
define('APIURL','http://x'); define('USE_IPV4',true); define('USE_IPV6',false);
define('CHANGE_TTL',false);
define('DOMAINLIST','example.com:');
define('IPV4_ADDRESS_URL','http://x'); define('IPV4_ADDRESS_URL_FALLBACK','http://x');
define('IPV6_ADDRESS_URL','http://x'); define('IPV6_ADDRESS_URL_FALLBACK','http://x');
DOMEOF
php -- -c "$local_config" -q <<DOMAINPHP > /dev/null 2>&1
<?php
require '$PROJECT_DIR/functions.php';
getDomains();
echo "SHOULD_NOT_REACH";
DOMAINPHP
if [ $? -ne 0 ]; then
    pass "DOMAINLIST entry without hosts exits with error"
else
    fail "DOMAINLIST entry without hosts exits with error"
fi

# --- Legacy format (DOMAIN + HOST, no DOMAINLIST) ---

# Legacy format should still work and return [DOMAIN => [HOST]]
run_php_custom \
    "define('CUSTOMERNR','1'); define('APIKEY','k'); define('APIPASSWORD','p');
     define('APIURL','http://x'); define('USE_IPV4',true); define('USE_IPV6',false);
     define('CHANGE_TTL',false);
     define('DOMAIN','legacy.com'); define('HOST','sub');
     define('IPV4_ADDRESS_URL','http://x'); define('IPV4_ADDRESS_URL_FALLBACK','http://x');
     define('IPV6_ADDRESS_URL','http://x'); define('IPV6_ADDRESS_URL_FALLBACK','http://x');" \
    '
    $result = getDomains();
    if ($result === ["legacy.com" => ["sub"]]) { echo "OK"; } else { echo "FAIL"; var_dump($result); }
' | grep -q "OK" && pass "legacy DOMAIN+HOST format works" || fail "legacy DOMAIN+HOST format works"

# Legacy format with wildcard host
run_php_custom \
    "define('CUSTOMERNR','1'); define('APIKEY','k'); define('APIPASSWORD','p');
     define('APIURL','http://x'); define('USE_IPV4',true); define('USE_IPV6',false);
     define('CHANGE_TTL',false);
     define('DOMAIN','legacy.com'); define('HOST','*');
     define('IPV4_ADDRESS_URL','http://x'); define('IPV4_ADDRESS_URL_FALLBACK','http://x');
     define('IPV6_ADDRESS_URL','http://x'); define('IPV6_ADDRESS_URL_FALLBACK','http://x');" \
    '
    $result = getDomains();
    if ($result === ["legacy.com" => ["*"]]) { echo "OK"; } else { echo "FAIL"; var_dump($result); }
' | grep -q "OK" && pass "legacy format with wildcard host" || fail "legacy format with wildcard host"

# No DOMAINLIST and no DOMAIN → should exit 1.
# run_php_custom runs PHP and we check if it exits non-zero (exit(1) from
# getDomains). We need to capture the exit code carefully since the function
# runs in a subshell via heredoc.
local_config="${UNIT_CONFIG}.legacy1.php"
cat > "$local_config" <<'LEGEOF'
<?php
define('CUSTOMERNR','1'); define('APIKEY','k'); define('APIPASSWORD','p');
define('APIURL','http://x'); define('USE_IPV4',true); define('USE_IPV6',false);
define('CHANGE_TTL',false);
define('IPV4_ADDRESS_URL','http://x'); define('IPV4_ADDRESS_URL_FALLBACK','http://x');
define('IPV6_ADDRESS_URL','http://x'); define('IPV6_ADDRESS_URL_FALLBACK','http://x');
LEGEOF
php -- -c "$local_config" -q <<LEGPHP > /dev/null 2>&1
<?php
require '$PROJECT_DIR/functions.php';
getDomains();
echo "SHOULD_NOT_REACH";
LEGPHP
if [ $? -ne 0 ]; then
    pass "no DOMAINLIST and no DOMAIN exits with error"
else
    fail "no DOMAINLIST and no DOMAIN exits with error"
fi

# DOMAIN set but no HOST → should exit 1
local_config="${UNIT_CONFIG}.legacy2.php"
cat > "$local_config" <<'LEGEOF'
<?php
define('CUSTOMERNR','1'); define('APIKEY','k'); define('APIPASSWORD','p');
define('APIURL','http://x'); define('USE_IPV4',true); define('USE_IPV6',false);
define('CHANGE_TTL',false);
define('DOMAIN','example.com');
define('IPV4_ADDRESS_URL','http://x'); define('IPV4_ADDRESS_URL_FALLBACK','http://x');
define('IPV6_ADDRESS_URL','http://x'); define('IPV6_ADDRESS_URL_FALLBACK','http://x');
LEGEOF
php -- -c "$local_config" -q <<LEGPHP > /dev/null 2>&1
<?php
require '$PROJECT_DIR/functions.php';
getDomains();
echo "SHOULD_NOT_REACH";
LEGPHP
if [ $? -ne 0 ]; then
    pass "DOMAIN without HOST exits with error"
else
    fail "DOMAIN without HOST exits with error"
fi
rm -f "${UNIT_CONFIG}.legacy1.php" "${UNIT_CONFIG}.legacy2.php"

# ===========================================================================
# 8-45. FULL UPDATE FLOW (mock HTTP server)
# ===========================================================================

echo ""
echo "=== 8-45. Full update flow (mock server) ==="

# The full update flow requires the cURL PHP extension and Python 3.
# Skip all integration tests if either is missing.
if ! php -r "exit(in_array('curl', get_loaded_extensions()) ? 0 : 1);" 2>/dev/null; then
    echo "  SKIP: cURL PHP extension not installed — skipping mock server tests"
elif ! command -v python3 &>/dev/null; then
    echo "  SKIP: python3 not found — skipping mock server tests"
else

start_mock_server

# --- 8. Happy path: IP unchanged, no update needed ---
# The mock /ipv4 returns 203.0.113.42, and the DNS record already has that
# IP. The script should log in, check records, find no change, and log out.
echo ""
echo "  --- 8. Happy path (IP unchanged) ---"
write_mock_config /api
run_update
assert_run_exit "exits 0" 0
assert_output "logs in" "Logged in successfully"
assert_output "gets domain info" "Successfully received Domain info"
assert_output "gets DNS records" "Successfully received DNS record data"
assert_output "detects no IPv4 change" "IPv4 address hasn't changed"
assert_output "logs out" "Logged out successfully"

# --- 9. IP changed: triggers DNS record update ---
# The mock /api-ip-changed returns DNS records with IP 1.1.1.1 (stale).
# The script should detect the change and update the record to 203.0.113.42.
echo ""
echo "  --- 9. IP changed (triggers update) ---"
write_mock_config /api-ip-changed
run_update
assert_run_exit "exits 0" 0
assert_output "detects IPv4 change" "IPv4 address has changed"
assert_output "shows old IP" "Before: 1.1.1.1"
assert_output "shows new IP" "Now: 203.0.113.42"
assert_output "updates successfully" "IPv4 address updated successfully"

# --- 10. Record creation: no existing DNS record ---
# The mock /api-no-records returns an empty record set. The script should
# create a new A record for the subdomain.
echo ""
echo "  --- 10. Record creation (no existing record) ---"
write_mock_config /api-no-records
run_update
assert_run_exit "exits 0" 0
assert_output "detects missing A record" "A record for host @ doesn't exist, creating"
assert_output "creates and updates" "IPv4 address updated successfully"

# --- 11. Duplicate A records: error ---
# The mock /api-dup-records returns two A records for hostname '@'.
# The script should exit with an error about multiple records.
echo ""
echo "  --- 11. Duplicate A records (error) ---"
write_mock_config /api-dup-records
run_update
assert_run_exit "exits 1" 1
assert_output "reports multiple records error" "Found multiple A records for the host @"

# --- 12. TTL change: CHANGE_TTL=true with high TTL ---
# The mock /api-high-ttl returns TTL=3600. With CHANGE_TTL=true, the script
# should lower it to 300.
echo ""
echo "  --- 12. TTL change ---"
write_mock_config /api-high-ttl "define('CHANGE_TTL', true)"
run_update
assert_run_exit "exits 0" 0
assert_output "lowers TTL" "Lowered TTL to 300 seconds successfully"

# Also test: TTL warning when CHANGE_TTL is false and TTL > 300
write_mock_config /api-high-ttl
run_update
assert_run_exit "TTL warning run exits 0" 0
assert_output "warns about high TTL" "TTL is higher than 300 seconds"

# --- 13. Session expiry: 4001 workaround ---
# The mock /api-session-expire returns error 4001 on the first non-login
# action, then succeeds after the script re-logs in. This tests the
# workaround for the netcup CCP DNS API bug (GitHub issue #21).
echo ""
echo "  --- 13. Session expiry (4001 re-login) ---"
reset_mock_server
write_mock_config /api-session-expire
run_update
assert_run_exit "exits 0 after re-login" 0
assert_output "detects 4001 error" "session id is not in a valid format"
assert_output "retries after re-login" "Logged in successfully"
assert_output "completes successfully" "Logged out successfully"

# The refreshed session should be reused for later API calls instead of
# triggering another 4001 on the next request.
echo ""
echo "  --- 13b. Session refresh persists across later API calls ---"
reset_mock_server
write_mock_config /api-session-refresh
run_update
assert_run_exit "exits 0 after one session refresh" 0
assert_output_count "performs exactly two login attempts" "Logging into netcup CCP DNS API." 2
assert_output_count "hits the 4001 workaround only once" "Received API error 4001" 1
assert_output "logs out after refreshed session" "Logged out successfully"

# --- 14. Multiple domains in one run ---
# Configure two domains. The script should process both sequentially.
echo ""
echo "  --- 14. Multiple domains ---"
write_mock_config /api "define('DOMAINLIST', 'first.com: @; second.com: www')"
run_update
assert_run_exit "exits 0" 0
assert_output "processes first domain" 'Beginning work on domain "first.com"'
assert_output "processes second domain" 'Beginning work on domain "second.com"'

# --- 15. Wildcard (*) and root (@) subdomains ---
# Configure both @ and * as subdomains. The mock only has a record for @,
# so * should trigger record creation.
echo ""
echo "  --- 15. Wildcard and root subdomains ---"
write_mock_config /api "define('DOMAINLIST', 'example.com: @, *')"
run_update
assert_run_exit "exits 0" 0
assert_output "handles root @ subdomain" 'Updating DNS records for subdomain "@"'
assert_output "handles wildcard * subdomain" 'Updating DNS records for subdomain "*"'
# * has no existing record → should be created
assert_output "creates wildcard record" "A record for host * doesn't exist, creating"

# --- 16. Manually provided IPv4 ---
# Pass -4 with a specific IP. The script should use it instead of fetching.
echo ""
echo "  --- 16. Manually provided IPv4 ---"
write_mock_config /api
run_update -4 "203.0.113.99"
assert_run_exit "exits 0" 0
assert_output "uses manual IPv4" 'Using manually provided IPv4 address "203.0.113.99"'
# The manual IP differs from the record → should trigger update
assert_output "updates with manual IP" "IPv4 address has changed"
assert_output "shows manual IP as new" "Now: 203.0.113.99"

# --- 17. IPv4 + IPv6 combined ---
# Enable both protocols. Both should be checked and processed.
echo ""
echo "  --- 17. IPv4 + IPv6 combined ---"
write_mock_config /api "define('USE_IPV6', true)"
run_update
assert_run_exit "exits 0" 0
assert_output "checks IPv4" "Getting IPv4 address from"
assert_output "checks IPv6" "Getting IPv6 address from"
assert_output "reports IPv4 status" "IPv4 address hasn't changed"
assert_output "reports IPv6 status" "IPv6 address hasn't changed"

# --- 18. Quiet mode ---
# With --quiet, NOTICE messages should be suppressed, but errors still shown.
echo ""
echo "  --- 18. Quiet mode ---"
write_mock_config /api
run_update --quiet
assert_run_exit "exits 0" 0
assert_output_missing "suppresses NOTICE output" "[NOTICE]"

# --- 19. API login failure ---
# The mock /api-login-fail always returns error 4013 (wrong credentials).
echo ""
echo "  --- 19. API login failure ---"
write_mock_config /api-login-fail
run_update
assert_run_exit "exits 1" 1
assert_output "shows login error" "Error while logging in"
# Error 4013 should include the hint about wrong credentials
assert_output "includes credential hint" "wrong API credentials"

# Malformed upstream responses should be retried and then fail with a
# controlled error instead of PHP warnings from array access on null.
echo ""
echo "  --- 19a. Invalid JSON from API ---"
write_mock_config /api-invalid-json
run_update
assert_run_exit "exits 1 on invalid JSON" 1
assert_output "reports invalid API response" "invalid API response"
assert_output_missing "does not leak PHP warnings on invalid JSON" "PHP Warning"

echo ""
echo "  --- 19b. Invalid API payload shape ---"
write_mock_config /api-invalid-payload
run_update
assert_run_exit "exits 1 on invalid payload" 1
assert_output "reports invalid payload as invalid API response" "invalid API response"
assert_output_missing "does not leak PHP warnings on invalid payload" "PHP Warning"

# --- 20. Garbage IP from primary, fallback succeeds ---
# The primary IP URL returns garbage text. The script retries (with
# RETRY_SLEEP=0 for fast testing), then falls back to the working URL.
echo ""
echo "  --- 20. Garbage primary IP → fallback ---"
cat > "$TEST_CONFIG" <<PHPEOF
<?php
define('CUSTOMERNR', '12345');
define('APIKEY', 'testkey');
define('APIPASSWORD', 'testpass');
define('APIURL', 'http://localhost:$MOCK_PORT/api');
define('USE_IPV4', true);
define('USE_IPV6', false);
define('CHANGE_TTL', false);
define('DOMAINLIST', 'example.com: @');
define('IPV4_ADDRESS_URL', 'http://localhost:$MOCK_PORT/ipv4-garbage');
define('IPV4_ADDRESS_URL_FALLBACK', 'http://localhost:$MOCK_PORT/ipv4');
define('IPV6_ADDRESS_URL', 'http://localhost:$MOCK_PORT/ipv6');
define('IPV6_ADDRESS_URL_FALLBACK', 'http://localhost:$MOCK_PORT/ipv6');
define('RETRY_SLEEP', 0);
define('JITTER_MAX', 0);
define('CACHE_FILE', '/dev/null');
PHPEOF
run_update
assert_run_exit "exits 0 after fallback" 0
assert_output "triggers fallback warning" "Trying fallback"
assert_output "retries before falling back" "Retrying now"
assert_output "eventually logs in" "Logged in successfully"

# --- 21. Manually provided IPv6 ---
# Pass -6 with a specific IPv6. The script should use it instead of fetching.
echo ""
echo "  --- 21. Manually provided IPv6 ---"
write_mock_config /api "define('USE_IPV4', false) define('USE_IPV6', true)"
run_update -6 "2001:db8::99"
assert_run_exit "exits 0" 0
assert_output "uses manual IPv6" 'Using manually provided IPv6 address "2001:db8::99"'
assert_output "detects AAAA change" "IPv6 address has changed"
assert_output "shows manual IPv6 as new" "Now: 2001:db8::99"

# --- 22. IPv6 changed (triggers AAAA update) ---
# The mock /api-ip-changed returns stale AAAA record (::1).
# The mock /ipv6 returns 2001:db8::42. Script should detect change and update.
echo ""
echo "  --- 22. IPv6 changed (AAAA update) ---"
write_mock_config /api-ip-changed "define('USE_IPV4', false) define('USE_IPV6', true)"
run_update
assert_run_exit "exits 0" 0
assert_output "detects IPv6 change" "IPv6 address has changed"
assert_output "shows old IPv6" "Before: ::1"
assert_output "shows new IPv6" "Now: 2001:db8::42"
assert_output "updates IPv6 successfully" "IPv6 address updated successfully"

# --- 23. AAAA record creation (no existing record) ---
# The mock /api-no-records returns empty records. With IPv6 enabled,
# the script should create a new AAAA record.
echo ""
echo "  --- 23. AAAA record creation ---"
write_mock_config /api-no-records "define('USE_IPV4', false) define('USE_IPV6', true)"
run_update
assert_run_exit "exits 0" 0
assert_output "detects missing AAAA record" "AAAA record for host @ doesn't exist, creating"
assert_output "creates and updates AAAA" "IPv6 address updated successfully"

# --- 24. Duplicate AAAA records (error) ---
# The mock /api-dup-aaaa returns two AAAA records for hostname '@'.
echo ""
echo "  --- 24. Duplicate AAAA records (error) ---"
write_mock_config /api-dup-aaaa "define('USE_IPV4', false) define('USE_IPV6', true)"
run_update
assert_run_exit "exits 1" 1
assert_output "reports multiple AAAA records" "Found multiple AAAA records for the host @"

# --- 25. Both IPv4 and IPv6 disabled (error) ---
# When both protocols are disabled, the script should refuse to run.
echo ""
echo "  --- 25. Both protocols disabled ---"
write_mock_config /api "define('USE_IPV4', false) define('USE_IPV6', false)"
run_update
assert_run_exit "exits 1" 1
assert_output "reports both disabled" "IPv4 as well as IPv6 is disabled"

# --- 26. Both IP services fail (error exit) ---
# Both primary and fallback return garbage → fetchIPWithFallback returns false.
echo ""
echo "  --- 26. Both IP services fail ---"
cat > "$TEST_CONFIG" <<PHPEOF
<?php
define('CUSTOMERNR', '12345');
define('APIKEY', 'testkey');
define('APIPASSWORD', 'testpass');
define('APIURL', 'http://localhost:$MOCK_PORT/api');
define('USE_IPV4', true);
define('USE_IPV6', false);
define('CHANGE_TTL', false);
define('DOMAINLIST', 'example.com: @');
define('IPV4_ADDRESS_URL', 'http://localhost:$MOCK_PORT/ipv4-garbage');
define('IPV4_ADDRESS_URL_FALLBACK', 'http://localhost:$MOCK_PORT/ipv4-garbage');
define('IPV6_ADDRESS_URL', 'http://localhost:$MOCK_PORT/ipv6');
define('IPV6_ADDRESS_URL_FALLBACK', 'http://localhost:$MOCK_PORT/ipv6');
define('RETRY_SLEEP', 0);
define('JITTER_MAX', 0);
define('CACHE_FILE', '/dev/null');
PHPEOF
run_update
assert_run_exit "exits 1 when both IPs fail" 1
assert_output "reports IPv4 failure" "didn't return a valid IPv4 address"

# --- 27. IPv6 services both fail (error exit) ---
echo ""
echo "  --- 27. Both IPv6 services fail ---"
cat > "$TEST_CONFIG" <<PHPEOF
<?php
define('CUSTOMERNR', '12345');
define('APIKEY', 'testkey');
define('APIPASSWORD', 'testpass');
define('APIURL', 'http://localhost:$MOCK_PORT/api');
define('USE_IPV4', false);
define('USE_IPV6', true);
define('CHANGE_TTL', false);
define('DOMAINLIST', 'example.com: @');
define('IPV4_ADDRESS_URL', 'http://localhost:$MOCK_PORT/ipv4');
define('IPV4_ADDRESS_URL_FALLBACK', 'http://localhost:$MOCK_PORT/ipv4');
define('IPV6_ADDRESS_URL', 'http://localhost:$MOCK_PORT/ipv6-garbage');
define('IPV6_ADDRESS_URL_FALLBACK', 'http://localhost:$MOCK_PORT/ipv6-garbage');
define('RETRY_SLEEP', 0);
define('JITTER_MAX', 0);
define('CACHE_FILE', '/dev/null');
PHPEOF
run_update
assert_run_exit "exits 1 when both IPv6 fail" 1
assert_output "reports IPv6 failure" "didn't return a valid IPv6 address"

# --- 28. Quiet mode: errors still shown ---
# With --quiet, NOTICE and WARNING are suppressed but ERROR must still appear.
echo ""
echo "  --- 28. Quiet mode: errors survive ---"
write_mock_config /api-login-fail
run_update --quiet
assert_run_exit "exits 1" 1
assert_output "ERROR still shown in quiet mode" "[ERROR]"
assert_output_missing "NOTICE suppressed in quiet mode" "[NOTICE]"

# --- 29. TTL update failure → continues ---
# updateDnsZone fails but the script should NOT exit — it prints
# "Failed to set TTL... Continuing." and continues processing.
echo ""
echo "  --- 29. TTL update failure (non-fatal) ---"
write_mock_config /api-ttl-update-fail "define('CHANGE_TTL', true)"
run_update
assert_run_exit "exits 0 despite TTL failure" 0
assert_output "reports TTL failure" "Failed to set TTL"
assert_output "continues after TTL failure" "Logged out successfully"

# --- 30. infoDnsZone failure → exits ---
echo ""
echo "  --- 30. infoDnsZone failure ---"
write_mock_config /api-zone-fail
run_update
assert_run_exit "exits 1" 1
assert_output "reports zone info error" "Error while getting DNS Zone info"

# --- 31. infoDnsRecords failure → exits ---
echo ""
echo "  --- 31. infoDnsRecords failure ---"
write_mock_config /api-records-fail
run_update
assert_run_exit "exits 1" 1
assert_output "reports records error" "Error while getting DNS Record info"

# --- 32. updateDnsRecords failure → exits ---
# The mock /api-update-fail returns stale IPs (to trigger update) but
# updateDnsRecords fails.
echo ""
echo "  --- 32. updateDnsRecords failure ---"
write_mock_config /api-update-fail
run_update
assert_run_exit "exits 1" 1
assert_output "reports update error" "Error while updating DNS Records"

# --- 33. Logout failure → exits ---
echo ""
echo "  --- 33. Logout failure ---"
write_mock_config /api-logout-fail
run_update
assert_run_exit "exits 1" 1
assert_output "reports logout error" "Error while logging out"

# --- 34. AAAA update failure → exits ---
# Same as test 32 but for IPv6: the mock returns stale AAAA records
# (to trigger update) but updateDnsRecords fails.
echo ""
echo "  --- 34. AAAA updateDnsRecords failure ---"
write_mock_config /api-update-fail "define('USE_IPV4', false) define('USE_IPV6', true)"
run_update
assert_run_exit "exits 1" 1
assert_output "reports AAAA update error" "Error while updating DNS Records"

# --- 35. Quiet mode suppresses [WARNING] ---
# The 4001 session-expire scenario generates [WARNING] messages. With --quiet,
# these should be suppressed while [ERROR] still appears if triggered.
echo ""
echo "  --- 35. Quiet mode suppresses warnings ---"
reset_mock_server
write_mock_config /api-session-expire
run_update --quiet
assert_run_exit "exits 0" 0
assert_output_missing "WARNING suppressed in quiet mode" "[WARNING]"
assert_output_missing "NOTICE suppressed in quiet mode" "[NOTICE]"

# --- 36. CHANGE_TTL=true but TTL already 300 (no-op) ---
# When TTL is already "300", no updateDnsZone call should be made even
# with CHANGE_TTL=true. The normal /api mock returns TTL="300".
echo ""
echo "  --- 36. TTL already optimal (no-op) ---"
write_mock_config /api "define('CHANGE_TTL', true)"
run_update
assert_run_exit "exits 0" 0
assert_output_missing "does not lower TTL when already 300" "Lowered TTL"
assert_output_missing "does not warn about high TTL" "TTL is higher than 300"

# --- 37. Jitter disabled → warning ---
# With JITTER_MAX=0 (used by all test configs), the jitter-disabled warning
# should appear. We verify it by NOT suppressing it with --quiet.
echo ""
echo "  --- 37. Jitter disabled warning ---"
write_mock_config /api
run_update
assert_run_exit "exits 0" 0
assert_output "jitter disabled warning shown" "Jitter is disabled"

# --- 38. Jitter enabled → logs delay ---
# With JITTER_MAX=1, the script sleeps 1 second and logs it.
echo ""
echo "  --- 38. Jitter enabled ---"
cat > "$TEST_CONFIG" <<PHPEOF
<?php
define('CUSTOMERNR', '12345');
define('APIKEY', 'testkey');
define('APIPASSWORD', 'testpass');
define('APIURL', 'http://localhost:$MOCK_PORT/api');
define('USE_IPV4', true);
define('USE_IPV6', false);
define('CHANGE_TTL', false);
define('DOMAINLIST', 'example.com: @');
define('IPV4_ADDRESS_URL', 'http://localhost:$MOCK_PORT/ipv4');
define('IPV4_ADDRESS_URL_FALLBACK', 'http://localhost:$MOCK_PORT/ipv4');
define('IPV6_ADDRESS_URL', 'http://localhost:$MOCK_PORT/ipv6');
define('IPV6_ADDRESS_URL_FALLBACK', 'http://localhost:$MOCK_PORT/ipv6');
define('RETRY_SLEEP', 0);
define('JITTER_MAX', 1);
define('CACHE_FILE', '/dev/null');
PHPEOF
run_update
assert_run_exit "exits 0" 0
assert_output "jitter delay logged" "Waiting 1 second (jitter)"
assert_output_missing "no jitter-disabled warning" "Jitter is disabled"

# --- 39. Cache hit → skips API ---
# Write a cache file with the same IP and config hash as the mock returns.
# The script should detect no change and exit without logging in.
echo ""
echo "  --- 39. Cache hit (skips API) ---"
CACHE_TMP="$SCRIPT_DIR/cache.test.json"
# Compute the config hash matching the test config (DOMAINLIST='example.com: @', USE_IPV4=true, USE_IPV6=false, CHANGE_TTL=false)
CACHE_HASH=$(php -r "echo md5(json_encode(array('domainlist'=>'example.com: @','use_ipv4'=>true,'use_ipv6'=>false,'change_ttl'=>false)));")
echo "{\"config_hash\":\"$CACHE_HASH\",\"ipv4\":\"203.0.113.42\"}" > "$CACHE_TMP"
cat > "$TEST_CONFIG" <<PHPEOF
<?php
define('CUSTOMERNR', '12345');
define('APIKEY', 'testkey');
define('APIPASSWORD', 'testpass');
define('APIURL', 'http://localhost:$MOCK_PORT/api');
define('USE_IPV4', true);
define('USE_IPV6', false);
define('CHANGE_TTL', false);
define('DOMAINLIST', 'example.com: @');
define('IPV4_ADDRESS_URL', 'http://localhost:$MOCK_PORT/ipv4');
define('IPV4_ADDRESS_URL_FALLBACK', 'http://localhost:$MOCK_PORT/ipv4');
define('IPV6_ADDRESS_URL', 'http://localhost:$MOCK_PORT/ipv6');
define('IPV6_ADDRESS_URL_FALLBACK', 'http://localhost:$MOCK_PORT/ipv6');
define('RETRY_SLEEP', 0);
define('JITTER_MAX', 0);
define('CACHE_FILE', '$CACHE_TMP');
PHPEOF
run_update
assert_run_exit "exits 0" 0
assert_output "cache hit message" "IP address hasn't changed since last run (cached)"
assert_output_missing "does not log in" "Logged in successfully"
assert_output_missing "no jitter on cache hit" "Waiting"
rm -f "$CACHE_TMP"

# --- 40. Cache miss → proceeds with full update ---
# Write a cache file with a DIFFERENT IP. The script should detect
# the change and proceed with the full API flow.
echo ""
echo "  --- 40. Cache miss (proceeds with update) ---"
CACHE_TMP="$SCRIPT_DIR/cache.test.json"
echo "{\"config_hash\":\"$CACHE_HASH\",\"ipv4\":\"1.2.3.4\"}" > "$CACHE_TMP"
cat > "$TEST_CONFIG" <<PHPEOF
<?php
define('CUSTOMERNR', '12345');
define('APIKEY', 'testkey');
define('APIPASSWORD', 'testpass');
define('APIURL', 'http://localhost:$MOCK_PORT/api');
define('USE_IPV4', true);
define('USE_IPV6', false);
define('CHANGE_TTL', false);
define('DOMAINLIST', 'example.com: @');
define('IPV4_ADDRESS_URL', 'http://localhost:$MOCK_PORT/ipv4');
define('IPV4_ADDRESS_URL_FALLBACK', 'http://localhost:$MOCK_PORT/ipv4');
define('IPV6_ADDRESS_URL', 'http://localhost:$MOCK_PORT/ipv6');
define('IPV6_ADDRESS_URL_FALLBACK', 'http://localhost:$MOCK_PORT/ipv6');
define('RETRY_SLEEP', 0);
define('JITTER_MAX', 0);
define('CACHE_FILE', '$CACHE_TMP');
PHPEOF
run_update
assert_run_exit "exits 0" 0
assert_output "logs in on cache miss" "Logged in successfully"
assert_output_missing "no cache hit message" "cached"
rm -f "$CACHE_TMP"

# --- 41. --force bypasses cache ---
# Cache file matches, but --force should bypass it and proceed with update.
echo ""
echo "  --- 41. Force bypasses cache ---"
CACHE_TMP="$SCRIPT_DIR/cache.test.json"
echo "{\"config_hash\":\"$CACHE_HASH\",\"ipv4\":\"203.0.113.42\"}" > "$CACHE_TMP"
cat > "$TEST_CONFIG" <<PHPEOF
<?php
define('CUSTOMERNR', '12345');
define('APIKEY', 'testkey');
define('APIPASSWORD', 'testpass');
define('APIURL', 'http://localhost:$MOCK_PORT/api');
define('USE_IPV4', true);
define('USE_IPV6', false);
define('CHANGE_TTL', false);
define('DOMAINLIST', 'example.com: @');
define('IPV4_ADDRESS_URL', 'http://localhost:$MOCK_PORT/ipv4');
define('IPV4_ADDRESS_URL_FALLBACK', 'http://localhost:$MOCK_PORT/ipv4');
define('IPV6_ADDRESS_URL', 'http://localhost:$MOCK_PORT/ipv6');
define('IPV6_ADDRESS_URL_FALLBACK', 'http://localhost:$MOCK_PORT/ipv6');
define('RETRY_SLEEP', 0);
define('JITTER_MAX', 0);
define('CACHE_FILE', '$CACHE_TMP');
PHPEOF
run_update --force
assert_run_exit "exits 0" 0
assert_output "force mode message" "Force mode enabled"
assert_output "logs in despite cache match" "Logged in successfully"
assert_output_missing "no cache hit message" "cached"
rm -f "$CACHE_TMP"

# --- 42. Cache file written after successful run ---
# Use a fresh cache path. After the run, the cache file should exist
# and contain the current IP.
echo ""
echo "  --- 42. Cache written after success ---"
CACHE_TMP="$SCRIPT_DIR/cache.test.json"
rm -f "$CACHE_TMP"
cat > "$TEST_CONFIG" <<PHPEOF
<?php
define('CUSTOMERNR', '12345');
define('APIKEY', 'testkey');
define('APIPASSWORD', 'testpass');
define('APIURL', 'http://localhost:$MOCK_PORT/api');
define('USE_IPV4', true);
define('USE_IPV6', false);
define('CHANGE_TTL', false);
define('DOMAINLIST', 'example.com: @');
define('IPV4_ADDRESS_URL', 'http://localhost:$MOCK_PORT/ipv4');
define('IPV4_ADDRESS_URL_FALLBACK', 'http://localhost:$MOCK_PORT/ipv4');
define('IPV6_ADDRESS_URL', 'http://localhost:$MOCK_PORT/ipv6');
define('IPV6_ADDRESS_URL_FALLBACK', 'http://localhost:$MOCK_PORT/ipv6');
define('RETRY_SLEEP', 0);
define('JITTER_MAX', 0);
define('CACHE_FILE', '$CACHE_TMP');
PHPEOF
run_update
assert_run_exit "exits 0" 0
if [ -f "$CACHE_TMP" ]; then
    pass "cache file created"
else
    fail "cache file created"
fi
# Verify the cache contains the mock's IPv4 address
if grep -qF "203.0.113.42" "$CACHE_TMP" 2>/dev/null; then
    pass "cache contains correct IPv4"
else
    fail "cache contains correct IPv4"
fi
rm -f "$CACHE_TMP"

# --- 43. Cache with IPv6 ---
# Enable both protocols, verify cache stores both IPs, and a subsequent
# run hits the cache.
echo ""
echo "  --- 43. Cache with IPv4+IPv6 ---"
CACHE_TMP="$SCRIPT_DIR/cache.test.json"
rm -f "$CACHE_TMP"
cat > "$TEST_CONFIG" <<PHPEOF
<?php
define('CUSTOMERNR', '12345');
define('APIKEY', 'testkey');
define('APIPASSWORD', 'testpass');
define('APIURL', 'http://localhost:$MOCK_PORT/api');
define('USE_IPV4', true);
define('USE_IPV6', true);
define('CHANGE_TTL', false);
define('DOMAINLIST', 'example.com: @');
define('IPV4_ADDRESS_URL', 'http://localhost:$MOCK_PORT/ipv4');
define('IPV4_ADDRESS_URL_FALLBACK', 'http://localhost:$MOCK_PORT/ipv4');
define('IPV6_ADDRESS_URL', 'http://localhost:$MOCK_PORT/ipv6');
define('IPV6_ADDRESS_URL_FALLBACK', 'http://localhost:$MOCK_PORT/ipv6');
define('RETRY_SLEEP', 0);
define('JITTER_MAX', 0);
define('CACHE_FILE', '$CACHE_TMP');
PHPEOF
# First run: no cache, full update, writes cache
run_update
assert_run_exit "first run exits 0" 0
assert_output "first run logs in" "Logged in successfully"
if grep -qF "2001:db8::42" "$CACHE_TMP" 2>/dev/null; then
    pass "cache contains IPv6"
else
    fail "cache contains IPv6"
fi
# Second run: cache hit, skips API
run_update
assert_run_exit "second run exits 0" 0
assert_output "second run hits cache" "IP address hasn't changed since last run (cached)"
assert_output_missing "second run does not log in" "Logged in successfully"
rm -f "$CACHE_TMP"

# --- 44. No cache file → proceeds normally ---
# When no cache file exists (first run), the script should proceed
# with the full update flow without errors.
echo ""
echo "  --- 44. No cache file (first run) ---"
CACHE_TMP="$SCRIPT_DIR/cache.test.json"
rm -f "$CACHE_TMP"
cat > "$TEST_CONFIG" <<PHPEOF
<?php
define('CUSTOMERNR', '12345');
define('APIKEY', 'testkey');
define('APIPASSWORD', 'testpass');
define('APIURL', 'http://localhost:$MOCK_PORT/api');
define('USE_IPV4', true);
define('USE_IPV6', false);
define('CHANGE_TTL', false);
define('DOMAINLIST', 'example.com: @');
define('IPV4_ADDRESS_URL', 'http://localhost:$MOCK_PORT/ipv4');
define('IPV4_ADDRESS_URL_FALLBACK', 'http://localhost:$MOCK_PORT/ipv4');
define('IPV6_ADDRESS_URL', 'http://localhost:$MOCK_PORT/ipv6');
define('IPV6_ADDRESS_URL_FALLBACK', 'http://localhost:$MOCK_PORT/ipv6');
define('RETRY_SLEEP', 0);
define('JITTER_MAX', 0);
define('CACHE_FILE', '$CACHE_TMP');
PHPEOF
run_update
assert_run_exit "exits 0" 0
assert_output "logs in without cache" "Logged in successfully"
assert_output_missing "no cache hit message" "cached"
rm -f "$CACHE_TMP"

# --- 45. Config change invalidates cache ---
# Cache has the correct IP but was written with a different DOMAINLIST.
# The config fingerprint won't match → cache miss → full update.
echo ""
echo "  --- 45. Config change invalidates cache ---"
CACHE_TMP="$SCRIPT_DIR/cache.test.json"
# Write a cache with the hash from DOMAINLIST='example.com: @' (standard test config)
echo "{\"config_hash\":\"$CACHE_HASH\",\"ipv4\":\"203.0.113.42\"}" > "$CACHE_TMP"
# But run with a DIFFERENT DOMAINLIST — the hash won't match
cat > "$TEST_CONFIG" <<PHPEOF
<?php
define('CUSTOMERNR', '12345');
define('APIKEY', 'testkey');
define('APIPASSWORD', 'testpass');
define('APIURL', 'http://localhost:$MOCK_PORT/api');
define('USE_IPV4', true);
define('USE_IPV6', false);
define('CHANGE_TTL', false);
define('DOMAINLIST', 'example.com: @, www');
define('IPV4_ADDRESS_URL', 'http://localhost:$MOCK_PORT/ipv4');
define('IPV4_ADDRESS_URL_FALLBACK', 'http://localhost:$MOCK_PORT/ipv4');
define('IPV6_ADDRESS_URL', 'http://localhost:$MOCK_PORT/ipv6');
define('IPV6_ADDRESS_URL_FALLBACK', 'http://localhost:$MOCK_PORT/ipv6');
define('RETRY_SLEEP', 0);
define('JITTER_MAX', 0);
define('CACHE_FILE', '$CACHE_TMP');
PHPEOF
run_update
assert_run_exit "exits 0" 0
assert_output "logs in despite matching IP" "Logged in successfully"
assert_output_missing "no cache hit" "cached"
# Verify the new subdomain was processed
assert_output "processes new subdomain" 'Updating DNS records for subdomain "www"'
rm -f "$CACHE_TMP"

# --- 45a. Env-mode end-to-end via entrypoint --run-once ---
# The entrypoint generates config.php from env vars and execs update.php
# in --run-once mode. We point everything at the mock server to verify
# the generated config is actually consumed correctly by update.php.
echo ""
echo "  --- 45a. Env-mode end-to-end via entrypoint --run-once ---"
E2E_TMP="$(mktemp -d)"
E2E_APP="$E2E_TMP/app"
mkdir -p "$E2E_APP/data"
cp "$PROJECT_DIR/update.php" "$PROJECT_DIR/functions.php" "$PROJECT_DIR/healthcheck.php" "$E2E_APP/"
e2e_output=$(
    env \
        APP_DIR="$E2E_APP" \
        CUSTOMERNR="12345" \
        APIKEY="testkey" \
        APIPASSWORD="testpass" \
        DOMAINLIST="example.com: @" \
        USE_IPV4="true" \
        USE_IPV6="false" \
        CHANGE_TTL="false" \
        APIURL="http://localhost:$MOCK_PORT/api" \
        IPV4_ADDRESS_URL="http://localhost:$MOCK_PORT/ipv4" \
        IPV4_ADDRESS_URL_FALLBACK="http://localhost:$MOCK_PORT/ipv4" \
        IPV6_ADDRESS_URL="http://localhost:$MOCK_PORT/ipv6" \
        IPV6_ADDRESS_URL_FALLBACK="http://localhost:$MOCK_PORT/ipv6" \
        JITTER_MAX="0" \
        RETRY_SLEEP="0" \
        sh "$PROJECT_DIR/docker-entrypoint.sh" --run-once 2>&1
) && e2e_status=$? || e2e_status=$?
if [ "$e2e_status" -eq 0 ]; then
    pass "env-mode end-to-end exits 0"
else
    fail "env-mode end-to-end exits 0 (got $e2e_status)"
fi
if echo "$e2e_output" | grep -qF "Loading config from environment variables"; then
    pass "env-mode announces it loaded from environment"
else
    fail "env-mode announces it loaded from environment"
fi
if echo "$e2e_output" | grep -qF "Logged in successfully"; then
    pass "env-mode generated config drives a successful login"
else
    fail "env-mode generated config drives a successful login"
fi
if echo "$e2e_output" | grep -qF "Logged out successfully"; then
    pass "env-mode end-to-end completes a full update cycle"
else
    fail "env-mode end-to-end completes a full update cycle"
fi
if [ -f "$E2E_APP/config.php" ] && grep -qF "define('CUSTOMERNR', '12345');" "$E2E_APP/config.php"; then
    pass "env-mode generated config.php is left in place for inspection"
else
    fail "env-mode generated config.php is left in place for inspection"
fi
rm -rf "$E2E_TMP"

fi  # end of cURL/python3 availability check

# ===========================================================================
# 46-52. DOCKER ENTRYPOINT / HEALTHCHECK
# ===========================================================================

echo ""
echo "=== 46-52. Docker entrypoint / healthcheck ==="

# --- 46. Initial failure should abort before scheduling cron ---
echo ""
echo "  --- 46. Entrypoint fails fast on startup error ---"
ENTRYPOINT_TMP="$(mktemp -d)"
ENTRYPOINT_APP="$ENTRYPOINT_TMP/app"
ENTRYPOINT_BIN="$ENTRYPOINT_TMP/bin"
ENTRYPOINT_LOG="$ENTRYPOINT_TMP/log.txt"
ENTRYPOINT_CRONTAB="$ENTRYPOINT_TMP/crontab.txt"
mkdir -p "$ENTRYPOINT_APP/data" "$ENTRYPOINT_BIN"
cat > "$ENTRYPOINT_APP/config.php" <<'EOF'
<?php
EOF
cat > "$ENTRYPOINT_APP/update.php" <<'EOF'
<?php
EOF
cat > "$ENTRYPOINT_BIN/php" <<EOF
#!/bin/sh
echo "php \$*" >> "$ENTRYPOINT_LOG"
exit 1
EOF
cat > "$ENTRYPOINT_BIN/crontab" <<EOF
#!/bin/sh
cat > "$ENTRYPOINT_CRONTAB"
echo "crontab \$*" >> "$ENTRYPOINT_LOG"
exit 0
EOF
cat > "$ENTRYPOINT_BIN/crond" <<EOF
#!/bin/sh
echo "crond \$*" >> "$ENTRYPOINT_LOG"
exit 0
EOF
chmod +x "$ENTRYPOINT_BIN/php" "$ENTRYPOINT_BIN/crontab" "$ENTRYPOINT_BIN/crond"
entrypoint_output=$(PATH="$ENTRYPOINT_BIN:$PATH" APP_DIR="$ENTRYPOINT_APP" CRON_SCHEDULE="*/10 * * * *" sh "$PROJECT_DIR/docker-entrypoint.sh" 2>&1)
entrypoint_status=$?
if [ "$entrypoint_status" -eq 1 ]; then
    pass "entrypoint exits 1 when initial update fails"
else
    fail "entrypoint exits 1 when initial update fails (got $entrypoint_status)"
fi
if echo "$entrypoint_output" | grep -qF -- "Initial run failed. Exiting."; then
    pass "entrypoint reports initial failure"
else
    fail "entrypoint reports initial failure"
fi
if [ ! -f "$ENTRYPOINT_CRONTAB" ] && ! grep -q "^crond " "$ENTRYPOINT_LOG" 2>/dev/null; then
    pass "entrypoint does not schedule cron after startup failure"
else
    fail "entrypoint does not schedule cron after startup failure"
fi
rm -rf "$ENTRYPOINT_TMP"

# --- 47. Successful startup should install cron and start crond ---
echo ""
echo "  --- 47. Entrypoint schedules cron after successful startup ---"
ENTRYPOINT_TMP="$(mktemp -d)"
ENTRYPOINT_APP="$ENTRYPOINT_TMP/app"
ENTRYPOINT_BIN="$ENTRYPOINT_TMP/bin"
ENTRYPOINT_LOG="$ENTRYPOINT_TMP/log.txt"
ENTRYPOINT_CRONTAB="$ENTRYPOINT_TMP/crontab.txt"
ENTRYPOINT_HEARTBEAT="$ENTRYPOINT_APP/data/last_success.json"
mkdir -p "$ENTRYPOINT_APP/data" "$ENTRYPOINT_BIN"
cat > "$ENTRYPOINT_APP/config.php" <<'EOF'
<?php
EOF
cat > "$ENTRYPOINT_APP/update.php" <<'EOF'
<?php
EOF
cat > "$ENTRYPOINT_APP/healthcheck.php" <<'EOF'
<?php
EOF
cat > "$ENTRYPOINT_BIN/php" <<EOF
#!/bin/sh
echo "php \$*" >> "$ENTRYPOINT_LOG"
if [ "\$1" = "$ENTRYPOINT_APP/healthcheck.php" ] && [ "\$2" = "--mark-success" ]; then
    echo '{"timestamp":1}' > "$ENTRYPOINT_HEARTBEAT"
fi
exit 0
EOF
cat > "$ENTRYPOINT_BIN/crontab" <<EOF
#!/bin/sh
cat > "$ENTRYPOINT_CRONTAB"
echo "crontab \$*" >> "$ENTRYPOINT_LOG"
exit 0
EOF
cat > "$ENTRYPOINT_BIN/crond" <<EOF
#!/bin/sh
echo "crond \$*" >> "$ENTRYPOINT_LOG"
exit 0
EOF
chmod +x "$ENTRYPOINT_BIN/php" "$ENTRYPOINT_BIN/crontab" "$ENTRYPOINT_BIN/crond"
entrypoint_output=$(PATH="$ENTRYPOINT_BIN:$PATH" APP_DIR="$ENTRYPOINT_APP" CRON_SCHEDULE="*/10 * * * *" sh "$PROJECT_DIR/docker-entrypoint.sh" --quiet 2>&1)
entrypoint_status=$?
if [ "$entrypoint_status" -eq 0 ]; then
    pass "entrypoint exits 0 after successful startup"
else
    fail "entrypoint exits 0 after successful startup (got $entrypoint_status)"
fi
if grep -qF -- "php $ENTRYPOINT_APP/update.php -c $ENTRYPOINT_APP/config.docker.php --quiet" "$ENTRYPOINT_LOG"; then
    pass "entrypoint runs updater before starting cron"
else
    fail "entrypoint runs updater before starting cron"
fi
if [ -f "$ENTRYPOINT_HEARTBEAT" ] && \
   grep -qF -- "php $ENTRYPOINT_APP/healthcheck.php --mark-success" "$ENTRYPOINT_LOG"; then
    pass "entrypoint records a heartbeat after successful startup"
else
    fail "entrypoint records a heartbeat after successful startup"
fi
if grep -qF -- "php $ENTRYPOINT_APP/update.php -c $ENTRYPOINT_APP/config.docker.php" "$ENTRYPOINT_CRONTAB" && \
   grep -qF -- "php $ENTRYPOINT_APP/healthcheck.php --mark-success" "$ENTRYPOINT_CRONTAB" && \
   grep -qF -- "'--quiet' >> /proc/1/fd/1 2>> /proc/1/fd/2" "$ENTRYPOINT_CRONTAB"; then
    pass "entrypoint installs expected cron command with heartbeat update"
else
    fail "entrypoint installs expected cron command with heartbeat update"
fi
if grep -qF -- "crond -f -l 2" "$ENTRYPOINT_LOG"; then
    pass "entrypoint starts crond in foreground"
else
    fail "entrypoint starts crond in foreground"
fi
rm -rf "$ENTRYPOINT_TMP"

# --- 48. healthcheck --mark-success writes a heartbeat file ---
echo ""
echo "  --- 48. Healthcheck writes heartbeat ---"
HEALTHCHECK_TMP="$(mktemp -d)"
HEALTHCHECK_APP_DIR="$HEALTHCHECK_TMP/app"
HEALTHCHECK_DATA_DIR="$HEALTHCHECK_APP_DIR/data"
HEALTHCHECK_FILE="$HEALTHCHECK_DATA_DIR/last_success.json"
HEALTHCHECK_SCHEDULE="*/5 * * * *"
HEALTHCHECK_NOW="2026-03-21 10:02:00 UTC"
HEALTHCHECK_GRACE="0"
HEALTHCHECK_TZ="UTC"
mkdir -p "$HEALTHCHECK_DATA_DIR"
cat > "$HEALTHCHECK_APP_DIR/config.php" <<'EOF'
<?php
define('JITTER_MAX', 30);
EOF
run_healthcheck --mark-success
assert_healthcheck_exit "mark-success exits 0" 0
if [ -f "$HEALTHCHECK_FILE" ] && grep -qF -- '"timestamp":1774087320' "$HEALTHCHECK_FILE"; then
    pass "mark-success writes the heartbeat file"
else
    fail "mark-success writes the heartbeat file"
fi
rm -rf "$HEALTHCHECK_TMP"

# --- 49. healthcheck stays healthy before the next scheduled run is due ---
echo ""
echo "  --- 49. Healthcheck healthy before next run ---"
HEALTHCHECK_TMP="$(mktemp -d)"
HEALTHCHECK_APP_DIR="$HEALTHCHECK_TMP/app"
HEALTHCHECK_DATA_DIR="$HEALTHCHECK_APP_DIR/data"
HEALTHCHECK_FILE="$HEALTHCHECK_DATA_DIR/last_success.json"
HEALTHCHECK_SCHEDULE="*/10 * * * *"
HEALTHCHECK_NOW="2026-03-21 10:09:00 UTC"
HEALTHCHECK_GRACE="0"
HEALTHCHECK_TZ="UTC"
mkdir -p "$HEALTHCHECK_DATA_DIR"
cat > "$HEALTHCHECK_APP_DIR/config.php" <<'EOF'
<?php
define('JITTER_MAX', 30);
EOF
echo '{"timestamp":1774087320}' > "$HEALTHCHECK_FILE"
run_healthcheck
assert_healthcheck_exit "healthcheck exits 0 before the next scheduled run" 0
rm -rf "$HEALTHCHECK_TMP"

# --- 50. healthcheck goes unhealthy after a missed scheduled run ---
echo ""
echo "  --- 50. Healthcheck unhealthy after missed run ---"
HEALTHCHECK_TMP="$(mktemp -d)"
HEALTHCHECK_APP_DIR="$HEALTHCHECK_TMP/app"
HEALTHCHECK_DATA_DIR="$HEALTHCHECK_APP_DIR/data"
HEALTHCHECK_FILE="$HEALTHCHECK_DATA_DIR/last_success.json"
HEALTHCHECK_SCHEDULE="*/5 * * * *"
HEALTHCHECK_NOW="2026-03-21 10:07:00 UTC"
HEALTHCHECK_GRACE="30"
HEALTHCHECK_TZ="UTC"
mkdir -p "$HEALTHCHECK_DATA_DIR"
cat > "$HEALTHCHECK_APP_DIR/config.php" <<'EOF'
<?php
define('JITTER_MAX', 30);
EOF
echo '{"timestamp":1774087320}' > "$HEALTHCHECK_FILE"
run_healthcheck
assert_healthcheck_exit "healthcheck exits 1 after a missed scheduled run" 1
assert_healthcheck_output "healthcheck reports the missed scheduled run" "next scheduled run was"
rm -rf "$HEALTHCHECK_TMP"

# --- 51. weekday-only schedules stay healthy over the weekend ---
echo ""
echo "  --- 51. Healthcheck respects weekday schedules ---"
HEALTHCHECK_TMP="$(mktemp -d)"
HEALTHCHECK_APP_DIR="$HEALTHCHECK_TMP/app"
HEALTHCHECK_DATA_DIR="$HEALTHCHECK_APP_DIR/data"
HEALTHCHECK_FILE="$HEALTHCHECK_DATA_DIR/last_success.json"
HEALTHCHECK_SCHEDULE="0 3 * * 1-5"
HEALTHCHECK_NOW="2026-03-21 12:00:00 UTC"
HEALTHCHECK_GRACE="0"
HEALTHCHECK_TZ="UTC"
mkdir -p "$HEALTHCHECK_DATA_DIR"
cat > "$HEALTHCHECK_APP_DIR/config.php" <<'EOF'
<?php
define('JITTER_MAX', 30);
EOF
echo '{"timestamp":1773975600}' > "$HEALTHCHECK_FILE"
run_healthcheck
assert_healthcheck_exit "weekday-only schedule stays healthy over the weekend" 0
rm -rf "$HEALTHCHECK_TMP"

# --- 52. Dockerfile defines the image healthcheck ---
echo ""
echo "  --- 52. Dockerfile healthcheck ---"
if grep -qF -- 'HEALTHCHECK --interval=1m --timeout=10s --start-period=2m --retries=3 CMD ["php", "/app/healthcheck.php"]' "$PROJECT_DIR/Dockerfile"; then
    pass "Dockerfile defines the container healthcheck"
else
    fail "Dockerfile defines the container healthcheck"
fi

# ===========================================================================
# 53-61. DOCKER ENTRYPOINT — ENV-VAR CONFIG MODE
# ===========================================================================
#
# These tests exercise the env-var configuration path in
# docker-entrypoint.sh. They use mock php/crontab/crond binaries placed
# in a temp dir and override PATH so the entrypoint never invokes the
# real binaries — only its own shell logic and the actual generated
# config file are validated.

echo ""
echo "=== 53-61. Docker entrypoint env-var config mode ==="

# Helper: write a stub php/crontab/crond into $1 so the entrypoint can
# proceed past the initial run, heartbeat, and crond invocation.
make_entrypoint_mocks() {
    local bin="$1"
    local app="$2"
    local heartbeat="$app/data/last_success.json"
    cat > "$bin/php" <<EOF
#!/bin/sh
if [ "\$1" = "$app/healthcheck.php" ] && [ "\$2" = "--mark-success" ]; then
    echo '{"timestamp":1}' > "$heartbeat"
fi
exit 0
EOF
    cat > "$bin/crontab" <<'EOF'
#!/bin/sh
cat > /dev/null
exit 0
EOF
    cat > "$bin/crond" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "$bin/php" "$bin/crontab" "$bin/crond"
}

# --- 53. Env-mode generates config.php from env vars ---
echo ""
echo "  --- 53. Env-mode generates config.php from env vars ---"
ENV_TMP="$(mktemp -d)"
ENV_APP="$ENV_TMP/app"
ENV_BIN="$ENV_TMP/bin"
mkdir -p "$ENV_APP/data" "$ENV_BIN"
make_entrypoint_mocks "$ENV_BIN" "$ENV_APP"
env_output=$(
    env \
        PATH="$ENV_BIN:$PATH" \
        APP_DIR="$ENV_APP" \
        CRON_SCHEDULE="*/10 * * * *" \
        CUSTOMERNR="12345" \
        APIKEY="testkey" \
        APIPASSWORD="testpass" \
        DOMAINLIST="example.com: @, www" \
        sh "$PROJECT_DIR/docker-entrypoint.sh" --quiet 2>&1
) && env_status=$? || env_status=$?
if [ "$env_status" -eq 0 ]; then
    pass "env-mode entrypoint exits 0"
else
    fail "env-mode entrypoint exits 0 (got $env_status)"
fi
if [ -f "$ENV_APP/config.php" ]; then
    pass "env-mode writes config.php"
else
    fail "env-mode writes config.php"
fi
if php -l "$ENV_APP/config.php" > /dev/null 2>&1; then
    pass "env-mode generated config.php has valid PHP syntax"
else
    fail "env-mode generated config.php has valid PHP syntax"
fi
verify=$(php -r "require '$ENV_APP/config.php'; echo CUSTOMERNR.'|'.APIKEY.'|'.APIPASSWORD.'|'.DOMAINLIST.'|'.var_export(USE_IPV4, true).'|'.var_export(USE_IPV6, true).'|'.var_export(CHANGE_TTL, true).'|'.APIURL;" 2>/dev/null)
expected="12345|testkey|testpass|example.com: @, www|true|false|false|https://ccp.netcup.net/run/webservice/servers/endpoint.php?JSON"
if [ "$verify" = "$expected" ]; then
    pass "env-mode generated config has expected values + defaults"
else
    fail "env-mode generated config has expected values + defaults (got '$verify')"
fi
if echo "$env_output" | grep -qF -- "Loading config from environment variables"; then
    pass "env-mode announces env-driven config"
else
    fail "env-mode announces env-driven config"
fi
rm -rf "$ENV_TMP"

# --- 54. Env-mode missing required variables fails fast ---
echo ""
echo "  --- 54. Env-mode missing required variables fails fast ---"
# Each iteration unsets one required var and confirms it's reported.
for missing_var in CUSTOMERNR APIKEY APIPASSWORD DOMAINLIST; do
    ENV_TMP="$(mktemp -d)"
    ENV_APP="$ENV_TMP/app"
    ENV_BIN="$ENV_TMP/bin"
    mkdir -p "$ENV_APP/data" "$ENV_BIN"
    make_entrypoint_mocks "$ENV_BIN" "$ENV_APP"
    # Build the env list by removing the variable under test.
    env_args="CUSTOMERNR=12345 APIKEY=k APIPASSWORD=p DOMAINLIST=example.com:@"
    env_args=$(echo "$env_args" | sed -E "s/(^| )$missing_var=[^ ]*//")
    env_output=$(
        env -i \
            PATH="$ENV_BIN:$PATH" \
            APP_DIR="$ENV_APP" \
            $env_args \
            sh "$PROJECT_DIR/docker-entrypoint.sh" 2>&1
    ) && env_status=$? || env_status=$?
    if [ "$env_status" -eq 1 ]; then
        pass "missing $missing_var exits 1"
    else
        fail "missing $missing_var exits 1 (got $env_status)"
    fi
    if echo "$env_output" | grep -qF "$missing_var" && \
       echo "$env_output" | grep -qF "Missing required environment variable"; then
        pass "missing $missing_var reports the variable name"
    else
        fail "missing $missing_var reports the variable name (output: $env_output)"
    fi
    if [ ! -f "$ENV_APP/config.php" ]; then
        pass "missing $missing_var does not write a partial config.php"
    else
        fail "missing $missing_var does not write a partial config.php"
    fi
    rm -rf "$ENV_TMP"
done

# --- 55. Env-mode accepts boolean variants ---
echo ""
echo "  --- 55. Env-mode accepts boolean variants ---"
# Truthy values that should produce PHP true.
for truthy in true True TRUE 1 yes Yes YES on On ON; do
    ENV_TMP="$(mktemp -d)"
    ENV_APP="$ENV_TMP/app"
    ENV_BIN="$ENV_TMP/bin"
    mkdir -p "$ENV_APP/data" "$ENV_BIN"
    make_entrypoint_mocks "$ENV_BIN" "$ENV_APP"
    env -i \
        PATH="$ENV_BIN:$PATH" \
        APP_DIR="$ENV_APP" \
        CUSTOMERNR=1 APIKEY=k APIPASSWORD=p DOMAINLIST="a.com: @" \
        USE_IPV4="$truthy" USE_IPV6="$truthy" CHANGE_TTL="$truthy" \
        sh "$PROJECT_DIR/docker-entrypoint.sh" --quiet > /dev/null 2>&1
    bools=$(php -r "require '$ENV_APP/config.php'; echo var_export(USE_IPV4, true).'|'.var_export(USE_IPV6, true).'|'.var_export(CHANGE_TTL, true);" 2>/dev/null)
    if [ "$bools" = "true|true|true" ]; then
        pass "boolean '$truthy' maps to PHP true for all three flags"
    else
        fail "boolean '$truthy' maps to PHP true (got '$bools')"
    fi
    rm -rf "$ENV_TMP"
done
# Falsy values that should produce PHP false.
for falsy in false False FALSE 0 no No NO off Off OFF; do
    ENV_TMP="$(mktemp -d)"
    ENV_APP="$ENV_TMP/app"
    ENV_BIN="$ENV_TMP/bin"
    mkdir -p "$ENV_APP/data" "$ENV_BIN"
    make_entrypoint_mocks "$ENV_BIN" "$ENV_APP"
    env -i \
        PATH="$ENV_BIN:$PATH" \
        APP_DIR="$ENV_APP" \
        CUSTOMERNR=1 APIKEY=k APIPASSWORD=p DOMAINLIST="a.com: @" \
        USE_IPV4="$falsy" USE_IPV6="$falsy" CHANGE_TTL="$falsy" \
        sh "$PROJECT_DIR/docker-entrypoint.sh" --quiet > /dev/null 2>&1
    bools=$(php -r "require '$ENV_APP/config.php'; echo var_export(USE_IPV4, true).'|'.var_export(USE_IPV6, true).'|'.var_export(CHANGE_TTL, true);" 2>/dev/null)
    if [ "$bools" = "false|false|false" ]; then
        pass "boolean '$falsy' maps to PHP false for all three flags"
    else
        fail "boolean '$falsy' maps to PHP false (got '$bools')"
    fi
    rm -rf "$ENV_TMP"
done

# --- 56. Env-mode rejects invalid boolean and non-numeric values ---
echo ""
echo "  --- 56. Env-mode rejects invalid values ---"
for bad_bool in maybe yep "  " 2 truefalse; do
    ENV_TMP="$(mktemp -d)"
    ENV_APP="$ENV_TMP/app"
    ENV_BIN="$ENV_TMP/bin"
    mkdir -p "$ENV_APP/data" "$ENV_BIN"
    make_entrypoint_mocks "$ENV_BIN" "$ENV_APP"
    env_output=$(
        env -i \
            PATH="$ENV_BIN:$PATH" \
            APP_DIR="$ENV_APP" \
            CUSTOMERNR=1 APIKEY=k APIPASSWORD=p DOMAINLIST="a.com: @" \
            USE_IPV4="$bad_bool" \
            sh "$PROJECT_DIR/docker-entrypoint.sh" 2>&1
    ) && env_status=$? || env_status=$?
    if [ "$env_status" -eq 1 ]; then
        pass "invalid USE_IPV4='$bad_bool' exits 1"
    else
        fail "invalid USE_IPV4='$bad_bool' exits 1 (got $env_status)"
    fi
    if echo "$env_output" | grep -qF "Invalid USE_IPV4"; then
        pass "invalid USE_IPV4='$bad_bool' reports the failing variable"
    else
        fail "invalid USE_IPV4='$bad_bool' reports the failing variable"
    fi
    rm -rf "$ENV_TMP"
done
# Empty USE_IPV4 should fall back to the default (true) — same convention
# as ${VAR:-default} expansion. This is consistent with the numeric vars.
ENV_TMP="$(mktemp -d)"
ENV_APP="$ENV_TMP/app"
ENV_BIN="$ENV_TMP/bin"
mkdir -p "$ENV_APP/data" "$ENV_BIN"
make_entrypoint_mocks "$ENV_BIN" "$ENV_APP"
env -i \
    PATH="$ENV_BIN:$PATH" \
    APP_DIR="$ENV_APP" \
    CUSTOMERNR=1 APIKEY=k APIPASSWORD=p DOMAINLIST="a.com: @" \
    USE_IPV4="" \
    sh "$PROJECT_DIR/docker-entrypoint.sh" --quiet > /dev/null 2>&1
default_use_ipv4=$(php -r "require '$ENV_APP/config.php'; echo var_export(USE_IPV4, true);" 2>/dev/null)
if [ "$default_use_ipv4" = "true" ]; then
    pass "empty USE_IPV4 falls back to the default (true)"
else
    fail "empty USE_IPV4 falls back to the default (got '$default_use_ipv4')"
fi
rm -rf "$ENV_TMP"
for bad_num in abc 1.5 -1 "10 20" "" 099 01 +5; do
    ENV_TMP="$(mktemp -d)"
    ENV_APP="$ENV_TMP/app"
    ENV_BIN="$ENV_TMP/bin"
    mkdir -p "$ENV_APP/data" "$ENV_BIN"
    make_entrypoint_mocks "$ENV_BIN" "$ENV_APP"
    env_output=$(
        env -i \
            PATH="$ENV_BIN:$PATH" \
            APP_DIR="$ENV_APP" \
            CUSTOMERNR=1 APIKEY=k APIPASSWORD=p DOMAINLIST="a.com: @" \
            RETRY_SLEEP="$bad_num" \
            sh "$PROJECT_DIR/docker-entrypoint.sh" 2>&1
    ) && env_status=$? || env_status=$?
    # Empty string is treated as "unset" — should NOT fail. All other bad
    # values must be rejected with exit 1.
    if [ -z "$bad_num" ]; then
        if [ "$env_status" -eq 0 ]; then
            pass "empty RETRY_SLEEP is treated as unset (exit 0)"
        else
            fail "empty RETRY_SLEEP is treated as unset (got $env_status; output: $env_output)"
        fi
    else
        if [ "$env_status" -eq 1 ] && echo "$env_output" | grep -qF "Invalid RETRY_SLEEP"; then
            pass "invalid RETRY_SLEEP='$bad_num' rejected with clear error"
        else
            fail "invalid RETRY_SLEEP='$bad_num' rejected (status=$env_status; output: $env_output)"
        fi
    fi
    rm -rf "$ENV_TMP"
done
# Multi-line input is a security regression: a permissive validator could
# accept a value whose first/last lines look numeric and inline arbitrary
# PHP between them. Tested separately because shell `for` loops don't
# iterate values containing newlines cleanly.
ENV_TMP="$(mktemp -d)"
ENV_APP="$ENV_TMP/app"
ENV_BIN="$ENV_TMP/bin"
mkdir -p "$ENV_APP/data" "$ENV_BIN"
make_entrypoint_mocks "$ENV_BIN" "$ENV_APP"
ML_PAYLOAD=$(printf '1\n);define("PWNED",true);//\n0')
env_output=$(
    env -i \
        PATH="$ENV_BIN:$PATH" \
        APP_DIR="$ENV_APP" \
        CUSTOMERNR=1 APIKEY=k APIPASSWORD=p DOMAINLIST="a.com: @" \
        RETRY_SLEEP="$ML_PAYLOAD" \
        sh "$PROJECT_DIR/docker-entrypoint.sh" 2>&1
) && env_status=$? || env_status=$?
if [ "$env_status" -eq 1 ] && echo "$env_output" | grep -qF "Invalid RETRY_SLEEP"; then
    pass "multi-line RETRY_SLEEP rejected (no PHP injection)"
else
    fail "multi-line RETRY_SLEEP rejected (status=$env_status; output: $env_output)"
fi
if [ ! -f "$ENV_APP/config.php" ]; then
    pass "rejected multi-line RETRY_SLEEP did not write config.php"
else
    fail "rejected multi-line RETRY_SLEEP did not write config.php"
fi
rm -rf "$ENV_TMP"

# --- 57. Env-mode escapes special characters in string values ---
# Single quotes and backslashes must be escaped so the generated PHP
# parses correctly and round-trips the value byte-for-byte.
echo ""
echo "  --- 57. Env-mode escapes special characters ---"
ENV_TMP="$(mktemp -d)"
ENV_APP="$ENV_TMP/app"
ENV_BIN="$ENV_TMP/bin"
mkdir -p "$ENV_APP/data" "$ENV_BIN"
make_entrypoint_mocks "$ENV_BIN" "$ENV_APP"
TRICKY_PASS="p'a\"ss\\with\$special'chars"
env -i \
    PATH="$ENV_BIN:$PATH" \
    APP_DIR="$ENV_APP" \
    CUSTOMERNR=1 APIKEY=k APIPASSWORD="$TRICKY_PASS" DOMAINLIST="a.com: @" \
    sh "$PROJECT_DIR/docker-entrypoint.sh" --quiet > /dev/null 2>&1
if php -l "$ENV_APP/config.php" > /dev/null 2>&1; then
    pass "config with special chars parses as PHP"
else
    fail "config with special chars parses as PHP"
fi
recovered=$(php -r "require '$ENV_APP/config.php'; echo APIPASSWORD;" 2>/dev/null)
if [ "$recovered" = "$TRICKY_PASS" ]; then
    pass "special-character APIPASSWORD round-trips byte-for-byte"
else
    fail "special-character APIPASSWORD round-trips byte-for-byte (got '$recovered', expected '$TRICKY_PASS')"
fi
rm -rf "$ENV_TMP"

# --- 58. Env-mode applies optional URL/numeric overrides ---
echo ""
echo "  --- 58. Env-mode applies optional overrides ---"
ENV_TMP="$(mktemp -d)"
ENV_APP="$ENV_TMP/app"
ENV_BIN="$ENV_TMP/bin"
mkdir -p "$ENV_APP/data" "$ENV_BIN"
make_entrypoint_mocks "$ENV_BIN" "$ENV_APP"
env -i \
    PATH="$ENV_BIN:$PATH" \
    APP_DIR="$ENV_APP" \
    CUSTOMERNR=1 APIKEY=k APIPASSWORD=p DOMAINLIST="a.com: @" \
    USE_IPV6=true \
    APIURL="https://api.example.com/dns" \
    IPV4_ADDRESS_URL="https://ip4.example.com" \
    IPV4_ADDRESS_URL_FALLBACK="https://ip4-fallback.example.com" \
    IPV6_ADDRESS_URL="https://ip6.example.com" \
    IPV6_ADDRESS_URL_FALLBACK="https://ip6-fallback.example.com" \
    RETRY_SLEEP=15 JITTER_MAX=7 \
    sh "$PROJECT_DIR/docker-entrypoint.sh" --quiet > /dev/null 2>&1
overrides=$(php -r "require '$ENV_APP/config.php'; echo APIURL.'|'.IPV4_ADDRESS_URL.'|'.IPV4_ADDRESS_URL_FALLBACK.'|'.IPV6_ADDRESS_URL.'|'.IPV6_ADDRESS_URL_FALLBACK.'|'.RETRY_SLEEP.'|'.JITTER_MAX;" 2>/dev/null)
expected="https://api.example.com/dns|https://ip4.example.com|https://ip4-fallback.example.com|https://ip6.example.com|https://ip6-fallback.example.com|15|7"
if [ "$overrides" = "$expected" ]; then
    pass "all optional overrides applied to generated config"
else
    fail "all optional overrides applied to generated config (got '$overrides')"
fi
# Verify numeric values are emitted as integers, not strings.
numeric_types=$(php -r "require '$ENV_APP/config.php'; echo gettype(RETRY_SLEEP).'|'.gettype(JITTER_MAX);" 2>/dev/null)
if [ "$numeric_types" = "integer|integer" ]; then
    pass "numeric overrides typed as PHP integers"
else
    fail "numeric overrides typed as PHP integers (got '$numeric_types')"
fi
rm -rf "$ENV_TMP"

# --- 59. Env-mode omits unset optional values from generated config ---
# Optional defines that aren't provided should be left out so update.php
# can apply its own defaults via the !defined() guards.
echo ""
echo "  --- 59. Env-mode omits unset optional values ---"
ENV_TMP="$(mktemp -d)"
ENV_APP="$ENV_TMP/app"
ENV_BIN="$ENV_TMP/bin"
mkdir -p "$ENV_APP/data" "$ENV_BIN"
make_entrypoint_mocks "$ENV_BIN" "$ENV_APP"
env -i \
    PATH="$ENV_BIN:$PATH" \
    APP_DIR="$ENV_APP" \
    CUSTOMERNR=1 APIKEY=k APIPASSWORD=p DOMAINLIST="a.com: @" \
    sh "$PROJECT_DIR/docker-entrypoint.sh" --quiet > /dev/null 2>&1
for opt in IPV4_ADDRESS_URL IPV4_ADDRESS_URL_FALLBACK IPV6_ADDRESS_URL IPV6_ADDRESS_URL_FALLBACK RETRY_SLEEP JITTER_MAX; do
    if grep -qF "define('$opt'" "$ENV_APP/config.php"; then
        fail "$opt should be omitted when not provided"
    else
        pass "$opt omitted from generated config when not provided"
    fi
done
rm -rf "$ENV_TMP"

# --- 60. Env-mode mounted config.php takes precedence over env vars ---
# Regression guard: existing users mounting their own config.php must
# not have it overwritten when env vars are also set.
echo ""
echo "  --- 60. Env-mode preserves mounted config.php ---"
ENV_TMP="$(mktemp -d)"
ENV_APP="$ENV_TMP/app"
ENV_BIN="$ENV_TMP/bin"
mkdir -p "$ENV_APP/data" "$ENV_BIN"
make_entrypoint_mocks "$ENV_BIN" "$ENV_APP"
USER_CONFIG_MARKER="<?php /* user-supplied config — must not be overwritten */"
printf '%s\n' "$USER_CONFIG_MARKER" > "$ENV_APP/config.php"
env_output=$(
    env \
        PATH="$ENV_BIN:$PATH" \
        APP_DIR="$ENV_APP" \
        CUSTOMERNR="should-be-ignored" \
        APIKEY="should-be-ignored" \
        APIPASSWORD="should-be-ignored" \
        DOMAINLIST="should-be-ignored" \
        sh "$PROJECT_DIR/docker-entrypoint.sh" --quiet 2>&1
) && env_status=$? || env_status=$?
if [ "$env_status" -eq 0 ]; then
    pass "mounted-config entrypoint exits 0"
else
    fail "mounted-config entrypoint exits 0 (got $env_status)"
fi
if [ "$(cat "$ENV_APP/config.php")" = "$USER_CONFIG_MARKER" ]; then
    pass "mounted config.php is preserved verbatim"
else
    fail "mounted config.php is preserved verbatim"
fi
if echo "$env_output" | grep -qF "Loading config from $ENV_APP/config.php"; then
    pass "entrypoint announces it loaded the mounted config"
else
    fail "entrypoint announces it loaded the mounted config"
fi
if echo "$env_output" | grep -qF "Loading config from environment variables"; then
    fail "env-mode generation should be skipped when config.php is mounted"
else
    pass "env-mode generation is skipped when config.php is mounted"
fi
rm -rf "$ENV_TMP"

# --- 61. Env-mode wrapper config still sets CACHE_FILE in $DATA_DIR ---
# The wrapper config (config.docker.php) should always default CACHE_FILE
# to $APP_DIR/data/cache.json, regardless of which mode generated config.php.
echo ""
echo "  --- 61. Env-mode wrapper config sets CACHE_FILE ---"
ENV_TMP="$(mktemp -d)"
ENV_APP="$ENV_TMP/app"
ENV_BIN="$ENV_TMP/bin"
mkdir -p "$ENV_APP/data" "$ENV_BIN"
make_entrypoint_mocks "$ENV_BIN" "$ENV_APP"
env -i \
    PATH="$ENV_BIN:$PATH" \
    APP_DIR="$ENV_APP" \
    CUSTOMERNR=1 APIKEY=k APIPASSWORD=p DOMAINLIST="a.com: @" \
    sh "$PROJECT_DIR/docker-entrypoint.sh" --quiet > /dev/null 2>&1
if [ -f "$ENV_APP/config.docker.php" ]; then
    pass "env-mode generates config.docker.php wrapper"
else
    fail "env-mode generates config.docker.php wrapper"
fi
cache_file=$(php -r "require '$ENV_APP/config.docker.php'; echo CACHE_FILE;" 2>/dev/null)
if [ "$cache_file" = "$ENV_APP/data/cache.json" ]; then
    pass "wrapper sets CACHE_FILE to data dir for env-mode configs"
else
    fail "wrapper sets CACHE_FILE to data dir (got '$cache_file')"
fi
rm -rf "$ENV_TMP"

# --- 62. Env-mode wrapper escapes APP_DIR before interpolating into PHP ---
# Regression guard for the "$APP_DIR contains a single quote" RCE: the
# wrapper config must inline $CONFIG_PATH and $DATA_DIR through
# escape_php_single, otherwise a malicious APP_DIR breaks out of the PHP
# string and runs arbitrary code on every config load.
echo ""
echo "  --- 62. Env-mode wrapper escapes APP_DIR ---"
ENV_TMP="$(mktemp -d)"
EVIL_APP="$ENV_TMP/x'.system('touch $ENV_TMP/PWNED').'"
mkdir -p "$EVIL_APP/data"
ENV_BIN="$ENV_TMP/bin"
mkdir -p "$ENV_BIN"
make_entrypoint_mocks "$ENV_BIN" "$EVIL_APP"
env -i \
    PATH="$ENV_BIN:$PATH" \
    APP_DIR="$EVIL_APP" \
    CUSTOMERNR=1 APIKEY=k APIPASSWORD=p DOMAINLIST="a.com: @" \
    sh "$PROJECT_DIR/docker-entrypoint.sh" --quiet > /dev/null 2>&1
if php -l "$EVIL_APP/config.docker.php" > /dev/null 2>&1; then
    pass "wrapper with hostile APP_DIR has valid syntax"
else
    fail "wrapper with hostile APP_DIR has valid syntax"
fi
# Loading the wrapper must NOT execute the injected system() call. The
# require itself will fail (file is missing inside the literal path), but
# that's expected — what matters is no side effect ran.
php -d error_reporting=0 -r 'try { require $argv[1]; } catch (\Throwable $e) { /* ignore */ }' "$EVIL_APP/config.docker.php" 2>/dev/null || true
if [ ! -e "$ENV_TMP/PWNED" ]; then
    pass "loading wrapper with hostile APP_DIR did not execute injected payload"
else
    fail "loading wrapper with hostile APP_DIR executed the injected payload"
fi
# CACHE_FILE should be the literal hostile path, proving the value flowed
# through as a string instead of being interpreted as PHP.
cache_file=$(php -r 'require $argv[1]; echo CACHE_FILE;' "$EVIL_APP/config.docker.php" 2>/dev/null || true)
if [ "$cache_file" = "$EVIL_APP/data/cache.json" ]; then
    pass "hostile APP_DIR survives as a literal CACHE_FILE path"
else
    fail "hostile APP_DIR survives as a literal CACHE_FILE path (got '$cache_file')"
fi
rm -rf "$ENV_TMP"

# --- 63. Env-mode error messages do not echo offending values ---
# Misplaced credentials (e.g. APIPASSWORD pasted into USE_IPV4 by mistake)
# must not land in `docker logs` via the validation error message.
echo ""
echo "  --- 63. Env-mode error messages redact values ---"
ENV_TMP="$(mktemp -d)"
ENV_APP="$ENV_TMP/app"
ENV_BIN="$ENV_TMP/bin"
mkdir -p "$ENV_APP/data" "$ENV_BIN"
make_entrypoint_mocks "$ENV_BIN" "$ENV_APP"
SECRET_TOKEN="hunter2-do-not-leak-$(date +%s%N)"
for var in USE_IPV4 USE_IPV6 CHANGE_TTL RETRY_SLEEP JITTER_MAX; do
    env_output=$(
        env -i \
            PATH="$ENV_BIN:$PATH" \
            APP_DIR="$ENV_APP" \
            CUSTOMERNR=1 APIKEY=k APIPASSWORD=p DOMAINLIST="a.com: @" \
            "$var=$SECRET_TOKEN" \
            sh "$PROJECT_DIR/docker-entrypoint.sh" 2>&1
    ) && env_status=$? || env_status=$?
    if [ "$env_status" -eq 1 ] && ! echo "$env_output" | grep -qF "$SECRET_TOKEN"; then
        pass "$var validation error does not echo the offending value"
    else
        fail "$var validation error leaked the value (status=$env_status; output=$env_output)"
    fi
done
rm -rf "$ENV_TMP"

# Helper: drives the entrypoint with mock binaries so we can inspect the
# crontab text it installs and the file modes it leaves behind.
# Sets $ENTRYPOINT_TMP, $ENTRYPOINT_APP, $ENTRYPOINT_CRONTAB,
# $ENTRYPOINT_LOG. Caller is responsible for `rm -rf "$ENTRYPOINT_TMP"`.
prepare_entrypoint_run() {
    ENTRYPOINT_TMP="$(mktemp -d)"
    ENTRYPOINT_APP="$ENTRYPOINT_TMP/app"
    ENTRYPOINT_BIN="$ENTRYPOINT_TMP/bin"
    ENTRYPOINT_LOG="$ENTRYPOINT_TMP/log.txt"
    ENTRYPOINT_CRONTAB="$ENTRYPOINT_TMP/crontab.txt"
    ENTRYPOINT_HEARTBEAT="$ENTRYPOINT_APP/data/last_success.json"
    mkdir -p "$ENTRYPOINT_APP/data" "$ENTRYPOINT_BIN"
    cat > "$ENTRYPOINT_BIN/php" <<EOF
#!/bin/sh
echo "php \$*" >> "$ENTRYPOINT_LOG"
if [ "\$1" = "$ENTRYPOINT_APP/healthcheck.php" ] && [ "\$2" = "--mark-success" ]; then
    echo '{"timestamp":1}' > "$ENTRYPOINT_HEARTBEAT"
fi
exit 0
EOF
    cat > "$ENTRYPOINT_BIN/crontab" <<EOF
#!/bin/sh
cat > "$ENTRYPOINT_CRONTAB"
exit 0
EOF
    cat > "$ENTRYPOINT_BIN/crond" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "$ENTRYPOINT_BIN/php" "$ENTRYPOINT_BIN/crontab" "$ENTRYPOINT_BIN/crond"
}

# --- 64. docker-compose.yml is valid YAML, including the env-var alternative ---
# Regression guard for the issue where unquoted DOMAINLIST=... made the
# alternative example unparseable. We test both the shipped form and the
# form with all alternative env vars uncommented.
echo ""
echo "  --- 64. docker-compose.yml parses cleanly ---"
if ! command -v docker &>/dev/null || ! docker compose version >/dev/null 2>&1; then
    skip "docker compose not available"
else
    if docker compose -f "$PROJECT_DIR/docker-compose.yml" config > /dev/null 2>&1; then
        pass "shipped docker-compose.yml parses"
    else
        fail "shipped docker-compose.yml parses"
    fi
    # Same file with the env-var alternative uncommented (and the config.php
    # bind-mount removed, since the user is opting into env mode).
    COMPOSE_TMP="$(mktemp -d)"
    sed -e 's/^      # - /      - /' \
        -e '/- "\.\/config\.php/d' \
        "$PROJECT_DIR/docker-compose.yml" > "$COMPOSE_TMP/docker-compose.yml"
    if docker compose -f "$COMPOSE_TMP/docker-compose.yml" config > /dev/null 2>&1; then
        pass "docker-compose.yml with env-var alternative uncommented parses"
    else
        fail "docker-compose.yml with env-var alternative uncommented parses"
    fi
    rm -rf "$COMPOSE_TMP"
fi

# --- 65. TZ env var is forwarded into the cron command ---
# Busybox crond doesn't propagate the parent shell's env to scheduled
# jobs, so without explicit forwarding TZ silently reverts to UTC for
# both update.php's log timestamps and the heartbeat JSON.
echo ""
echo "  --- 65. Cron command forwards TZ ---"
prepare_entrypoint_run
env -i \
    PATH="$ENTRYPOINT_BIN:$PATH" \
    APP_DIR="$ENTRYPOINT_APP" \
    CRON_SCHEDULE="*/2 * * * *" \
    TZ="Europe/Berlin" \
    CUSTOMERNR=1 APIKEY=k APIPASSWORD=p DOMAINLIST="a.com: @" \
    sh "$PROJECT_DIR/docker-entrypoint.sh" --quiet > /dev/null 2>&1
if grep -qF -- "TZ='Europe/Berlin' php $ENTRYPOINT_APP/update.php" "$ENTRYPOINT_CRONTAB"; then
    pass "TZ is prefixed before the cron-fired update.php"
else
    fail "TZ is prefixed before the cron-fired update.php (cron line: $(cat "$ENTRYPOINT_CRONTAB"))"
fi
if grep -qF -- "TZ='Europe/Berlin' php $ENTRYPOINT_APP/healthcheck.php --mark-success" "$ENTRYPOINT_CRONTAB"; then
    pass "TZ is prefixed before the cron-fired heartbeat write"
else
    fail "TZ is prefixed before the cron-fired heartbeat write"
fi
rm -rf "$ENTRYPOINT_TMP"

# Without TZ, no TZ= prefix should appear (avoid forwarding an empty TZ
# which would mean "unknown timezone" inside PHP).
prepare_entrypoint_run
env -i \
    PATH="$ENTRYPOINT_BIN:$PATH" \
    APP_DIR="$ENTRYPOINT_APP" \
    CRON_SCHEDULE="*/2 * * * *" \
    CUSTOMERNR=1 APIKEY=k APIPASSWORD=p DOMAINLIST="a.com: @" \
    sh "$PROJECT_DIR/docker-entrypoint.sh" --quiet > /dev/null 2>&1
if grep -qF "TZ=" "$ENTRYPOINT_CRONTAB"; then
    fail "no TZ env should mean no TZ= prefix in cron line"
else
    pass "no TZ env means no TZ= prefix in cron line"
fi
rm -rf "$ENTRYPOINT_TMP"

# --- 66. Args with embedded spaces survive the cron command ---
# Regression guard for the $ARGS = "$ARGS $arg" word-splitting bug. A
# multi-word arg used to flatten and re-split on whitespace, losing
# argument boundaries.
echo ""
echo "  --- 66. Cron command preserves multi-word args ---"
prepare_entrypoint_run
env -i \
    PATH="$ENTRYPOINT_BIN:$PATH" \
    APP_DIR="$ENTRYPOINT_APP" \
    CUSTOMERNR=1 APIKEY=k APIPASSWORD=p DOMAINLIST="a.com: @" \
    sh "$PROJECT_DIR/docker-entrypoint.sh" --note "hello world" --quiet > /dev/null 2>&1
if grep -qF -- "'--note' 'hello world' '--quiet'" "$ENTRYPOINT_CRONTAB"; then
    pass "multi-word arg stays single-quoted in the cron command"
else
    fail "multi-word arg stays single-quoted (cron line: $(cat "$ENTRYPOINT_CRONTAB"))"
fi
# Single-quote in arg should be escaped via the standard '\'' trick so
# the cron line round-trips through /bin/sh -c without re-splitting.
prepare_entrypoint_run
env -i \
    PATH="$ENTRYPOINT_BIN:$PATH" \
    APP_DIR="$ENTRYPOINT_APP" \
    CUSTOMERNR=1 APIKEY=k APIPASSWORD=p DOMAINLIST="a.com: @" \
    sh "$PROJECT_DIR/docker-entrypoint.sh" "--note=O'Brien" > /dev/null 2>&1
if grep -qF -- "'--note=O'\\''Brien'" "$ENTRYPOINT_CRONTAB"; then
    pass "single quote inside arg is escaped via '\\'' for the cron command"
else
    fail "single quote inside arg is escaped (cron line: $(cat "$ENTRYPOINT_CRONTAB"))"
fi
rm -rf "$ENTRYPOINT_TMP"

# --- 67. Env-mode generated config files are mode 0600 ---
# Regression guard for the credentials-at-0644 finding: anyone later
# adding a non-root USER directive should inherit the secure default.
echo ""
echo "  --- 67. Env-mode config files restricted to 0600 ---"
prepare_entrypoint_run
env -i \
    PATH="$ENTRYPOINT_BIN:$PATH" \
    APP_DIR="$ENTRYPOINT_APP" \
    CUSTOMERNR=1 APIKEY=k APIPASSWORD=p DOMAINLIST="a.com: @" \
    sh "$PROJECT_DIR/docker-entrypoint.sh" --quiet > /dev/null 2>&1
config_mode=$(stat -c '%a' "$ENTRYPOINT_APP/config.php" 2>/dev/null)
docker_mode=$(stat -c '%a' "$ENTRYPOINT_APP/config.docker.php" 2>/dev/null)
if [ "$config_mode" = "600" ]; then
    pass "generated config.php is mode 0600"
else
    fail "generated config.php is mode 0600 (got '$config_mode')"
fi
if [ "$docker_mode" = "600" ]; then
    pass "generated config.docker.php is mode 0600"
else
    fail "generated config.docker.php is mode 0600 (got '$docker_mode')"
fi
rm -rf "$ENTRYPOINT_TMP"

# Mounted config.php should NOT have its permissions changed by the
# entrypoint — that's the user's file, not ours.
prepare_entrypoint_run
echo "<?php" > "$ENTRYPOINT_APP/config.php"
chmod 0644 "$ENTRYPOINT_APP/config.php"
env -i \
    PATH="$ENTRYPOINT_BIN:$PATH" \
    APP_DIR="$ENTRYPOINT_APP" \
    sh "$PROJECT_DIR/docker-entrypoint.sh" --quiet > /dev/null 2>&1
mounted_mode=$(stat -c '%a' "$ENTRYPOINT_APP/config.php" 2>/dev/null)
if [ "$mounted_mode" = "644" ]; then
    pass "mounted config.php's mode is left untouched"
else
    fail "mounted config.php's mode is left untouched (got '$mounted_mode')"
fi
rm -rf "$ENTRYPOINT_TMP"

# ===========================================================================
# RESULTS
# ===========================================================================

echo ""
echo "============================================="
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
echo "============================================="

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
