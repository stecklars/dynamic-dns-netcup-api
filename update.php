<?php

  require_once("functions.php");

  echo("===============================================================\n");
  echo("Running dynamic DNS client for netcup 1.0 at " . date("Y/m/d H:i:s") . "\n");
  echo("This script is not affiliated with netcup.\n");
  echo("===============================================================\n\n");

  // Login
  if ($apisessionid = login(CUSTOMERNR, APIKEY, APIPASSWORD)) {
    echo "Logged in successfully!\n\n";
  }
  else {
    die("Exiting due to fatal error...\n\n");
  }

  // Let's get infos about the DNS zone
  if ($infoDnsZone = infoDnsZone(DOMAIN, CUSTOMERNR, APIKEY, $apisessionid)) {
    echo "Successfully received Domain info.\n\n";
  }
  else {
    die("Exiting due to fatal error...\n\n");
  }
  //TTL Warning
  if ($infoDnsZone['responsedata']['ttl'] > 300 && CHANGE_TTL != True) {
    echo("TTL is higher than 300 seconds - this is not optimal for dynamic DNS, since DNS updates will take a long time. Ideally, change TTL to lower value. You may set CHANGE_TTL to True in config.php,
in which case TTL will be set to 300 seconds automatically.\n\n");
  }

  //If user wants it, then we lower TTL, in case it doesn't have correct value
  if (CHANGE_TTL == True && $infoDnsZone['responsedata']['ttl'] != 300) {

    $infoDnsZone['responsedata']['ttl'] = 300;

    if (updateDnsZone(DOMAIN, CUSTOMERNR, APIKEY, $apisessionid, $infoDnsZone['responsedata'])) {
      echo("Lowered TTL to 300 seconds successfully.\n\n");
    }
    else {
      echo("Failed to set TTL...\n\n");
    }
  }

  //Let's get the DNS record data.
  if ($infoDnsRecords = infoDnsRecords(DOMAIN, CUSTOMERNR, APIKEY, $apisessionid)) {
    echo ("Successfully received DNS record data.\n\n");
  }
  else {
    die("Exiting due to fatal error...\n\n");
  }

  //Find the ID of the Host(s)
  $hostIDs = array();

  foreach ($infoDnsRecords['responsedata']['dnsrecords'] as $record) {
    if ($record['hostname'] == HOST && $record['type'] == "A") {
      array_push($hostIDs, array(
        'id' => $record['id'],
        'hostname' => $record['hostname'],
        'type' => $record['type'],
        'priority' => $record['priority'],
        'destination' => $record['destination'],
        'deleterecord' => $record['deleterecord'],
        'state' => $record['state']
      ));
    }
  }

  //If we can't find the zone, exit due to error.
  if (sizeof($hostIDs) == 0) {
    // TODO: Add Host
    die("Error: Host ". HOST . " with an A-Record doesn't exist! Exiting...\n\n");
  }

  //If the host with A record exists more than one time...
  if (sizeof($hostIDs) > 1) {
    echo ("Found multiple A-Records for the Host " . HOST . ".\n\n");
    die("Please specify a host for which only a single A-Record exists in config.php. Exiting due to the error...\n\n");
  }

  //If we couldn't determine a valid public IPv4 address
  if (!$publicIP = getCurrentPublicIP()) {
    die("Exiting due to fatal error...\n\n");
  }

  $ipchange = False;

  //Has the IP changed?
  foreach ($hostIDs as $record) {
    if ($record['destination'] != $publicIP) {
      //Yes, it has changed.
      $ipchange = True;
      echo "IP has changed
Before: " . $record['destination'] . "
Now: " . $publicIP . "\n\n";
    }
    else {
      //No, it hasn't changed.
      echo "IP hasn't changed. Current IP: " . $publicIP . "\n\n";
    }
  }

  //Yes, it has changed.
  if ($ipchange == True) {
    $hostIDs[0]['destination'] = $publicIP;
    //Update the record
    if (updateDnsRecords(DOMAIN, CUSTOMERNR, APIKEY, $apisessionid, $hostIDs)) {
      echo "IP address updated successfully!\n\n";
    }
    else {
      die("Exiting due to fatal error...\n\n");
    }
  }

  //Logout
  if (logout(CUSTOMERNR, APIKEY, $apisessionid)) {
    echo "Logged out successfully!\n\n";
  }
  else {
    die("Exiting due to fatal error...\n\n");
  }
