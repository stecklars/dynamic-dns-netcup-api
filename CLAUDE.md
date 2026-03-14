# CLAUDE.md

## Project overview

Dynamic DNS client for the netcup CCP DNS API, written in PHP. Updates A/AAAA DNS records with the current public IP address. Designed to run as a cron job.

## Architecture

Three source files, no framework, no dependencies beyond PHP-CLI with cURL:

- `update.php` — Entry point. Orchestrates the full flow: fetch IP → check cache → jitter → login → process domains → logout → write cache.
- `functions.php` — All functions (API wrappers, cURL handling, retry logic, IP fetching, output, CLI parsing) plus top-level CLI option parsing and config loading.
- `config.dist.php` — Template config with all options documented. Users copy to `config.php`.

## Key design decisions

- **No autoloading, no Composer, no classes.** The script is intentionally simple — a single `php update.php` invocation. Keep it that way.
- **Constants for config.** All config values are PHP `define()` constants. They cannot be redefined at runtime, which affects testing (each test case needing different constants requires a separate PHP process).
- **CLI parsing happens at include time** in `functions.php` (lines 8-70). This means `require`-ing `functions.php` in tests triggers `getopt()`, config loading, and potential `exit()` calls. Tests work around this by passing `-c <config>` and `-q` via CLI args to a `php` process reading from stdin.
- **Global variables** (`$quiet`, `$forceUpdate`, `$providedIPv4`, `$providedIPv6`, `$apisessionid`) are used for state. Functions access them via `global`.

## Testing

Run tests with `./test.sh`. Requires Bash, PHP-CLI, and Python 3.

- Unit tests (IP validation, domain parsing) work without cURL by loading `functions.php` with a dummy config via `php -- -c <config> -q`.
- Integration tests use `test_mock_server.py` — a Python HTTP server simulating both IP lookup services and the netcup API. It listens on dual-stack (IPv4+IPv6) and has 13 API endpoint variants for different scenarios.
- Test configs set `RETRY_SLEEP=0`, `JITTER_MAX=0`, and `CACHE_FILE=/dev/null` to avoid delays and side effects.
- Cache-specific tests use a temp file (`cache.test.json`) and compute the expected config fingerprint dynamically.

## Important patterns

- **Retry logic:** `executeCurlWithRetries()` handles API retries. `fetchIPWithFallback()` handles IP lookup retries with validation + fallback URL. Both use `RETRY_SLEEP` (default 30s) between attempts.
- **IP version forcing:** `CURL_IPRESOLVE_V4` / `CURL_IPRESOLVE_V6` is passed through `fetchIPWithFallback()` → `initializeCurlHandlerGetIP()` to prevent dual-stack servers from returning the wrong address type.
- **Cache invalidation:** The cache stores a config fingerprint (md5 of DOMAINLIST, USE_IPV4, USE_IPV6, CHANGE_TTL). Config changes automatically invalidate the cache.
- **Session expiry workaround:** The netcup API has a bug where sessions expire early (error 4001). `sendRequest()` catches this, re-logs in, and retries once.

## Common tasks

- **Adding a new config option:** Add `define()` in `config.dist.php` (documented), add `!defined()` default guard in `update.php`, add to `write_mock_config` in `test.sh` if it affects test behavior.
- **Adding a new API mock variant:** Add handler method in `test_mock_server.py`, add to the dispatch dict, write tests in `test.sh`.
- **Bumping version:** Change `const VERSION` in `functions.php` line 3. Update the version check in `test.sh` (search for the old version string).

**Important:** After any user-facing change (new feature, new CLI option, changed behavior), update `README.md` to match. Keep the CLI options table in `README.md` identical to the help text in `functions.php`. Update the feature list if applicable.

## Things to watch out for

- `functions.php` top-level code runs on include — don't `require` it without passing appropriate CLI args.
- PHP constants can't be redefined — tests needing different config values need separate PHP processes.
- The `CURLOPT_FAILONERROR` option is set on all cURL handles — HTTP errors (4xx/5xx) cause `curl_exec` to return `false`.
- `curl_close()` must be called on every code path. Check for handle leaks when modifying `sendRequest()` or `fetchIPWithFallback()`.
- Cache file writes use `file_put_contents` which is atomic for small writes on most filesystems, but there is no `flock()` — concurrent cron runs could theoretically produce a corrupted cache file (handled gracefully by treating invalid JSON as a cache miss).
