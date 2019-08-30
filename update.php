<?php

//Load necessary functions
require_once 'functions.php';

outputStdout("=============================================");
outputStdout("Running dynamic DNS client for netcup 2.0");
outputStdout("This script is not affiliated with netcup.");
outputStdout("=============================================\n");

outputStdout(sprintf("Updating DNS records for host %s on domain %s\n", HOST, DOMAIN));

// get cached IP addresses
$ipcache = getIPCache();

// set default values
$ipv4change = false;
$ipv6change = false;

$publicIPv4 = '127.0.0.1';
$publicIPv6 = '::1';

if (USE_IPV4 === true) {
	// get public IPv4 address
	$publicIPv4 = getCurrentPublicIPv4();

	//If we couldn't determine a valid public IPv4 address exit
	if (!$publicIPv4) {
	    outputStderr("Main API and fallback API didn't return a valid IPv4 address. Exiting.");
	    exit(1);
	}

	if ($ipcache !== false) {
		// check whether public IPv4 has changed according to IP cache
		if ($ipcache['ipv4'] !== $publicIPv4) {
			$ipv4change = true;
			outputStdout(sprintf("IPv4 address has changed according to local IP cache. Before: %s; Now: %s", $ipcache['ipv4'], $publicIPv4));
		}
		else
		{
			outputStdout("IPv4 address hasn't changed according to local IP cache. Current IPv4 address: ".$publicIPv4);
		}
	}
}	

if (USE_IPV6 === true) {
	// get public IPv4 address
	$publicIPv6 = getCurrentPublicIPv6();

	//If we couldn't determine a valid public IPv6 address exit
	if (!$publicIPv6) {
	    outputStderr("Device, main API and fallback API didn't return a valid IPv6 address. Exiting.");
	    exit(1);
	// If there are multiple IPv6 filter on the previous IPv6 (there may be IPv6 PD re-assign issues) and select the first IPv6
        } elseif (is_array($publicIPv6)) {
            $publicIPv6 = array_filter($publicIPv6, function ($var) use($ipcache) { return (stripos($var, $ipcache['ipv6']) === false); });
	    $publicIPv6 = $publicIPv6[array_keys($publicIPv6)[0]];
        }


	if ($ipcache !== false) {
		// check whether public IPv6 has changed according to IP cache
		if ($ipcache['ipv6'] !== $publicIPv6) {
			$ipv6change = true;
			outputStdout(sprintf("IPv6 address has changed according to local IP cache. Before: %s; Now: %s", $ipcache['ipv6'], $publicIPv6));
		}
		else
		{
			outputStdout("IPv6 address hasn't changed according to local IP cache. Current IPv6 address: ".$publicIPv6);
		}
	}
}

// Login to to netcup via API if no IP cache is available or changes need to be updated
if ($ipcache === false | $ipv4change === true | $ipv6change === true) {
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

	if (USE_IPV4) {		

		//Find the host defined in config.php
		$foundHostsV4 = array();

		foreach ($infoDnsRecords['responsedata']['dnsrecords'] as $record) {
		    if ($record['hostname'] === HOST && $record['type'] === "A") {
		        $foundHostsV4[] = array(
		            'id' => $record['id'],
		            'hostname' => $record['hostname'],
		            'type' => $record['type'],
		            'priority' => $record['priority'],
		            'destination' => $record['destination'],
		            'deleterecord' => $record['deleterecord'],
		            'state' => $record['state'],
		        );
		    }
		}

		//If we can't find the host, create it.
		if (count($foundHostsV4) === 0) {
		    outputStdout(sprintf("A record for host %s doesn't exist, creating necessary DNS record.", HOST));
		    $foundHostsV4[] = array(
		        'hostname' => HOST,
		        'type' => 'A',
		        'destination' => 'newly created Record',
		    );
		}

		//If the host with A record exists more than one time...
		if (count($foundHostsV4) > 1) {
		    outputStderr(sprintf("Found multiple A records for the host %s – Please specify a host for which only a single A record exists in config.php. Exiting.", HOST));
		    exit(1);
		}		

		//Has the IP changed?
		foreach ($foundHostsV4 as $record) {
		    if ($record['destination'] !== $publicIPv4) {
		        //Yes, it has changed.
		        $ipv4change = true;
		        outputStdout(sprintf("IPv4 address has changed. Before: %s; Now: %s", $record['destination'], $publicIPv4));
		    } else {
		        //No, it hasn't changed.
		        $ipv4change = false;
		        outputStdout("IPv4 address hasn't changed. Current IPv4 address: ".$publicIPv4);
		    }
		}

		//Yes, it has changed.
		if ($ipv4change === true) {
		    $foundHostsV4[0]['destination'] = $publicIPv4;
		    //Update the record
		    if (updateDnsRecords(DOMAIN, CUSTOMERNR, APIKEY, $apisessionid, $foundHostsV4)) {
		        outputStdout("IPv4 address updated successfully!");
		    } else {
		    	// clear ip cache in order to reconnect to API in any case on next run of script
		    	clearIPCache();
		        exit(1);
		    }
		}
	}

	if (USE_IPV6) {

	    //Find the host defined in config.php
	    $foundHostsV6 = array();

	    foreach ($infoDnsRecords['responsedata']['dnsrecords'] as $record) {
	        if ($record['hostname'] === HOST && $record['type'] === "AAAA") {
	            $foundHostsV6[] = array(
	                'id' => $record['id'],
	                'hostname' => $record['hostname'],
	                'type' => $record['type'],
	                'priority' => $record['priority'],
	                'destination' => $record['destination'],
	                'deleterecord' => $record['deleterecord'],
	                'state' => $record['state'],
	            );
	        }
	    }

	    //If we can't find the host, create it.
	    if (count($foundHostsV6) === 0) {
	        outputStdout(sprintf("AAAA record for host %s doesn't exist, creating necessary DNS record.", HOST));
	        $foundHostsV6[] = array(
	            'hostname' => HOST,
	            'type' => 'AAAA',
	            'destination' => 'newly created Record',
	        );
	    }

	    //If the host with AAAA record exists more than one time...
	    if (count($foundHostsV6) > 1) {
	        outputStderr(sprintf("Found multiple AAAA records for the host %s – Please specify a host for which only a single AAAA record exists in config.php. Exiting.", HOST));
	        exit(1);
	    }

	    //Has the IP changed?
	    foreach ($foundHostsV6 as $record) {
	        if ($record['destination'] !== $publicIPv6) {
	            //Yes, it has changed.	 
	            $ipv6change = true;           
	            outputStdout(sprintf("IPv6 address has changed. Before: %s; Now: %s", $record['destination'], $publicIPv6));
	        } else {
	            //No, it hasn't changed.
	            $ipv6change = false;
	            outputStdout("IPv6 address hasn't changed. Current IPv6 address: ".$publicIPv6);
	        }
	    }

	    //Yes, it has changed.
	    if ($ipv6change === true) {
	        $foundHostsV6[0]['destination'] = $publicIPv6;
	        //Update the record
	        if (updateDnsRecords(DOMAIN, CUSTOMERNR, APIKEY, $apisessionid, $foundHostsV6)) {
	            outputStdout("IPv6 address updated successfully!");
	        } else {
	        	// clear ip cache in order to reconnect to API in any case on next run of script
	        	clearIPCache();
	            exit(1);
	        }
	    }
	}

	//Logout
	if (logout(CUSTOMERNR, APIKEY, $apisessionid)) {
	    outputStdout("Logged out successfully!");
	} else {
		// clear ip cache in order to reconnect to API in any case on next run of script
		clearIPCache();
	    exit(1);
	}

	// update ip cache
	setIPCache($publicIPv4, $publicIPv6);
}
?>