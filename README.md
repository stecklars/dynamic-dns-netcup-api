# Dynamic DNS client for netcup DNS API
*This project is not affiliated with the company netcup GmbH. Although it is developed by an employee, it is not an official client by netcup GmbH and was developed in my free time.*
*netcup is a registered trademark of netcup GmbH, Karlsruhe, Germany.*

**A simple dynamic DNS client written in PHP for use with the netcup DNS API.**

## Requirements
* Be a netcup customer: https://www.netcup.de – or for international customers: https://www.netcup.eu
  * You don't have to be a domain reseller to use the necessary functions for this client – every customer with a domain may use it.
* netcup API key and API password, which can be created within your CCP at https://ccp.netcup.net
* PHP-CLI with CURL extension
* A domain :wink:

## Features
### Implemented
* All necessary API functions for DNS actions implemented (REST API)
* Determines correct public IP address, uses fallback API for determining the IP address, in case main API does return invalid / no IP
* Updating of a specific subdomain, domain root, or subdomain
* Creation of DNS record, if it doesn't already exist
* If configured, lowers TTL to 300 seconds for the domain on each run, if necessary
* Hiding output (quiet option)

### Missing
* Support for domain root and wildcard / specific subdomains at the same time
* Caching the IP provided to netcup DNS, to avoid running into (currently not existing) rate limits in the DNS API
* IPv6 Support
* Probably a lot more :grin: – to be continued...

## Getting started
### Configuration
Configuration is very simple: Just fill out `config.php` with the required values.

### How to use
`php update.php`

You should probably run this script every few minutes, so that your IP is updated as quickly as possible. Add it to your cronjobs and run it regularly, for example every five minutes.

### CLI options
Just add these Options after the command like `php update.php --quiet`

| option        | function                                             |
| ------------- |-----------------------------------------------------:|
| --quiet       | The script won't output normal messages, only errors |

## Example output
```
$ php update.php
[2018/06/10 01:16:28 +0200][NOTICE] =============================================
[2018/06/10 01:16:28 +0200][NOTICE] Running dynamic DNS client for netcup 1.0
[2018/06/10 01:16:28 +0200][NOTICE] This script is not affiliated with netcup.
[2018/06/10 01:16:28 +0200][NOTICE] =============================================

[2018/06/10 01:16:28 +0200][NOTICE] Logged in successfully!
[2018/06/10 01:16:29 +0200][NOTICE] Successfully received Domain info.
[2018/06/10 01:16:29 +0200][NOTICE] Successfully received DNS record data.
[2018/06/10 01:16:30 +0200][NOTICE] IP has changed. Before: 1.2.3.4; Now: 5.6.7.8
[2018/06/10 01:16:30 +0200][NOTICE] IP address updated successfully!
[2018/06/10 01:16:30 +0200][NOTICE] Logged out successfully!
```
```
$ php update.php
[2018/06/10 01:17:11 +0200][NOTICE] =============================================
[2018/06/10 01:17:11 +0200][NOTICE] Running dynamic DNS client for netcup 1.0
[2018/06/10 01:17:11 +0200][NOTICE] This script is not affiliated with netcup.
[2018/06/10 01:17:11 +0200][NOTICE] =============================================

[2018/06/10 01:17:12 +0200][NOTICE] Logged in successfully!
[2018/06/10 01:17:12 +0200][NOTICE] Successfully received Domain info.
[2018/06/10 01:17:12 +0200][NOTICE] Successfully received DNS record data.
[2018/06/10 01:17:13 +0200][NOTICE] IP hasn't changed. Current IP: 5.6.7.8
[2018/06/10 01:17:13 +0200][NOTICE] Logged out successfully!
```

If you have ideas on how to improve this script, please don't hesitate to create an issue or provide me with a pull request. Thank you!
