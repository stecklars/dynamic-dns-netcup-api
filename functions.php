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

const IP_CACHE_FILE = '/ipcache';

// clears the ip cache
function clearIPCache()
{
    if (file_exists(sys_get_temp_dir().IP_CACHE_FILE)) {
        unlink(sys_get_temp_dir().IP_CACHE_FILE);
    }
}

// gets the public ipv4 and ipv6 addresses of the last successful run of the script 
function getIPCache()
{
    // check if cache file exists
    if (file_exists(sys_get_temp_dir().IP_CACHE_FILE)) {
        // parse cache file
        $ipcache = json_decode(file_get_contents(sys_get_temp_dir().IP_CACHE_FILE), TRUE);
        if ($ipcache === false) {
            outputWarning("Could not parse IP cache.");
        }
        return $ipcache;
    } else {
        outputStdout('No ip cache available');
        return false;
    }
}

// writes the current public ipv4 and ipv6 address to a cache file
function setIPCache($publicIPv4, $publicIPv6)
{
    $ipcache = [
    "ipv4" => $publicIPv4,
    "ipv6" => $publicIPv6,
    "timestamp" => date('Y-m-d H:i:s', time()),
    ];

    file_put_contents(sys_get_temp_dir().IP_CACHE_FILE, json_encode($ipcache));
}

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
    $publicIP = rtrim(file_get_contents('https://api.ipify.org'));

    //Let's check that this is really a IPv4 address, just in case...
    if (filter_var($publicIP, FILTER_VALIDATE_IP, FILTER_FLAG_IPV4 | FILTER_FLAG_NO_PRIV_RANGE | FILTER_FLAG_NO_RES_RANGE)) {
        return $publicIP;
    }

    outputWarning("https://api.ipify.org didn't return a valid IPv4 address. Trying fallback API https://ip4.seeip.org");
    //If IP is invalid, try another API
    //The API adds an empty line, so we remove that with rtrim
    $publicIP = rtrim(file_get_contents('https://ip4.seeip.org'));

    //Let's check the result of the second API
    if (filter_var($publicIP, FILTER_VALIDATE_IP, FILTER_FLAG_IPV4 | FILTER_FLAG_NO_PRIV_RANGE | FILTER_FLAG_NO_RES_RANGE)) {
        return $publicIP;
    }

    //Still no valid IP?
    return false;
}

function ipv6_to_binary($ip) {
    $result = '';
    foreach (unpack('C*', inet_pton($ip)) as $octet) {
        $result .= str_pad(decbin($octet), 8, "0", STR_PAD_LEFT);
    }
    return $result;
}

// returns the longest valid IPv6 address of the input addresses
function getLongestValidIPv6($ipv6addresses) {
  $ipv6information=shell_exec("ip -6 addr show ".IPV6_INTERFACE." | awk '{print $2}' | cut -ds -f1");
  $longestValidIPv6 = [
  "ipv6" => "::1",
  "validity" => "-1",
  ];
  foreach ($ipv6addresses as $currentIPv6address) {
   $validity = getValidityIPv6($ipv6information, $currentIPv6address);
   if($validity>$longestVAlidIPv6["validity"]) {
       $longestValidIPv6["ipv6"]=$currentIPv6address;
       $longestValidIPv6["validity"]=$validity;
   }
}
return $longestValidIPv6["ipv6"];
}

// returns the validity of the IPv6 address based on the output of "ip -6 addr show ".IPV6_INTERFACE." | awk '{print $2}' | cut -ds -f1"
function getValidityIPv6($ipv6information, $ipv6address)
{
    $lineNum = 1;
    $found = false;
    foreach(preg_split("/((\r?\n)|(\r\n?))/", $ipv6information) as $line) {
        if($found) {
            return($line);
        }
        if (strpos($line, $ipv6address) !== false) {
            $found=true;
        }
        $lineNum++;
    }
    return -1;
}

//Returns current public IPv6 address
function getCurrentPublicIPv6()
{
    $ipv6addresses = preg_split("/((\r?\n)|(\r\n?))/", shell_exec("ip -6 addr show ".IPV6_INTERFACE." | grep 'scope' | grep -Po '(?<=inet6 )[\da-z:]+'"));
    
    // filter non-valid, private and reserved range addresses
    $ipv6addresses = array_filter($ipv6addresses, function ($var) { return (filter_var($var, FILTER_VALIDATE_IP, FILTER_FLAG_IPV6 | FILTER_FLAG_NO_PRIV_RANGE | FILTER_FLAG_NO_RES_RANGE));});

    // filter non-EUI-64-Identifier addresses
    if (NO_IPV6_PRIVACY_EXTENSIONS) {
      $ipv6addresses = array_filter($ipv6addresses, function ($var) { return (strpos(ipv6_to_binary($var), '1111111111111110') === 88); });
  } else {
        // filter EUI-64-Identifier addresses
    $ipv6addresses = array_filter($ipv6addresses, function ($var) { return (strpos(ipv6_to_binary($var), '1111111111111110') !== 88); });
}

if (sizeof($ipv6addresses) === 1) {
    return($ipv6addresses[array_keys($ipv6addresses)[0]]);
} elseif (sizeof($ipv6addresses) > 1) {
    return(getLongestValidIPv6($ipv6addresses));
} else {
    outputWarning("Device didn't return a valid IPv6 address.");
}

    // no valid IP?
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
?>