<?php

//Load necessary functions
require_once 'functions.php';

outputStdout("=============================================");
outputStdout("Running dynamic DNS client for netcup 1.0");
outputStdout("This script is not affiliated with netcup.");
outputStdout("=============================================\n");

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

//Find the ID of the Host(s)
$hostIDs = array();

foreach ($infoDnsRecords['responsedata']['dnsrecords'] as $record) {
    if ($record['hostname'] === HOST && $record['type'] === "A") {
        $hostIDs[] = array(
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

//If we can't find the zone, exit due to error.
if (count($hostIDs) === 0) {
    // TODO: Add Host
    outputStderr((sprintf("[ERROR] Host %s with an A-Record doesn't exist! Exiting.", HOST)));
    exit(1);
}

//If the host with A record exists more than one time...
if (count($hostIDs) > 1) {
    outputStderr(sprintf("[ERROR] Found multiple A-Records for the Host %s", HOST));
    outputStderr(("Please specify a host for which only a single A-Record exists in config.php. Exiting."));
    exit(1);
}

//If we couldn't determine a valid public IPv4 address
if (!$publicIP = getCurrentPublicIPv4()) {
    outputStderr("[ERROR] Main API and fallback API didn't return a valid IPv4 address. Exiting.");
    exit(1);
}

$ipchange = false;

//Has the IP changed?
foreach ($hostIDs as $record) {
    if ($record['destination'] !== $publicIP) {
        //Yes, it has changed.
        $ipchange = true;
        outputStdout(sprintf("IP has changed. Before: %s; Now: %s", $record['destination'], $publicIP));
    } else {
        //No, it hasn't changed.
        outputStdout("IP hasn't changed. Current IP: ".$publicIP."");
    }
}

//Yes, it has changed.
if ($ipchange === true) {
    $hostIDs[0]['destination'] = $publicIP;
    //Update the record
    if (updateDnsRecords(DOMAIN, CUSTOMERNR, APIKEY, $apisessionid, $hostIDs)) {
        outputStdout("IP address updated successfully!");
    } else {
        exit(1);
    }
}

//Logout
if (logout(CUSTOMERNR, APIKEY, $apisessionid)) {
    outputStdout("Logged out successfully!");
} else {
    exit(1);
}
