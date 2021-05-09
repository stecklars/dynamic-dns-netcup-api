<?php

//Load necessary functions
require_once 'functions.php';

outputStdout("=============================================");
outputStdout("Running dynamic DNS client for netcup 2.0");
outputStdout("This script is not affiliated with netcup.");
outputStdout("=============================================\n");

// set constants
$APIURL = 'https://ccp.netcup.net/run/webservice/servers/endpoint.php?JSON';

// get cached IP addresses
$ipcache = getIPCache();

// set default values
$ipv4change = false;
$ipv6change = false;

$publicIPv4 = '127.0.0.1';
$publicIPv6 = '::1';

if ($config_array['USE_IPV4'] === 'true') {
	// do some logging
	outputStdout(sprintf("Updating DNS records for host(s) '%s' (A record) on domain %s", $config_array['HOST_IPv4'], $config_array['DOMAIN']));

	// get public IPv4 address
	$publicIPv4 = $config_array['USE_FRITZBOX']  === 'true' ? getCurrentPublicIPv4FromFritzBox($config_array['FRITZBOX_IP']) : getCurrentPublicIPv4();

	if ($publicIPv4) {
		if ($ipcache !== false) {
			// check whether public IPv4 has changed according to IP cache
			if ($ipcache['ipv4'] !== $publicIPv4) {
				$ipv4change = true;
				outputStdout(sprintf("IPv4 address has changed according to local IP cache. Before: %s; Now: %s", $ipcache['ipv4'], $publicIPv4));
			} else {
				$ipv4change = false;
				outputStdout("IPv4 address hasn't changed according to local IP cache. Current IPv4 address: ".$publicIPv4);
			}
		} else {
			$ipv4change = true;
		}
	} else {
		$ipv4change = false;
	}
}

if ($config_array['USE_IPV6'] === 'true') {
        // do some logging
        outputStdout(sprintf("Updating DNS records for host(s) '%s' (AAAA record) on domain %s", $config_array['HOST_IPv6'], $config_array['DOMAIN']));

	// get public IPv6 address
	$publicIPv6 = getCurrentPublicIPv6($config_array['IPV6_INTERFACE'], $config_array['NO_IPV6_PRIVACY_EXTENSIONS']);

	if ($publicIPv6) {
		if ($ipcache !== false) {
			// check whether public IPv6 has changed according to IP cache
			if ($ipcache['ipv6'] !== $publicIPv6) {
				$ipv6change = true;
				outputStdout(sprintf("IPv6 address has changed according to local IP cache. Before: %s; Now: %s", $ipcache['ipv6'], $publicIPv6));
			} else {
				$ipv6change = false;
				outputStdout("IPv6 address hasn't changed according to local IP cache. Current IPv6 address: ".$publicIPv6);
			}
		} else {
			$ipv6change = true;
		}
	} else {
		$ipv6change = false;
	}
}

// Login to to netcup via API if public ipv4 or public ipv6 is available AND changes need to be updated
if ($ipv4change === true | $ipv6change === true) {

	// Login
	if ($apisessionid = login($config_array['CUSTOMERNR'], $config_array['APIKEY'], $config_array['APIPASSWORD'], $APIURL)) {
		outputStdout("Logged in successfully!");
	} else {
		// clear ip cache in order to reconnect to API in any case on next run of script 
		clearIPCache();
		exit(1);
	}

	// Let's get infos about the DNS zone
	if ($infoDnsZone = infoDnsZone($config_array['DOMAIN'], $config_array['CUSTOMERNR'], $config_array['APIKEY'], $apisessionid, $APIURL)) {
		outputStdout("Successfully received Domain info.");
	} else {
		// clear ip cache in order to reconnect to API in any case on next run of script
		clearIPCache();
		exit(1);
	}

	//TTL Warning
	if ($config_array['CHANGE_TTL'] !== 'true' && $infoDnsZone['responsedata']['ttl'] > 300) {
		outputStdout("TTL is higher than 300 seconds - this is not optimal for dynamic DNS, since DNS updates will take a long time. Ideally, change TTL to lower value. You may set CHANGE_TTL to True in config.ini, in which case TTL will be set to 300 seconds automatically.");
	}

	//If user wants it, then we lower TTL, in case it doesn't have correct value
	if ($config_array['CHANGE_TTL'] === 'true' && $infoDnsZone['responsedata']['ttl'] !== "300") {
		$infoDnsZone['responsedata']['ttl'] = 300;

		if (updateDnsZone($config_array['DOMAIN'], $config_array['CUSTOMERNR'], $config_array['APIKEY'], $apisessionid, $infoDnsZone['responsedata'], $APIURL)) {
			outputStdout("Lowered TTL to 300 seconds successfully.");
		} else {
			outputStderr("Failed to set TTL... Continuing.");
		}
	}

	//Let's get the DNS record data.
	if ($infoDnsRecords = infoDnsRecords($config_array['DOMAIN'], $config_array['CUSTOMERNR'], $config_array['APIKEY'], $apisessionid, $APIURL)) {
		outputStdout("Successfully received DNS record data.");
	} else {
		// clear ip cache in order to reconnect to API in any case on next run of script
		clearIPCache();
		exit(1);
	}

	// update ipv4
	if ($ipv4change) {
		updateIP($infoDnsRecords, $publicIPv4, $apisessionid, $config_array['HOST_IPv4'], $config_array['HOST_IPv4'], $config_array['DOMAIN'], $config_array['CUSTOMERNR'], $config_array['APIKEY'], $APIURL);
	}

	// update ipv6
	if ($ipv6change) {
		updateIP($infoDnsRecords, $publicIPv6, $apisessionid, $config_array['HOST_IPv6'], $config_array['HOST_IPv4'], $config_array['DOMAIN'], $config_array['CUSTOMERNR'], $config_array['APIKEY'], $APIURL);
	}

	//Logout
	if (logout($config_array['CUSTOMERNR'], $config_array['APIKEY'], $apisessionid, $APIURL)) {
		outputStdout("Logged out successfully!");
	}

	// update ip cache
	setIPCache($publicIPv4, $publicIPv6);
}

// restart docker container(s) if ipv6 changed and setting is activated
if ($ipv6change === true && $config_array['RESTART_CONTAINERS'] === 'true') {
	shell_exec("docker restart ".explode(",", array_map('trim', $config_array['CONTAINERS'])));
}
?>