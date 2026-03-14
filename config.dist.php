<?php

// Enter your netcup customer number here.
define('CUSTOMERNR', '12345');


// Enter your API-Password and -Key here - you can generate them in your CCP at https://ccp.netcup.net
define('APIPASSWORD', 'abcdefghijklmnopqrstuvwxyz');
define('APIKEY', 'abcdefghijklmnopqrstuvwxyz');


// Define domains and subdomains which should be used for dynamic DNS in the following format:
// domain.tld: host1, host2, host3; domain2.tld: host1, host4, *, @
// Start with the domain (without subdomain), add ':' after the domain, then add as many subdomains as you want, separated by ','.
// To add another domain, finish with ';'.
// Whitespace (spaces and newlines) are ignored. If you have a very complicated configuration, you may want to use multiple lines. Feel free to do so!
// If one of the subdomains does not exist, the script will create them for you.
// Subdomain configuration: Use '@' for the domain without subdomain. Use '*' for wildcard: All subdomains (except ones already defined in DNS).
define('DOMAINLIST', 'myfirstdomain.com: server, dddns; myseconddomain.com: @, *, some-subdomain');


// The old format for configuring domain + host is still supported, but deprecated. I recommend to switch to the above config,
// as it allows you to define multiple domains + subdomains.

// Enter Domain which should be used for dynamic DNS.
// define('DOMAIN', 'mydomain.com');
// Enter subdomain to be used for dynamic DNS, alternatively '@' for domain root or '*' for wildcard. If the record doesn't exist, the script will create it.
// define('HOST', 'server');


// Enter an URL to use to determine the public IPv4 address.
// [Optional; will be set to default value 'https://get-ipv4.steck.cc' if missing.]
define('IPV4_ADDRESS_URL', 'https://get-ipv4.steck.cc');

// Enter an URL to use as fallback to determine the public IPv4 address.
// [Optional; will be set to default value 'https://ipv4.seeip.org' if missing.]
define('IPV4_ADDRESS_URL_FALLBACK', 'https://ipv4.seeip.org');

// Enter an URL to use to determine the public IPv6 address.
// [Optional; will be set to default value 'https://get-ipv6.steck.cc' if missing.]
define('IPV6_ADDRESS_URL', 'https://get-ipv6.steck.cc');

// Enter an URL to use as fallback to determine the public IPv6 address.
// [Optional; will be set to default value 'https://v6.ident.me' if missing.]
define('IPV6_ADDRESS_URL_FALLBACK', 'https://v6.ident.me');


// If set to true, the script will check for your public IPv4 address and add it as an A-Record / change an existing A-Record for the host.
// You may want to deactivate this, for example, when using a carrier grade NAT (CGNAT).
// Most likely though, you should keep this active, unless you know otherwise.
define('USE_IPV4', true);

// If set to true, the script will check for your public IPv6 address too and add it as an AAAA-Record / change an existing AAAA-Record for the host.
// Activate this only if you have IPv6 connectivity, or you *WILL* get errors.
define('USE_IPV6', false);


// If set to true, this will change TTL to 300 seconds on every run if necessary.
define('CHANGE_TTL', true);


// Seconds to wait between retries on network errors or invalid responses.
// [Optional; will be set to default value 30 if missing.]
// define('RETRY_SLEEP', 30);


// Maximum random delay in seconds (1 to JITTER_MAX) applied before API calls.
// This spreads load on the DNS API when many users run the script via cron at the same time.
// Set to 0 to disable (not recommended).
// [Optional; will be set to default value 30 if missing.]
define('JITTER_MAX', 30);


// Path to the IP cache file. The script caches the current IP address after
// a successful update. On subsequent runs, if the IP hasn't changed, the
// script skips the DNS API entirely. Use --force to bypass the cache.
// [Optional; will be set to default value '__DIR__/cache.json' if missing.]
// define('CACHE_FILE', __DIR__ . '/cache.json');


// Use netcup DNS REST-API.
define('APIURL', 'https://ccp.netcup.net/run/webservice/servers/endpoint.php?JSON');
