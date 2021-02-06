<?php
// Enter your netcup customer number here
define('CUSTOMERNR', '12345');

//Enter your API-Key and -Password here - you can generate them in your CCP at https://ccp.netcup.net
define('APIKEY', 'abcdefghijklmnopqrstuvwxyz');
define('APIPASSWORD', 'abcdefghijklmnopqrstuvwxyz');

// Enter Domain which should be used for dynamic DNS
define('DOMAIN', 'mydomain.com');

//Enter subdomain(s) to be used for dynamic DNS IPv4, alternatively '@' for domain root or '*' for wildcard. If the record doesn't exist, the script will create it.
define('HOST_IPv4', 'server.example.com,server1.example.com');

//Enter subdomain(s) to be used for dynamic DNS IPv6, alternatively '@' for domain root or '*' for wildcard. If the record doesn't exist, the script will create it.
define('HOST_IPv6', 'server.example.com,server1.example.com');

//Activate IPv4 update
define('USE_IPV4', true);

//Should the script try to get the public IPv4 from your FritzBox?
define('USE_FRITZBOX', false);

//IP of the Fritz Box. You can use default fritz.box
define('FRITZBOX_IP', 'fritz.box');

//If set to true, the script will check for your public IPv6 address too and add it as an AAAA-Record / change an existing AAAA-Record for the host.
//Activate this only if you have IPv6 connectivity, or you *WILL* get errors.
define('USE_IPV6', false);

//Required if using IPv6: The interface to get the IPv6 address from
define('IPV6_INTERFACE', 'eth0');

//Shall only IPv6 addresses be set in the AAAA record which have a static EUI-64-Identifier (no privacy extensions)? If 'false', EUI-64-Identifier will be filtered and not be used
define('NO_IPV6_PRIVACY_EXTENSIONS', true);

//If set to true, this will change TTL to 300 seconds on every run if necessary.
define('CHANGE_TTL', true);

// Use netcup DNS REST-API
define('APIURL', 'https://ccp.netcup.net/run/webservice/servers/endpoint.php?JSON');

// Send an email on errors and warnings. Requires the 'sendmail_path' to be set in php.ini.
define('SEND_MAIL', false);

// Recipient mail address for error and warnings
define('MAIL_RECIPIENT', 'user@domain.tld');
?>
