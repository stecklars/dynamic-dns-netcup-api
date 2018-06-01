<?php

require_once 'config.php';

//Declare possbile options
$quiet = false;

//Check passed options
foreach ($argv as $option) {
    if ($option === "--quiet") {
        $quiet = true;
    }
}

const SUCCESS = 'success';

// Sends $request to netcup Domain API and returns the result
function sendRequest($request)
{
    $ch = curl_init(APIURL);
    $curlOptions = array(
        CURLOPT_POST => 1,
        CURLOPT_RETURNTRANSFER => 1,
        CURLOPT_HTTPHEADER => array('Content-Type: application/json'),
        CURLOPT_POSTFIELDS => $request,
    );
    curl_setopt_array($ch, $curlOptions);

    $result = curl_exec($ch);
    curl_close($ch);

    $result = json_decode($result, true);

    return $result;
}

//Outputs $text to Stdout
function outputStdout($text) {
    global $quiet;

    //If quiet option is set, don't output anything on stdout
    if ($quiet === true) {
        return;
    }
    echo $text;
}

//Outputs $text to Stderr
function outputStderr($text) {
    fwrite(STDERR, $text);
}

//Returns current public IP.
function getCurrentPublicIP()
{
    $publicIP = file_get_contents('https://api.ipify.org');

    //Let's check that this is really a IPv4 address, just in case...
    if (filter_var($publicIP, FILTER_VALIDATE_IP, FILTER_FLAG_IPV4)) {
        return $publicIP;
    }
    return false;
}

//Login into netcup domain API and returns Apisessionid
function login($customernr, $apikey, $apipassword)
{
    $logindata = array(
        'action' => 'login',
        'param' =>
            array(
                'customernumber' => $customernr,
                'apikey' => $apikey,
                'apipassword' => $apipassword,
            ),
    );

    $request = json_encode($logindata);

    $result = sendRequest($request);

    if ($result['status'] === SUCCESS) {
        return $result['responsedata']['apisessionid'];
    }

    outputStderr(sprintf("[ERROR] Error while logging in: %s Exiting.\n\n", $result['longmessage']));
    return false;
}

//Logout of netcup domain API, returns boolean
function logout($customernr, $apikey, $apisessionid)
{
    $logoutdata = array(
        'action' => 'logout',
        'param' =>
            array(
                'customernumber' => $customernr,
                'apikey' => $apikey,
                'apisessionid' => $apisessionid,
            ),
    );

    $request = json_encode($logoutdata);

    $result = sendRequest($request);

    if ($result['status'] === SUCCESS) {
        return true;
    }

    outputStderr(sprintf("[ERROR] Error while logging out: %s Exiting.\n\n", $result['longmessage']));
    return false;
}

//Get info about dns zone from netcup domain API, returns result
function infoDnsZone($domainname, $customernr, $apikey, $apisessionid)
{
    $infoDnsZoneData = array(
        'action' => 'infoDnsZone',
        'param' =>
            array(
                'domainname' => $domainname,
                'customernumber' => $customernr,
                'apikey' => $apikey,
                'apisessionid' => $apisessionid,
            ),
    );

    $request = json_encode($infoDnsZoneData);

    $result = sendRequest($request);

    if ($result['status'] === SUCCESS) {
        return $result;
    }

    outputStderr(sprintf("[ERROR] Error while getting DNS Zone info: %s Exiting.\n\n", $result['longmessage']));
    return false;
}

//Get info about dns records from netcup domain API, returns result
function infoDnsRecords($domainname, $customernr, $apikey, $apisessionid)
{
    $infoDnsRecordsData = array(
        'action' => 'infoDnsRecords',
        'param' =>
            array(
                'domainname' => $domainname,
                'customernumber' => $customernr,
                'apikey' => $apikey,
                'apisessionid' => $apisessionid,
            ),
    );

    $request = json_encode($infoDnsRecordsData);

    $result = sendRequest($request);

    if ($result['status'] === SUCCESS) {
        return $result;
    }

    outputStderr(sprintf("[ERROR] Error while getting DNS Record info: %s Exiting.\n\n", $result['longmessage']));
    return false;
}

//Updates DNS Zone using the netcup domain API and returns boolean
function updateDnsZone($domainname, $customernr, $apikey, $apisessionid, $dnszone)
{
    $updateDnsZoneData = array(
        'action' => 'updateDnsZone',
        'param' =>
            array(
                'domainname' => $domainname,
                'customernumber' => $customernr,
                'apikey' => $apikey,
                'apisessionid' => $apisessionid,
                'dnszone' => $dnszone,
            ),
    );

    $request = json_encode($updateDnsZoneData);

    $result = sendRequest($request);

    if ($result['status'] === SUCCESS) {
        return true;
    }

    outputStderr(sprintf("[ERROR] Error while updating DNS Zone: %s Exiting.\n\n", $result['longmessage']));
    return false;
}

//Updates DNS records using the netcup domain API and returns boolean
function updateDnsRecords($domainname, $customernr, $apikey, $apisessionid, $dnsrecords)
{
    $updateDnsZoneData = array(
        'action' => 'updateDnsRecords',
        'param' =>
            array(
                'domainname' => $domainname,
                'customernumber' => $customernr,
                'apikey' => $apikey,
                'apisessionid' => $apisessionid,
                'dnsrecordset' => array(
                    'dnsrecords' => $dnsrecords,
                ),
            ),
    );

    $request = json_encode($updateDnsZoneData);

    $result = sendRequest($request);

    if ($result['status'] === SUCCESS) {
        return true;
    }

    outputStderr(sprintf("[ERROR] Error while updating DNS Records: %s Exiting.\n\n", $result['longmessage']));
    return false;
}
