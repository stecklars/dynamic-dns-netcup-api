<?php

//Load necessary functions
require_once 'functions.php';

outputStdout("=============================================");
outputStdout("Running dynamic DNS client for netcup 2.0");
outputStdout("This script is not affiliated with netcup.");
outputStdout("=============================================\n");

outputStdout(sprintf("Updating DNS records for host %s on domain %s\n", HOST, DOMAIN));

// Login
if ($apisessionid = login(CUSTOMERNR, APIKEY, APIPASSWORD)) {
    outputStdout("Logged in successfully!");
} else {
    exit(1);
}

// Let's get infos about the DNS zone
if ($infoDnsZone = infoDnsZone(DOMAIN, CUSTOMERNR, APIKEY, $apisessionid)) {
    outputStdout("Successfully received Domain info.");
} else {
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
    exit(1);
}

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

//If we couldn't determine a valid public IPv4 address
if (!$publicIPv4 = getCurrentPublicIPv4()) {
    outputStderr("Main API and fallback API didn't return a valid IPv4 address. Exiting.");
    exit(1);
}

$ipv4change = false;

//Has the IP changed?
foreach ($foundHostsV4 as $record) {
    if ($record['destination'] !== $publicIPv4) {
        //Yes, it has changed.
        $ipv4change = true;
        outputStdout(sprintf("IPv4 address has changed. Before: %s; Now: %s", $record['destination'], $publicIPv4));
    } else {
        //No, it hasn't changed.
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
        exit(1);
    }
}

if (USE_IPV6 === true) {
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

    //If we couldn't determine a valid public IPv6 address
    if (!$publicIPv6 = getCurrentPublicIPv6()) {
        outputStderr("Main API and fallback API didn't return a valid IPv6 address. Do you have IPv6 connectivity? If not, please disable USE_IPV6 in config.php. Exiting.");
        exit(1);
    }

    $ipv6change = false;

    //Has the IP changed?
    foreach ($foundHostsV6 as $record) {
        if ($record['destination'] !== $publicIPv6) {
            //Yes, it has changed.
            $ipv6change = true;
            outputStdout(sprintf("IPv6 address has changed. Before: %s; Now: %s", $record['destination'], $publicIPv6));
        } else {
            //No, it hasn't changed.
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
            exit(1);
        }
    }
}

//Logout
if (logout(CUSTOMERNR, APIKEY, $apisessionid)) {
    outputStdout("Logged out successfully!");
} else {
    exit(1);
}
