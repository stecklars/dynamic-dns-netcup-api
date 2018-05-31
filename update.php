<?php

require_once 'functions.php';

echo "===============================================================\n";
echo "Running dynamic DNS client for netcup 1.0 at ".date("Y/m/d H:i:s")."\n";
echo "This script is not affiliated with netcup.\n";
echo "===============================================================\n\n";

// Login
if ($apisessionid = login(CUSTOMERNR, APIKEY, APIPASSWORD)) {
    echo "Logged in successfully!\n\n";
} else {
    die("Exiting due to fatal error...\n\n");
}

// Let's get infos about the DNS zone
if ($infoDnsZone = infoDnsZone(DOMAIN, CUSTOMERNR, APIKEY, $apisessionid)) {
    echo "Successfully received Domain info.\n\n";
} else {
    die("Exiting due to fatal error...\n\n");
}
//TTL Warning
if (CHANGE_TTL !== true && $infoDnsZone['responsedata']['ttl'] > 300) {
    echo "TTL is higher than 300 seconds - this is not optimal for dynamic DNS, since DNS updates will take a long time. Ideally, change TTL to lower value. You may set CHANGE_TTL to True in config.php,\nin which case TTL will be set to 300 seconds automatically.\n\n";
}

//If user wants it, then we lower TTL, in case it doesn't have correct value
if (CHANGE_TTL === true && $infoDnsZone['responsedata']['ttl'] !== "300") {
    $infoDnsZone['responsedata']['ttl'] = 300;

    if (updateDnsZone(DOMAIN, CUSTOMERNR, APIKEY, $apisessionid, $infoDnsZone['responsedata'])) {
        echo "Lowered TTL to 300 seconds successfully.\n\n";
    } else {
        echo "Failed to set TTL...\n\n";
    }
}

//Let's get the DNS record data.
if ($infoDnsRecords = infoDnsRecords(DOMAIN, CUSTOMERNR, APIKEY, $apisessionid)) {
    echo "Successfully received DNS record data.\n\n";
} else {
    die("Exiting due to fatal error...\n\n");
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
    die(sprintf("Error: Host %s with an A-Record doesn't exist! Exiting...\n\n", HOST));
}

//If the host with A record exists more than one time...
if (count($hostIDs) > 1) {
    printf("Found multiple A-Records for the Host %s\n\n", HOST);
    die("Please specify a host for which only a single A-Record exists in config.php. Exiting due to the error...\n\n");
}

//If we couldn't determine a valid public IPv4 address
if (!$publicIP = getCurrentPublicIP()) {
    die("Exiting due to fatal error...\n\n");
}

$ipchange = false;

//Has the IP changed?
foreach ($hostIDs as $record) {
    if ($record['destination'] !== $publicIP) {
        //Yes, it has changed.
        $ipchange = true;
        printf("IP has changed\nBefore: %s\nNow: %s\n\n", $record['destination'], $publicIP);
    } else {
        //No, it hasn't changed.
        echo "IP hasn't changed. Current IP: ".$publicIP."\n\n";
    }
}

//Yes, it has changed.
if ($ipchange === true) {
    $hostIDs[0]['destination'] = $publicIP;
    //Update the record
    if (updateDnsRecords(DOMAIN, CUSTOMERNR, APIKEY, $apisessionid, $hostIDs)) {
        echo "IP address updated successfully!\n\n";
    } else {
        die("Exiting due to fatal error...\n\n");
    }
}

//Logout
if (logout(CUSTOMERNR, APIKEY, $apisessionid)) {
    echo "Logged out successfully!\n\n";
} else {
    die("Exiting due to fatal error...\n\n");
}
