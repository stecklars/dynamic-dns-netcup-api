<?php

//Constants
require_once 'config.php';
const SUCCESS = 'success';
const IP_CACHE_FILE = '/ipcache';

//Declare possbile options
$quiet = false;

//Check passed options
foreach ($argv as $option) {
    if ($option === "--quiet") {
        $quiet = true;
    }
}


/**
 * Clear IP Cache
 */
function clearIPCache()
{
    if (file_exists(sys_get_temp_dir().IP_CACHE_FILE)) {
        unlink(sys_get_temp_dir().IP_CACHE_FILE);
    }
}

/**
 * Get cached IPs from temp file
 * @return Array or false if it doesn't exists
 */
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

/**
 * Save passed IPs to temp file
 */
function setIPCache($publicIPv4, $publicIPv6)
{
    $ipcache = [
        "ipv4" => $publicIPv4,
        "ipv6" => $publicIPv6,
        "timestamp" => date('Y-m-d H:i:s', time()),
    ];

    file_put_contents(sys_get_temp_dir().IP_CACHE_FILE, json_encode($ipcache));
}

/**
 * Sends request to netcup Domain API and returns the result
 * @param request Request
 */
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

/**
 * Output passed string
 * @param message Message to output
 */
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

/**
 * Outputs warning to stderr
 * @param message Warning to output
 */
function outputWarning($message)
{
    $date = date("Y/m/d H:i:s O");
    $output = sprintf("[%s][WARNING] %s\n", $date, $message);

    fwrite(STDERR, $output);
}


/**
 * Outputs error to stderr
 * @param message Error to output
 */
function outputStderr($message)
{
    $date = date("Y/m/d H:i:s O");
    $output = sprintf("[%s][ERROR] %s\n", $date, $message);

    fwrite(STDERR, $output);
}

/**
 * Get public IPv4 from ipify.org
 * @return String Current public IPv4 address or false if no ip found
 */
function getCurrentPublicIPv4()
{
    $publicIP = rtrim(file_get_contents('https://api.ipify.org'));

    //Let's check that this is really an IPv4 address, just in case...
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

/**
 * Using UPnP to get public IPv4 from local FritzBox
 * @param fritzboxadress Adress to FritzBox
 * @return String current public IPv4 address or false if no ip found
 */
function getCurrentPublicIPv4FromFritzBox($fritzboxadress)
{
    $data = "<?xml version='1.0' encoding='utf-8'?> <s:Envelope s:encodingStyle='http://schemas.xmlsoap.org/soap/encoding/' xmlns:s='http://schemas.xmlsoap.org/soap/envelope/'> <s:Body> <u:GetExternalIPAddress xmlns:u='urn:schemas-upnp-org:service:WANIPConnection:1' /> </s:Body> </s:Envelope>";

    $ch = curl_init('http://'.$fritzboxadress.':49000/igdupnp/control/WANIPConn1');
    $curlOptions = array(
        CURLOPT_POST => 1,
        CURLOPT_RETURNTRANSFER => 1,
        CURLOPT_HTTPHEADER => array(
                                'Content-Type: text/xml',
                                'charset="utf-8"',
                                'SoapAction:urn:schemas-upnp-org:service:WANIPConnection:1#GetExternalIPAddress'
                                ),
        CURLOPT_POSTFIELDS => $data,
    );
    curl_setopt_array($ch, $curlOptions);

    $result = curl_exec($ch);
    curl_close ($ch);

    //search for IPv4 in result
    preg_match_all("/<NewExternalIPAddress>(.*)<\/NewExternalIPAddress>/i", $result, $match);

    if (!empty($match)) {
        return $match[1][0];
    }
    else {
        //fallback to ipify
        outputWarning("Can't get public IP from FritzBox at ".$fritzboxadress.". Fallback to ipify.");
        return getCurrentPublicIPv4();
    }
}

/**
 * Convert IPv6 to binary
 * @param ip IPv6
 */
function ipv6_to_binary($ip) {
    $result = '';
    foreach (unpack('C*', inet_pton($ip)) as $octet) {
        $result .= str_pad(decbin($octet), 8, "0", STR_PAD_LEFT);
    }
    return $result;
}

/**
 * Returns the longest valid IPv6 address of the input addresses
 * @param ipv6addresses array of IPv6 addresses
 * @return String longest valid IPv6 address of input addresses
 */
function getLongestValidIPv6($ipv6addresses) {
  $ipv6information=shell_exec("ip -6 addr show ".IPV6_INTERFACE." | awk '{print $2}' | cut -ds -f1");
  $longestValidIPv6 = [
  "ipv6" => "::1",
  "validity" => "-1",
  ];
  foreach ($ipv6addresses as $currentIPv6address) {
   $validity = getValidityIPv6($ipv6information, $currentIPv6address);
   if($validity>$longestValidIPv6["validity"]) {
       $longestValidIPv6["ipv6"]=$currentIPv6address;
       $longestValidIPv6["validity"]=$validity;
   }
}
return $longestValidIPv6["ipv6"];
}


/**
 * Returns the validity of the IPv6 address based on the output of "ip -6 addr show ".IPV6_INTERFACE." | awk '{print $2}' | cut -ds -f1"
 * @param ipv6information output of "ip -6 addr show ".IPV6_INTERFACE." | awk '{print $2}' | cut -ds -f1"
 * @param ipv6address the IPv6 address to get the validity of
 * @return String the validity of the input IPv6 address based on the input IPv6 information, -1 if validity could not be determined
 */
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

/**
 * Returns current public IPv6 address
 * @return String Current public IPv6 address or false if no ip found
 */
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

/**
 * Login into netcup domain API 
 * @param customernr Netcup Customer Number
 * @param apikey Api Key for Netcup domain Api
 * @param apipassword Api Password for Netcup domain Api
 * @return String Apisessionid
 */
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

/**
 * Logout of netcup domain API
 * @param customernr Netcup Customer Number
 * @param apikey Api Key for Netcup domain Api
 * @param apisessionid Api Session ID
 * @return Boolean for success
 */
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

/**
 * Get info about dns zone from netcup domain API
 * @param domainname Domain Name
 * @param apikey Api Key for Netcup domain Api
 * @param apisessionid Api Session ID
 * @return Array Result of Request or false
 */
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


/**
 * Get info about dns records from netcup domain API
 * @param domainname Domain Name
 * @param customernr Netcup Customer Number
 * @param apikey Api Key for Netcup domain Api
 * @return Array Result of Request or false
 */
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

/**
 * Updates DNS Zone using the netcup domain API
 * @param domainname Domain Name
 * @param customernr Netcup Customer Number
 * @param apikey Api Key for Netcup domain Api
 * @param apisessionid Api Session ID
 * @param $dnszone DNS Zone to update
 * @return Boolean for success
 */
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

/**
 * Updates DNS records using the netcup domain API
 * @param domainname Domain Name
 * @param customernr Netcup Customer Number
 * @param apikey Api Key for Netcup domain Api
 * @param apisessionid Api Session ID
 * @param dnsrecords DNS Record to update
 * @return Boolean for success
 */
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

/**
 * Updates the DNS A or AAAA record based on input IP address
 * @param infoDnsRecords the netcup DNS record info
 * @param publicIP the IP address to be updated via the API
 * @param apisessionid Api Key for Netcup domain Api
 * @return Boolean for success
 */
function updateIP($infoDnsRecords, $publicIP, $apisessionid)
{
    // set record type and ip type strings based on iput IP address type
    if (filter_var($publicIP, FILTER_VALIDATE_IP, FILTER_FLAG_IPV6)) {
        $recordType = "AAAA";
        $ipType = "IPv6";
	$hosts = explode (",", HOST_IPv6);
    } else {
        $recordType = "A";
        $ipType = "IPv4";
	$hosts = explode (",", HOST_IPv4);
    }

    //loop at hosts to update
    foreach ($hosts as $host) {
        $foundHosts = array();
        foreach ($infoDnsRecords['responsedata']['dnsrecords'] as $record) {
            if ($record['hostname'] === $host && $record['type'] === $recordType) {
                $foundHosts[] = array(
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
        if (count($foundHosts) === 0) {
            outputStdout(sprintf($recordType." record for host %s doesn't exist, creating necessary DNS record.", $host));
            $foundHosts[] = array(
                'hostname' => $host,
                'type' => $recordType,
                'destination' => 'newly created Record',
                );
        }

        //If the host with A/AAAA record exists more than one time...
        if (count($foundHosts) > 1) {
            outputStderr(sprintf("Found multiple ".$recordType." records for the host %s – Please specify a host for which only a single ".$recordType." record exists in config.php. Exiting.", $host));
            exit(1);
        }       

        //Has the IP changed?
        foreach ($foundHosts as $record) {
            if ($record['destination'] !== $publicIP) {
                //Yes, it has changed.
                outputStdout(sprintf($ipType." address has changed. Before: %s; Now: %s", $record['destination'], $publicIP));
                $foundHosts[0]['destination'] = $publicIP;
                //Update the record
                if (updateDnsRecords(DOMAIN, CUSTOMERNR, APIKEY, $apisessionid, $foundHosts)) {
                    outputStdout($ipType." address updated successfully!");
                } else {
                    // clear ip cache in order to reconnect to API in any case on next run of script
                    clearIPCache();
                }
            } else {
                //No, it hasn't changed.
                outputStdout(sprintf($ipType." for host %s address hasn't changed. Current ".$ipType." address: ".$publicIP, $host));
            }
        }
    }
}
?>
