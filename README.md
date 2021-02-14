# Dynamic DNS client for netcup DNS API
**A simple dynamic DNS client written in PHP for use with the netcup DNS API.** This project is a fork of https://github.com/stecklars/dynamic-dns-netcup-api. Please also refer to the dockernized version under https://hub.docker.com/r/mm28ajos/dynamic-dns-netcup-api.

## Requirements
* Be a netcup customer: https://www.netcup.de – or for international customers: https://www.netcup.eu
  * You don't have to be a domain reseller to use the necessary functions for this client – every customer with a domain may use it.
* netcup API key and API password, which can be created within your CCP at https://ccp.netcup.net
* PHP-CLI with CURL, JSON and Openssl extension or run it with docker-compose: https://hub.docker.com/r/mm28ajos/dynamic-dns-netcup-api
* A domain :wink:

## Features
### Implemented
* All necessary API functions for DNS actions implemented (REST API)
* Determines correct public IP addresses (IPv4 and IPv6) without external third party look ups using local adapter for IPV or local FritzBox (external API call for determining the IPv4 addresses possible if no fritz box available or as fallback)
* Caching the IP provided to netcup DNS to avoid unnecessary API calls
* Updating of a specific subdomain, domain root, or multiple subdomains
* configure hosts for updating IPv4 and IPv6 separately
* Creation of DNS record, if it does not already exist
* If configured, lowers TTL to 300 seconds for the domain on each run if necessary
* Hiding output (quiet option)
* Dockernized version available, refer to https://hub.docker.com/r/mm28ajos/dynamic-dns-netcup-api

### Missing
* Support for domain root and wildcard
* Probably a lot more :grin: – to be continued...

## Getting started
### Download
Download the [latest version](https://github.com/mm28ajos/dynamic-dns-netcup-api/releases/latest) from the releases or clone the repository:

`$ git clone https://github.com/mm28ajos/dynamic-dns-netcup-api/dynamic-dns-netcup-api.git`

### Configuration
Configuration is very simple: Just fill out `config.ini` with the required values. The options are explained in there.

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
[2021/02/14 16:49:27 +0000][NOTICE] =============================================
[2021/02/14 16:49:27 +0000][NOTICE] Running dynamic DNS client for netcup 2.0
[2021/02/14 16:49:27 +0000][NOTICE] This script is not affiliated with netcup.
[2021/02/14 16:49:27 +0000][NOTICE] =============================================

[2021/02/14 16:49:27 +0000][NOTICE] No ip cache available
[2021/02/14 16:49:27 +0000][NOTICE] Updating DNS records for host(s) 'sub.subdomainA' (A record) on domain domain.tld
[2021/02/14 16:49:28 +0000][NOTICE] Updating DNS records for host(s) 'sub.subdomainB' (AAAA record) on domain domain.tld
[2021/02/14 16:49:28 +0000][NOTICE] Logged in successfully!
[2021/02/14 16:49:28 +0000][NOTICE] Successfully received Domain info.
[2021/02/14 16:49:28 +0000][NOTICE] Successfully received DNS record data.
[2021/02/14 16:49:28 +0000][NOTICE] A record for host sub.subdomainA doesn't exist, creating necessary DNS record.
[2021/02/14 16:49:28 +0000][NOTICE] IPv4 address for host sub.subdomain has changed. Before: newly created Record; Now: 8.8.8.8
[2021/02/14 16:49:31 +0000][NOTICE] IPv4 address updated successfully!
[2021/02/14 16:49:31 +0000][NOTICE] AAAA record for host sub.subdomainB doesn't exist, creating necessary DNS record.
[2021/02/14 16:49:31 +0000][NOTICE] IPv6 address for host sub.subdomainB has changed. Before: newly created Record; Now: 2a01:::0
[2021/02/14 16:49:33 +0000][NOTICE] IPv6 address updated successfully!
[2021/02/14 16:49:33 +0000][NOTICE] Logged out successfully!
```
```
$ php update.php
[2021/02/14 16:52:38 +0000][NOTICE] =============================================
[2021/02/14 16:52:38 +0000][NOTICE] Running dynamic DNS client for netcup 2.0
[2021/02/14 16:52:38 +0000][NOTICE] This script is not affiliated with netcup.
[2021/02/14 16:52:38 +0000][NOTICE] =============================================

[2021/02/14 16:52:38 +0000][NOTICE] Updating DNS records for host(s) 'sub.subdomainA' (A record) on domain domain.tld
[2021/02/14 16:52:40 +0000][NOTICE] IPv4 address hasn't changed according to local IP cache. Current IPv4 address: 8.8.8.8
[2021/02/14 16:52:40 +0000][NOTICE] Updating DNS records for host(s) 'sub.subdomainB' (AAAA record) on domain domain.tld
[2021/02/14 16:52:40 +0000][NOTICE] IPv6 address hasn't changed according to local IP cache. Current IPv6 address: 2a01:::0
```

If you have ideas on how to improve this script, please don't hesitate to create an issue or provide me with a pull request. Thank you!