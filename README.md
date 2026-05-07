# Dynamic DNS client for netcup DNS API
*This project is not affiliated with the company netcup GmbH. Although it is developed by an employee, it is not an official client by netcup GmbH and was developed in my free time.*
*netcup is a registered trademark of netcup GmbH, Karlsruhe, Germany.*

**A simple dynamic DNS client written in PHP for use with the netcup DNS API.**

## Requirements
* Be a netcup customer: https://www.netcup.de – or for international customers: https://www.netcup.eu
  * You don't have to be a domain reseller to use the necessary functions for this client – every customer with a domain may use it.
* netcup API key and API password, which can be created within your CCP at https://www.customercontrolpanel.de
* PHP-CLI with CURL extension
* A domain :wink:

## Features
### Implemented
* All necessary API functions for DNS actions implemented (REST API)
* Determines correct public IP address, uses fallback API for determining the IP address, in case main API does return invalid / no IP
* Forces correct IP version (IPv4/IPv6) when connecting to IP address lookup services, preventing issues with dual-stack servers
* Automatically retries API requests on errors
* IPv4 and IPv6 Support (can be individually enabled / disabled)
* Possible to manually provide IPv4 / IPv6 address to set as a CLI option
* Update everything you want in one go: Every combination of domains, subdomains, domain root, and domain wildcard is possible
* Creation of DNS record, if it doesn't already exist
* If configured, lowers TTL to 300 seconds for the domain on each run, if necessary
* Caching: After a successful run, the current IP is cached locally. On subsequent runs, the DNS API is skipped entirely if the IP hasn't changed. Use `--force` to bypass the cache.
* Jitter: A random delay (1–30 seconds by default) is applied before API calls to spread load when many users run the script via cron at the same time. Configurable via `JITTER_MAX` in config.
* Hiding output (quiet option)

## Getting started
### Option 1: Direct (PHP)
#### Requirements
* PHP-CLI with CURL extension

#### Download
Download the [latest version](https://github.com/stecklars/dynamic-dns-netcup-api/releases/latest) from the releases or clone the repository:

`$ git clone https://github.com/stecklars/dynamic-dns-netcup-api.git`

I'm always trying to keep the master branch stable.

Then, allow `update.php` to be executed by your user:

`chmod u+x update.php`

#### Configuration
* Copy `config.dist.php` to `config.php`
  * `cp config.dist.php config.php`
* Fill out `config.php` with the required values. The options are explained in there.

#### How to use
`./update.php`

You should probably run this script every few minutes, so that your IP is updated as quickly as possible. Add it to your cronjobs and run it regularly, for example every five minutes.

### Option 2: Docker
A Docker image is available for systems without PHP, such as NAS devices. The image is built for **linux/amd64**, **linux/arm64**, and **linux/arm/v7** (e.g. Raspberry Pi, NAS devices). It includes PHP, cURL, and a built-in scheduler — no additional setup required.

You can configure the container either by **mounting a `config.php`** (steps below) or by **passing environment variables** ([details](#configuration-via-environment-variables)). Pick whichever fits your workflow — the file mount takes precedence if both are present.

Create your `config.php` first — use [`config.dist.php`](https://github.com/stecklars/dynamic-dns-netcup-api/blob/master/config.dist.php) as a template. Before starting the container in cron mode, verify your config works:

```bash
docker run --rm -v ./config.php:/app/config.php:ro stecklars/dynamic-dns-netcup-api --run-once
```

If this runs successfully, proceed with the instructions for your platform below. If it fails, the error message will tell you what to fix. If the container exits immediately after starting in cron mode, check `docker logs dyndns` for the error.

#### Container environment variables

| Variable        | Default         | Description                              |
| --------------- | --------------- | ---------------------------------------- |
| CRON_SCHEDULE   | `*/5 * * * *`   | How often to check for IP changes        |
| TZ              | UTC             | Timezone for the schedule and log output |
| HEALTHCHECK_GRACE_SECONDS | `JITTER_MAX + 120` | Extra grace after the next scheduled run before the container becomes unhealthy |

(See [Configuration via environment variables](#configuration-via-environment-variables) for the env vars that replace `config.php`.)

#### Volume mounts

| Container path   | Description                          |
| ---------------- | ------------------------------------ |
| `/app/config.php` | Your configuration file (read-only). Optional when [configuring via environment variables](#configuration-via-environment-variables). |
| `/app/data`       | Persistent IP cache (empty dir, created automatically) |

#### NAS (Synology, QNAP, Unraid)
1. Search for `stecklars/dynamic-dns-netcup-api` in your NAS Docker GUI and download the image
2. Create a container with the volume mounts and environment variables described above
3. Set the restart policy to "always" or "unless stopped" so it survives reboots
4. Start the container — it runs the script immediately and then on the configured schedule

#### Command line
The image is pulled from Docker Hub automatically — no need to clone the repository:

```bash
docker run -d --name dyndns \
  -v ./config.php:/app/config.php:ro \
  -v dyndns-data:/app/data \
  -e CRON_SCHEDULE="*/5 * * * *" \
  -e TZ=Europe/Berlin \
  --restart unless-stopped \
  stecklars/dynamic-dns-netcup-api
```

#### Docker compose
If you have cloned the repository, you can use docker compose instead:

`docker compose up -d`

#### One-shot mode
To run the script once instead of starting the scheduler (e.g., to test your config):

```bash
docker run --rm -v ./config.php:/app/config.php:ro stecklars/dynamic-dns-netcup-api --run-once
```

One-shot mode is meant for testing and manual runs — for regular use, use the cron mode (the default) which handles scheduling, caching, and jitter automatically.

Script flags like `--force` and `--quiet` can be used in both modes, e.g.:

```bash
docker run --rm -v ./config.php:/app/config.php:ro stecklars/dynamic-dns-netcup-api --run-once --force
```

#### Configuration via environment variables
If you'd rather not mount a `config.php`, you can pass every setting as an environment variable instead — convenient when secrets come from your orchestrator (`docker run --env-file`, Docker secrets, Kubernetes ConfigMaps, etc.). On startup the entrypoint generates `config.php` from the env vars.

```bash
docker run -d --name dyndns \
  -e CUSTOMERNR=12345 \
  -e APIKEY=your-api-key \
  -e APIPASSWORD=your-api-password \
  -e DOMAINLIST="example.com: @, www; second.tld: mail" \
  -e USE_IPV4=true \
  -e USE_IPV6=false \
  -e CHANGE_TTL=true \
  -v dyndns-data:/app/data \
  --restart unless-stopped \
  stecklars/dynamic-dns-netcup-api
```

| Variable                       | Required | Default                       | Description                                                |
| ------------------------------ | -------- | ----------------------------- | ---------------------------------------------------------- |
| CUSTOMERNR                     | yes      | —                             | netcup customer number                                     |
| APIKEY                         | yes      | —                             | netcup API key                                             |
| APIPASSWORD                    | yes      | —                             | netcup API password                                        |
| DOMAINLIST                     | yes      | —                             | Domain configuration (see [`config.dist.php`](https://github.com/stecklars/dynamic-dns-netcup-api/blob/master/config.dist.php) for the format) |
| USE_IPV4                       | no       | `true`                        | Update A records                                           |
| USE_IPV6                       | no       | `false`                       | Update AAAA records                                        |
| CHANGE_TTL                     | no       | `true`                        | Lower TTL to 300 seconds on each run                       |
| APIURL                         | no       | `https://ccp.netcup.net/run/webservice/servers/endpoint.php?JSON` | Override the netcup API endpoint |
| IPV4_ADDRESS_URL               | no       | `https://get-ipv4.steck.cc`   | Primary IPv4 lookup URL                                    |
| IPV4_ADDRESS_URL_FALLBACK      | no       | `https://ipv4.seeip.org`      | Fallback IPv4 lookup URL                                   |
| IPV6_ADDRESS_URL               | no       | `https://get-ipv6.steck.cc`   | Primary IPv6 lookup URL                                    |
| IPV6_ADDRESS_URL_FALLBACK      | no       | `https://v6.ident.me`         | Fallback IPv6 lookup URL                                   |
| RETRY_SLEEP                    | no       | `30`                          | Seconds to wait between retries                            |
| JITTER_MAX                     | no       | `30`                          | Max random delay before API calls (`0` to disable)         |

Booleans accept `true` / `false` / `1` / `0` / `yes` / `no` / `on` / `off` (case-insensitive). Verify your env-var configuration in one-shot mode before going into cron mode:

```bash
docker run --rm \
  -e CUSTOMERNR=12345 -e APIKEY=... -e APIPASSWORD=... \
  -e DOMAINLIST="example.com: @" \
  stecklars/dynamic-dns-netcup-api --run-once
```

`--run-once` exercises the env-var → `config.php` conversion and a single update; it does **not** start `crond` or validate `CRON_SCHEDULE`. If `--run-once` is happy, cron mode usually is too — but the easiest way to confirm is to start the container in cron mode and watch `docker logs`.

If a `config.php` is mounted at `/app/config.php`, it always takes precedence and these env vars are ignored.

#### Viewing logs
```bash
docker logs dyndns                  # show all logs
docker logs -f dyndns               # follow logs in real-time
docker logs --tail 20 dyndns        # show last 20 lines
```

In docker compose, use `docker compose logs -f`.

#### Container health
The image defines a Docker `HEALTHCHECK`. It does not run `update.php` again; instead it checks whether the last successful run is still fresh relative to `CRON_SCHEDULE`.

This means irregular schedules are handled correctly. For example, a schedule like `0 3 * * 1-5` stays healthy over the weekend and only turns unhealthy after a weekday run is overdue. The default grace period is `JITTER_MAX + 120` seconds and can be overridden with `HEALTHCHECK_GRACE_SECONDS`.

#### Docker notes
* **"Permission denied" errors on Fedora, RHEL, or openSUSE**: These systems use SELinux, which blocks container access to mounted files even if file permissions look correct. Fix this by adding the `:z` flag to all volume mounts, e.g., `-v ./config.php:/app/config.php:ro,z -v dyndns-data:/app/data:z`. This does not affect NAS systems.
* **IPv6**: Docker's default bridge network does not support IPv6. If you use `USE_IPV6=true`, run the container with `--network host` or configure Docker's IPv6 support.

### CLI options
Just add these Options after the command like `./update.php --quiet`

| short option | long option        | function                                                  |
| ------------ | ------------------ |----------------------------------------------------------:|
| -q           | --quiet            | The script won't output notices or warnings, only errors  |
| -c           | --config           | Manually provide a path to the config file                |
| -4           | --ipv4             | Manually provide the IPv4 address to set                  |
| -6           | --ipv6             | Manually provide the IPv6 address to set                  |
| -f           | --force            | Force update, bypassing the IP cache                      |
| -h           | --help             | Outputs this help                                         |
| -v           | --version          | Outputs the current version of the script                 |

## Testing
A test suite is included in the `tests/` directory that validates the script's functionality using a mock HTTP server.

### Requirements for running tests
* Bash
* PHP-CLI (unit tests work without cURL; integration tests require the cURL extension)
* Python 3 (for the mock HTTP server)

### Running the tests
`./tests/test.sh`

The test suite covers CLI options, IP validation, domain parsing, and full end-to-end update flows including caching, jitter, TTL management, error handling, and IPv4/IPv6 support.

If you have ideas on how to improve this script, please don't hesitate to create an issue. Thank you!
