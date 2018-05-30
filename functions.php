<?php

  require_once("config.php");

  // Sends $request to netcup Domain API and returns the result
  function sendRequest($request) {
    $ch = curl_init(APIURL);
    $curlOptions = array(
      CURLOPT_POST => 1,
      CURLOPT_RETURNTRANSFER => 1,
      CURLOPT_HTTPHEADER => array('Content-Type: application/json'),
      CURLOPT_POSTFIELDS => $request
    );
    curl_setopt_array($ch, $curlOptions);

    $result = curl_exec($ch);
    curl_close($ch);

    $result = json_decode($result, True);
    return $result;
  }

  //Returns current public IP.
  function getCurrentPublicIP() {
    $publicIP = file_get_contents('https://api.ipify.org');

    //Let's check that this is really a IPv4 address, just in case...
    if (filter_var($publicIP, FILTER_VALIDATE_IP, FILTER_FLAG_IPV4)) {
      return($publicIP);
    }
    else {
      echo("https://api.ipify.org didn't return a valid IPv4 address.\n\n");
      return(False);
    }
  }

  //Login into netcup domain API and returns Apisessionid
  function login($customernr, $apikey, $apipassword) {

    $logindata = array(
      'action' => 'login',
      'param' =>
        array(
        'customernumber' => CUSTOMERNR,
        'apikey' => APIKEY,
        'apipassword' => APIPASSWORD
        )
    );

    $request = json_encode($logindata);

    $result = sendRequest($request);

    if ($result['status'] == "success") {
      return($result['responsedata']['apisessionid']);
    }
    else {
      echo("ERROR: Error while logging in: " . $result['longmessage'] . "\n\n");
      return(False);
    }
  }
  //Logout of netcup domain API, returns boolean
  function logout($customernr, $apikey, $apisessionid) {

    $logoutdata = array(
      'action' => 'logout',
      'param' =>
        array(
          'customernumber' => CUSTOMERNR,
          'apikey' => APIKEY,
          'apisessionid' => $apisessionid
        )
    );

    $request = json_encode($logoutdata);

    $result = sendRequest($request);

    if ($result['status'] == "success") {
      return(True);
    }
    else {
      echo("ERROR: Error while logging out: " . $result['longmessage'] . "\n\n");
      return(False);
    }
  }
  //Get info about dns zone from netcup domain API, returns result
  function infoDnsZone($domainname, $customernr, $apikey, $apisessionid) {
    $infoDnsZoneData = array(
      'action' => 'infoDnsZone',
      'param' =>
        array(
          'domainname' => $domainname,
          'customernumber' => $customernr,
          'apikey' => $apikey,
          'apisessionid' => $apisessionid
        )
    );

    $request = json_encode($infoDnsZoneData);

    $result = sendRequest($request);

    if ($result['status'] == "success") {
      return($result);
    }
    else {
      echo("Error while getting DNS Zone info: " . $result['longmessage'] . "\n\n");
      return(False);
    }
  }

  //Get info about dns records from netcup domain API, returns result
  function infoDnsRecords($domainname, $customernr, $apikey, $apisessionid) {
    $infoDnsRecordsData = array(
      'action' => 'infoDnsRecords',
      'param' =>
        array(
          'domainname' => $domainname,
          'customernumber' => $customernr,
          'apikey' => $apikey,
          'apisessionid' => $apisessionid
        )
    );

    $request = json_encode($infoDnsRecordsData);

    $result = sendRequest($request);

    if ($result['status'] == "success") {
      return($result);
    }
    else {
      echo("Error while getting DNS Record info: " . $result['longmessage'] . "\n\n");
      return(False);
    }
  }

  //Updates DNS Zone using the netcup domain API and returns boolean
  function updateDnsZone($domainname, $customernr, $apikey, $apisessionid, $dnszone) {
    $updateDnsZoneData = array(
      'action' => 'updateDnsZone',
      'param' =>
        array(
          'domainname' => $domainname,
          'customernumber' => $customernr,
          'apikey' => $apikey,
          'apisessionid' => $apisessionid,
          'dnszone' => $dnszone
        )
    );

    $request = json_encode($updateDnsZoneData);

    $result = sendRequest($request);

    if ($result['status'] == "success") {
      return(True);
    }
    else {
      echo("Error while updating DNS Zone: " . $result['longmessage'] . "\n\n");
      return(False);
    }
  }

  //Updates DNS records using the netcup domain API and returns boolean
  function updateDnsRecords($domainname, $customernr, $apikey, $apisessionid, $dnsrecords) {
    $updateDnsZoneData = array(
      'action' => 'updateDnsRecords',
      'param' =>
        array(
          'domainname' => $domainname,
          'customernumber' => $customernr,
          'apikey' => $apikey,
          'apisessionid' => $apisessionid,
          'dnsrecordset' => array(
            'dnsrecords' => $dnsrecords
          )
        )
    );

    $request = json_encode($updateDnsZoneData);

    $result = sendRequest($request);

    if ($result['status'] == "success") {
      return(True);
    }
    else {
      echo("Error while updating DNS Records: " . $result['longmessage'] . "\n\n");
      return(False);
    }
  }
