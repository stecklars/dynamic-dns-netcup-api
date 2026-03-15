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
A Docker image is available for systems without PHP, such as NAS devices. The image includes PHP, cURL, and a built-in scheduler — no additional setup required. You only need to provide your `config.php`.

Create your `config.php` first (see Configuration above), then follow the instructions for your platform below.

#### Environment variables

| Variable        | Default         | Description                              |
| --------------- | --------------- | ---------------------------------------- |
| CRON_SCHEDULE   | `*/5 * * * *`   | How often to check for IP changes        |
| TZ              | UTC             | Timezone for the schedule and log output |

#### Volume mounts

| Container path   | Description                          |
| ---------------- | ------------------------------------ |
| `/app/config.php` | Your configuration file (read-only) |
| `/app/data`       | Persistent IP cache                 |

#### NAS (Synology, QNAP, Unraid)
1. Search for `stecklars/dynamic-dns-netcup-api` in your NAS Docker GUI and download the image
2. Create a container with the volume mounts and environment variables described above
3. Set the restart policy to "always" or "unless stopped" so it survives reboots
4. Start the container — it runs the script immediately and then on the configured schedule

#### Command line
```bash
docker run -d \
  -v ./config.php:/app/config.php:ro \
  -v dyndns-data:/app/data \
  -e CRON_SCHEDULE="*/5 * * * *" \
  -e TZ=Europe/Berlin \
  --restart unless-stopped \
  stecklars/dynamic-dns-netcup-api
```

Or using docker compose:
1. Clone the repository
2. Create your `config.php`
3. Run `docker compose up -d`

#### One-shot mode
To run the script once instead of starting the scheduler (e.g., to test your config or force an update):

```bash
docker run --rm -v ./config.php:/app/config.php:ro stecklars/dynamic-dns-netcup-api --force
```

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
A test suite is included (`test.sh`) that validates the script's functionality using a mock HTTP server (`test_mock_server.py`).

### Requirements for running tests
* Bash
* PHP-CLI (unit tests work without cURL; integration tests require the cURL extension)
* Python 3 (for the mock HTTP server)

### Running the tests
`./test.sh`

The test suite covers CLI options, IP validation, domain parsing, and full end-to-end update flows including caching, jitter, TTL management, error handling, and IPv4/IPv6 support.

If you have ideas on how to improve this script, please don't hesitate to create an issue. Thank you!
