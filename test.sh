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
#   14. Full update flow — multiple domains in one run
#   15. Full update flow — wildcard (*) and root (@) subdomains
#   16. Full update flow — manually provided IPv4
#   17. Full update flow — IPv4 + IPv6 combined
#   18. Full update flow — quiet mode
#   19. Full update flow — API login failure
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
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
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
require '$SCRIPT_DIR/functions.php';
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
require '$SCRIPT_DIR/functions.php';
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
    output=$(php "$SCRIPT_DIR/update.php" -c "$TEST_CONFIG" $extra_args 2>&1) && exit_code=$? || exit_code=$?
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


# ===========================================================================
# 1. SYNTAX CHECKS
# ===========================================================================

echo ""
echo "=== 1. Syntax checks ==="

# Verify both PHP files parse without syntax errors.
assert_exit_code "functions.php has valid syntax" 0 php -l "$SCRIPT_DIR/functions.php"
assert_exit_code "update.php has valid syntax" 0 php -l "$SCRIPT_DIR/update.php"

# ===========================================================================
# 2. CLI OPTIONS
# ===========================================================================

echo ""
echo "=== 2. CLI options ==="

# --version / -v should print the version string and exit cleanly.
assert_exit_code "--version exits 0" 0 php "$SCRIPT_DIR/update.php" --version
assert_output_contains "--version shows version number" "5.0" php "$SCRIPT_DIR/update.php" --version
assert_exit_code "-v exits 0" 0 php "$SCRIPT_DIR/update.php" -v

# --help / -h should print usage information and exit cleanly.
assert_exit_code "--help exits 0" 0 php "$SCRIPT_DIR/update.php" --help
assert_output_contains "--help shows options table" "--quiet" php "$SCRIPT_DIR/update.php" --help
assert_output_contains "--help shows force option" "--force" php "$SCRIPT_DIR/update.php" --help
assert_exit_code "-h exits 0" 0 php "$SCRIPT_DIR/update.php" -h

# ===========================================================================
# 3. INVALID IP ARGUMENTS
# ===========================================================================

echo ""
echo "=== 3. Invalid IP arguments ==="

# Providing an invalid IPv4 or IPv6 address via CLI should fail immediately
# with exit code 1, before any API calls are made.
assert_exit_code "-4 with garbage text exits 1" 1 php "$SCRIPT_DIR/update.php" -4 "not-an-ip"
assert_exit_code "-4 with out-of-range octets exits 1" 1 php "$SCRIPT_DIR/update.php" -4 "999.999.999.999"
assert_exit_code "-6 with garbage text exits 1" 1 php "$SCRIPT_DIR/update.php" -6 "not-an-ipv6"
assert_output_contains "-4 invalid shows error message" "is invalid. Exiting" php "$SCRIPT_DIR/update.php" -4 "bad"
assert_output_contains "-6 invalid shows error message" "is invalid. Exiting" php "$SCRIPT_DIR/update.php" -6 "bad"

# ===========================================================================
# 4. CONFIG LOADING
# ===========================================================================

echo ""
echo "=== 4. Config loading ==="

# A non-existent config path should fail with exit 1 and a helpful error.
assert_exit_code "missing config file exits 1" 1 php "$SCRIPT_DIR/update.php" -c "/nonexistent/config.php"
assert_output_contains "missing config shows error" "Could not open config.php" \
    php "$SCRIPT_DIR/update.php" -c "/nonexistent/config.php"

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
require '$SCRIPT_DIR/functions.php';
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
require '$SCRIPT_DIR/functions.php';
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
# 8-36. FULL UPDATE FLOW (mock HTTP server)
# ===========================================================================

echo ""
echo "=== 8-36. Full update flow (mock server) ==="

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
# Write a cache file with the same IP as the mock returns, then run.
# The script should detect no change and exit without logging in.
echo ""
echo "  --- 39. Cache hit (skips API) ---"
CACHE_TMP="$SCRIPT_DIR/cache.test.json"
echo '{"ipv4":"203.0.113.42"}' > "$CACHE_TMP"
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
echo '{"ipv4":"1.2.3.4"}' > "$CACHE_TMP"
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
echo '{"ipv4":"203.0.113.42"}' > "$CACHE_TMP"
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

fi  # end of cURL/python3 availability check

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
