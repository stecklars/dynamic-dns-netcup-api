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
* IPv6 Support
* Updating of a specific subdomain, domain root, or subdomain
* Creation of DNS record, if it doesn't already exist
* If configured, lowers TTL to 300 seconds for the domain on each run, if necessary
* Hiding output (quiet option)

### Missing
* Support for domain root and wildcard / specific subdomains at the same time
* Caching the IP provided to netcup DNS, to avoid running into (currently not existing) rate limits in the DNS API
* Probably a lot more :grin: – to be continued...

## Getting started
### Download
Download the [latest version](https://github.com/stecklars/dynamic-dns-netcup-api/releases/latest) from the releases or clone the repository:

`$ git clone https://github.com/stecklars/dynamic-dns-netcup-api.git`

I'm always trying to keep the master branch stable.

### Configuration
Configuration is very simple: 
* Copy `config.dist.php` to `config.php`
  * `cp config.dist.php config.php`
* Fill out `config.php` with the required values. The options are explained in there.

### How to use
`php update.php`

You should probably run this script every few minutes, so that your IP is updated as quickly as possible. Add it to your cronjobs and run it regularly, for example every five minutes.

### CLI options
Just add these Options after the command like `php update.php --quiet`

| option        | function                                                  |
| ------------- |----------------------------------------------------------:|
| --quiet       | The script won't output notices, only errors and warnings |

## Example outputs
```
$ php update.php
[2018/06/10 05:03:40 +0200][NOTICE] =============================================
[2018/06/10 05:03:40 +0200][NOTICE] Running dynamic DNS client for netcup 2.0
[2018/06/10 05:03:40 +0200][NOTICE] This script is not affiliated with netcup.
[2018/06/10 05:03:40 +0200][NOTICE] =============================================

[2018/06/10 05:03:40 +0200][NOTICE] Updating DNS records for host @ on domain mydomain.com

[2018/06/10 05:03:41 +0200][NOTICE] Logged in successfully!
[2018/06/10 05:03:41 +0200][NOTICE] Successfully received Domain info.
[2018/06/10 05:03:41 +0200][NOTICE] Lowered TTL to 300 seconds successfully.
[2018/06/10 05:03:42 +0200][NOTICE] Successfully received DNS record data.
[2018/06/10 05:03:42 +0200][NOTICE] A record for host @ doesn't exist, creating necessary DNS record.
[2018/06/10 05:03:42 +0200][NOTICE] IPv4 address has changed. Before: newly created Record; Now: 5.6.7.8
[2018/06/10 05:03:44 +0200][NOTICE] IPv4 address updated successfully!
[2018/06/10 05:03:44 +0200][NOTICE] AAAA record for host @ doesn't exist, creating necessary DNS record.
[2018/06/10 05:03:44 +0200][NOTICE] IPv6 address has changed. Before: newly created Record; Now: 2001:db8:85a3:0:0:8a2e:370:7334
[2018/06/10 05:03:46 +0200][NOTICE] IPv6 address updated successfully!
[2018/06/10 05:03:46 +0200][NOTICE] Logged out successfully!

```
```
$ php update.php
[2018/06/10 05:03:50 +0200][NOTICE] =============================================
[2018/06/10 05:03:50 +0200][NOTICE] Running dynamic DNS client for netcup 2.0
[2018/06/10 05:03:50 +0200][NOTICE] This script is not affiliated with netcup.
[2018/06/10 05:03:50 +0200][NOTICE] =============================================

[2018/06/10 05:03:50 +0200][NOTICE] Updating DNS records for host @ on domain mydomain.com

[2018/06/10 05:03:50 +0200][NOTICE] Logged in successfully!
[2018/06/10 05:03:51 +0200][NOTICE] Successfully received Domain info.
[2018/06/10 05:03:51 +0200][NOTICE] Successfully received DNS record data.
[2018/06/10 05:03:52 +0200][NOTICE] IPv4 address hasn't changed. Current IPv4 address: 5.6.7.8
[2018/06/10 05:03:52 +0200][NOTICE] IPv6 address hasn't changed. Current IPv6 address: 2001:db8:85a3:0:0:8a2e:370:7334
[2018/06/10 05:03:52 +0200][NOTICE] Logged out successfully!
```
```
$ php update.php
[2018/06/10 05:08:22 +0200][NOTICE] =============================================
[2018/06/10 05:08:22 +0200][NOTICE] Running dynamic DNS client for netcup 2.0
[2018/06/10 05:08:22 +0200][NOTICE] This script is not affiliated with netcup.
[2018/06/10 05:08:22 +0200][NOTICE] =============================================

[2018/06/10 05:08:22 +0200][NOTICE] Updating DNS records for host @ on domain mydomain.com

[2018/06/10 05:08:22 +0200][NOTICE] Logged in successfully!
[2018/06/10 05:08:22 +0200][NOTICE] Successfully received Domain info.
[2018/06/10 05:08:23 +0200][NOTICE] Successfully received DNS record data.
[2018/06/10 05:08:23 +0200][NOTICE] IPv4 address has changed. Before: 5.6.7.8; Now: 1.2.3.4
[2018/06/10 05:08:24 +0200][NOTICE] IPv4 address updated successfully!
[2018/06/10 05:08:24 +0200][NOTICE] IPv6 address has changed. Before: 2001:db8:85a3:0:0:8a2e:370:7334; Now: 2001:db8:85a3:0:0:8a2e:370:5123
[2018/06/10 05:08:24 +0200][NOTICE] IPv6 address updated successfully!
[2018/06/10 05:08:25 +0200][NOTICE] Logged out successfully!
```

If you have ideas on how to improve this script, please don't hesitate to create an issue or provide me with a pull request. Thank you!
