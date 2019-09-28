<?php

//Load necessary functions
require_once 'functions.php';

outputStdout("=============================================");
outputStdout("Running dynamic DNS client for netcup 2.0");
outputStdout("This script is not affiliated with netcup.");
outputStdout("=============================================\n");

outputStdout(sprintf("Updating DNS records for host(s) '%s' (A record) and '%s' (AAAA record) on domain %s\n", HOST_IPv4, HOST_IPv6, DOMAIN));

// get cached IP addresses
$ipcache = getIPCache();

// set default values
$ipv4change = false;
$ipv6change = false;

$publicIPv4 = '127.0.0.1';
$publicIPv6 = '::1';

if (USE_IPV4 === true) {
	// get public IPv4 address
	$publicIPv4 = USE_FRITZBOX ? getCurrentPublicIPv4FromFritzBox(FRITZBOX_IP) : getCurrentPublicIPv4();

	//If we couldn't determine a valid public IPv4 address: disable further IPv4 assessment
	if (!$publicIPv4) {
		$USE_IPV4 = false;
	} elseif ($ipcache !== false) {
		// check whether public IPv4 has changed according to IP cache
		if ($ipcache['ipv4'] !== $publicIPv4) {
			$ipv4change = true;
			outputStdout(sprintf("IPv4 address has changed according to local IP cache. Before: %s; Now: %s", $ipcache['ipv4'], $publicIPv4));
		} else {
			outputStdout("IPv4 address hasn't changed according to local IP cache. Current IPv4 address: ".$publicIPv4);
		}
	}
}	

if (USE_IPV6 === true) {
	// get public IPv6 address
	$publicIPv6 = getCurrentPublicIPv6();

	//If we couldn't determine a valid public IPv6 address: disable further IPv6 assessment
	if (!$publicIPv6) {
		$USE_IPV6 = false;
	} elseif ($ipcache !== false) {
		// check whether public IPv6 has changed according to IP cache
		if ($ipcache['ipv6'] !== $publicIPv6) {
			$ipv6change = true;
			outputStdout(sprintf("IPv6 address has changed according to local IP cache. Before: %s; Now: %s", $ipcache['ipv6'], $publicIPv6));
		} else {
			outputStdout("IPv6 address hasn't changed according to local IP cache. Current IPv6 address: ".$publicIPv6);
		}
	}
}

// Login to to netcup via API if public ipv4 or public ipv6 is available AND no IP cache is available or changes need to be updated
if ((USE_IPV6 | USE_IPV4) & ($ipcache === false | $ipv4change === true | $ipv6change === true)) {
	// Login
	if ($apisessionid = login(CUSTOMERNR, APIKEY, APIPASSWORD)) {
		outputStdout("Logged in successfully!");
	} else {
		// clear ip cache in order to reconnect to API in any case on next run of script 
		clearIPCache();
		exit(1);
	}

	// Let's get infos about the DNS zone
	if ($infoDnsZone = infoDnsZone(DOMAIN, CUSTOMERNR, APIKEY, $apisessionid)) {
		outputStdout("Successfully received Domain info.");
	} else {
		// clear ip cache in order to reconnect to API in any case on next run of script
		clearIPCache();
		exit(1);
	}

	//TTL Warning
	if (CHANGE_TTL !== true && $infoDnsZone['responsedata']['ttl'] > 300) {
		outputStdout("TTL is higher than 300 seconds - this is not optimal for dynamic DNS, since DNS updates will take a long time. Ideally, change TTL to lower value. You may set CHANGE_TTL to True in config.php, in which case TTL will be set to 300 seconds automatically.");
	}

	//If user wants it, then we lower TTL, in case it doesn't have correct value
	if (CHANGE_TTL === true && $infoDnsZone['responsedata']['ttl'] !== "300") {
		$infoDnsZone['responsedata']['ttl'] = 300;

		if (updateDnsZone(DOMAIN, CUSTOMERNR, APIKEY, $apisessionid, $infoDnsZone['responsedata'])) {
			outputStdout("Lowered TTL to 300 seconds successfully.");
		} else {
			outputStderr("Failed to set TTL... Continuing.");
		}
	}

	//Let's get the DNS record data.
	if ($infoDnsRecords = infoDnsRecords(DOMAIN, CUSTOMERNR, APIKEY, $apisessionid)) {
		outputStdout("Successfully received DNS record data.");
	} else {
		// clear ip cache in order to reconnect to API in any case on next run of script
		clearIPCache();
		exit(1);
	}
	
	// update ipv4
	if (USE_IPV4) {
		updateIP($infoDnsRecords, $publicIPv4, $apisessionid);
	}

	// update ipv6
	if (USE_IPV6) {
		updateIP($infoDnsRecords, $publicIPv6, $apisessionid);
	}

	//Logout
	if (logout(CUSTOMERNR, APIKEY, $apisessionid)) {
		outputStdout("Logged out successfully!");
	}

	// update ip cache
	setIPCache($publicIPv4, $publicIPv6);
}
?>