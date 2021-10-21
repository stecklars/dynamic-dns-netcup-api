#!/usr/bin/env php
<?php

//Load necessary functions
require_once 'functions.php';

outputStdout("=============================================");
outputStdout("Running dynamic DNS client for netcup 2.0.1");
outputStdout("This script is not affiliated with netcup.");
outputStdout("=============================================\n");

if (! _is_curl_installed()) {
    outputStderr("cURL PHP extension is not installed. Please install the cURL PHP extension, otherwise the script will not work. Exiting.");
    exit(1);
}

outputStdout(sprintf("Reading DNS records for host %s on domain %s\n", HOST, DOMAIN));

// Login
if ($apisessionid = login(CUSTOMERNR, APIKEY, APIPASSWORD)) {
    outputStdout("Logged in successfully!");
} else {
    exit(1);
}

// Let's get infos about the DNS zone
if ($infoDnsZone = infoDnsZone(DOMAIN, CUSTOMERNR, APIKEY, $apisessionid)) {
    outputStdout("Successfully received Domain info.");
    outputStdout(sprintf("Base-Domain: %s", $infoDnsZone['responsedata']['name']));
} else {
    exit(1);
}

//Let's get the DNS record data.
if ($infoDnsRecords = infoDnsRecords(DOMAIN, CUSTOMERNR, APIKEY, $apisessionid)) {
    outputStdout("Successfully received DNS record data.");
} else {
    exit(1);
}

foreach ($infoDnsRecords['responsedata']['dnsrecords'] as $record) {
    outputStdout(sprintf("Record: %s, Type: %s, Destination: %s", $record['hostname'], $record['type'], $record['destination']));
}

//Logout
if (logout(CUSTOMERNR, APIKEY, $apisessionid)) {
    outputStdout("Logged out successfully!");
} else {
    exit(1);
}
