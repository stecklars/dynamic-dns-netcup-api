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
* Automatically retries API requests on errors
* IPv4 and IPv6 Support (can be individually enabled / disabled)
* Possible to manually provide IPv4 / IPv6 address to set as a CLI option
* Update everything you want in one go: Every combination of domains, subdomains, domain root, and domain wildcard is possible
* Creation of DNS record, if it doesn't already exist
* If configured, lowers TTL to 300 seconds for the domain on each run, if necessary
* Hiding output (quiet option)

### Missing
* Caching the IP provided to netcup DNS, to avoid running into (currently extremely tolerant) rate limits in the DNS API
* Probably a lot more :grin: – to be continued...

## Getting started
### Download
Download the [latest version](https://github.com/stecklars/dynamic-dns-netcup-api/releases/latest) from the releases or clone the repository:

`$ git clone https://github.com/stecklars/dynamic-dns-netcup-api.git`

I'm always trying to keep the master branch stable.

Then, allow `update.php` to be executed by your user:

`chmod u+x update.php`

### Configuration
Configuration is very simple: 
* Copy `config.dist.php` to `config.php`
  * `cp config.dist.php config.php`
* Fill out `config.php` with the required values. The options are explained in there.

### How to use
`./update.php`

You should probably run this script every few minutes, so that your IP is updated as quickly as possible. Add it to your cronjobs and run it regularly, for example every five minutes.

### CLI options
Just add these Options after the command like `./update.php --quiet`

| short option | long option        | function                                                  |
| ------------ | ------------------ |----------------------------------------------------------:|
| -q           | --quiet            | The script won't output notices, only errors and warnings |
| -c           | --config           | Manually provide a path to the config file                |
| -4           | --ipv4             | Manually provide the IPv4 address to set                  |
| -6           | --ipv6             | Manually provide the IPv6 address to set                  |
| -h           | --help             | Outputs this help                                         |
| -v           | --version          | Outputs the current version of the script                 |

If you have ideas on how to improve this script, please don't hesitate to create an issue. Thank you!
