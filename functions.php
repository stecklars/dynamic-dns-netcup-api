<?php

//Try to load required config.php, if it fails, output error, as user probably has not followed "Getting started" guide.
if (!include_once('config.php')) {
    outputStderr("Could not open config.php. Please follow the getting started guide and provide a valid config.php file. Exiting.");
    exit(1);
}

//Declare possible options
$quiet = false;
$force = false;

//Check passed options
if(isset($argv)){
    foreach ($argv as $option) {
        if ($option === "--quiet") {
            $quiet = true;
        }
        if ($option === "--force") {
            $force = true;
        }
    }
}

const SUCCESS = 'success';


//Checks if curl PHP extension is installed
function _is_curl_installed() {
    if  (in_array  ('curl', get_loaded_extensions())) {
        return true;
    }
    else {
        return false;
    }
}

//declare some variables
$dir = getcwd();
$cip4 = '/cip4.log';
$cip6 = '/cip6.log';

function checkcachedip($dir, $ip, $publicIP) {
    //Checks if local files exists
    if (!file_exists($dir.$ip)) {
        file_put_contents($dir.$ip, '');
        chmod($dir.$ip, 0600);
    }
    //Compare local ip - public ip
    if (trim(file_get_contents($dir.$ip)) === $publicIP) {
       return true;
       }
       else {
       return false;
    }
}

// Sends $request to netcup Domain API and returns the result
function sendRequest($request)
{
    $ch = curl_init(APIURL);
    $curlOptions = array(
        CURLOPT_POST => 1,
        CURLOPT_TIMEOUT => 30,
        CURLOPT_RETURNTRANSFER => 1,
        CURLOPT_FAILONERROR => 1,
        CURLOPT_HTTPHEADER => array('Content-Type: application/json'),
        CURLOPT_POSTFIELDS => $request,
    );
    curl_setopt_array($ch, $curlOptions);

    $result = curl_exec($ch);

    if (curl_errno($ch)) {
        $curl_errno = curl_errno($ch);
        $curl_error_msg = curl_error($ch);
    }
    curl_close($ch);

    // Some error handling
    if (isset($curl_error_msg)) {
        outputStderr("cURL Error: ($curl_errno) $curl_error_msg - Exiting.");
        exit(1);
    }

    if (empty($result)) {
        outputStderr("Did not receive a valid response from netcup API (the response was empty). However, I also did not get a curl error or HTTP status code indicating an error. Unknown error. Exiting.");
        exit(1);
    }

    // If everything seems to be ok, proceed...
    $result = json_decode($result, true);

    return $result;
}

//Outputs $text to Stdout
function outputStdout($message)
{
    global $quiet;

    //If quiet option is set, don't output anything on stdout
    if ($quiet === true) {
        return;
    }

    $date = date("Y/m/d H:i:s O");
    $output = sprintf("[%s][NOTICE] %s\n", $date, $message);
    echo $output;
}

//Outputs warning to stderr
function outputWarning($message)
{
    $date = date("Y/m/d H:i:s O");
    $output = sprintf("[%s][WARNING] %s\n", $date, $message);

    fwrite(STDERR, $output);
}

//Outputs error to Stderr
function outputStderr($message)
{
    $date = date("Y/m/d H:i:s O");
    $output = sprintf("[%s][ERROR] %s\n", $date, $message);

    fwrite(STDERR, $output);
}

//Returns current public IPv4 address.
function getCurrentPublicIPv4()
{
    $publicIP = rtrim(@file_get_contents('https://api.ipify.org'));

    //Let's check that this is really a IPv4 address, just in case...
    if (filter_var($publicIP, FILTER_VALIDATE_IP, FILTER_FLAG_IPV4)) {
        return $publicIP;
    }

    outputWarning("https://api.ipify.org didn't return a valid IPv4 address. Trying fallback API https://ip4.seeip.org");
    //If IP is invalid, try another API
    //The API adds an empty line, so we remove that with rtrim
    $publicIP = rtrim(@file_get_contents('https://ip4.seeip.org'));

    //Let's check the result of the second API
    if (filter_var($publicIP, FILTER_VALIDATE_IP, FILTER_FLAG_IPV4)) {
        return $publicIP;
    }

    //Still no valid IP?
    return false;
}

//Returns current public IPv6 address
function getCurrentPublicIPv6()
{
    $publicIP = rtrim(@file_get_contents('https://ip6.seeip.org'));

    if (filter_var($publicIP, FILTER_VALIDATE_IP, FILTER_FLAG_IPV6)) {
        return $publicIP;
    }

    outputWarning("https://ip6.seeip.org didn't return a valid IPv6 address.");
    //If IP is invalid, try another API
    $publicIP = rtrim(@file_get_contents('https://v6.ident.me/'));

    //Let's check the result of the second API
    if (filter_var($publicIP, FILTER_VALIDATE_IP, FILTER_FLAG_IPV6)) {
        return $publicIP;
    }

    //Still no valid IP?
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

    outputStderr(sprintf("Error while logging in: %s Exiting.", $result['longmessage']));
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

    outputStderr(sprintf("Error while logging out: %s Exiting.", $result['longmessage']));
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

    outputStderr(sprintf("Error while getting DNS Zone info: %s Exiting.", $result['longmessage']));
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

    outputStderr(sprintf("Error while getting DNS Record info: %s Exiting.", $result['longmessage']));
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

    outputStderr(sprintf("Error while updating DNS Zone: %s Exiting.", $result['longmessage']));
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

    outputStderr(sprintf("Error while updating DNS Records: %s Exiting.", $result['longmessage']));
    return false;
}
