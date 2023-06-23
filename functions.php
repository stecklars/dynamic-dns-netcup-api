<?php

const VERSION = '4.0';
const SUCCESS = 'success';


//Check passed options
$shortopts = "q4:6:c:vh";
$longopts = array(
    "quiet",
    "ipv4:",
    "ipv6:",
    "config:",
    "version",
    "help"
);
$options = getopt($shortopts, $longopts);
if (isset($options['version']) || isset($options['v'])) {
    echo "Dynamic DNS client for netcup ".VERSION."\n";
    echo "This script is not affiliated with netcup.\n";
    exit();
}
if (isset($options['help']) || isset($options['h'])) {
    echo "\n";
    echo "Dynamic DNS client for netcup ".VERSION."\n";
    echo "This script is not affiliated with netcup.\n";
    echo "\n| short option | long option        | function                                                  |
| ------------ | ------------------ |----------------------------------------------------------:|
| -q           | --quiet            | The script won't output notices, only errors and warnings |
| -c           | --config           | Manually provide a path to the config file                |
| -4           | --ipv4             | Manually provide the IPv4 address to set                  |
| -6           | --ipv6             | Manually provide the IPv6 address to set                  |
| -h           | --help             | Outputs this help                                         |
| -v           | --version          | Outputs the current version of the script                 |\n\n";
    exit();
}
if (isset($options['quiet']) || isset($options['q'])) {
    $quiet = true;
}
if (isset($options['ipv4']) || isset($options[4])) {
    $providedIPv4 = isset($options[4]) ? $options[4] : $options["ipv4"];
    if (!isIPV4Valid($providedIPv4)) {
        outputStderr(sprintf('Manually provided IPv4 address "%s" is invalid. Exiting.', $providedIPv4));
        exit(1);
    }
}
if (isset($options['ipv6']) || isset($options[6])) {
    $providedIPv6 = isset($options[6]) ? $options[6] : $options["ipv6"];
    if (!isIPv6Valid($providedIPv6)) {
        outputStderr(sprintf('Manually provided IPv6 address "%s" is invalid. Exiting.', $providedIPv6));
        exit(1);
    }
}
if (isset($options['config']) || isset($options['c'])) {
    $configFilePath = isset($options['c']) ? $options['c'] : $options['config'];
} else {
    // If user does not supply an option on the CLI, we will use the default location.
    $configFilePath = __DIR__ . '/config.php';
}

// Load config file
if (!include_once($configFilePath)) {
    outputStderr(sprintf('Could not open config.php at "%s". Please follow the getting started guide and provide a valid config.php file. Exiting.', $configFilePath));
    exit(1);
}


//Checks if curl PHP extension is installed
function _is_curl_installed()
{
    if (in_array('curl', get_loaded_extensions())) {
        return true;
    } else {
        return false;
    }
}

// Create cURL handler for posting to the netcup CCP API
function initializeCurlHandlerPostNetcupAPI($request)
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
    return $ch;
}

// Create cURL handler for get requests (for getting the current public IP)
function initializeCurlHandlerGetIP($url)
{
    $ch = curl_init($url);
    $curlOptions = array(
        CURLOPT_TIMEOUT => 30,
        CURLOPT_RETURNTRANSFER => 1,
        CURLOPT_FAILONERROR => 1
    );
    curl_setopt_array($ch, $curlOptions);
    return $ch;
}

// Check if curl request was successful
function wasCurlSuccessful($ch)
{
    if (curl_errno($ch)) {
        return false;
    }
    return true;
}

// Retrys a curl request for the specified amount of retries after a failure
function retryCurlRequest($ch, $tryCount, $tryLimit)
{
    $accessed_url = curl_getinfo($ch)['url'];

    if (curl_errno($ch)) {
        $curl_errno = curl_errno($ch);
        $curl_error_msg = curl_error($ch);
    }

    if (curl_errno($ch)) {
        if ($tryCount === 1) {
            outputWarning("cURL Error while accessing $accessed_url: ($curl_errno) $curl_error_msg - Retrying in 30 seconds. (Try $tryCount / $tryLimit)");
        }
    } else {
        outputWarning("API at $accessed_url returned invalid answer. Retrying in 30 seconds. (Try $tryCount / $tryLimit)");
    }
    sleep(30);
    outputWarning("Retrying now.");
    $result = curl_exec($ch);
    if (curl_errno($ch)) {
        $curl_errno = curl_errno($ch);
        $curl_error_msg = curl_error($ch);
        $tryCount++;
        if (curl_errno($ch)) {
            outputWarning("cURL Error while accessing $accessed_url: ($curl_errno) $curl_error_msg - Retrying in 30 seconds. (Try $tryCount / $tryLimit)");
        }
        return false;
    } else {
        unset($curl_errno);
        unset($curl_error_msg);
        return $result;
    }
}

// Sends $request to netcup Domain API and returns the result
function sendRequest($request)
{
    $ch = initializeCurlHandlerPostNetcupAPI($request);
    $result = curl_exec($ch);

    if (!wasCurlSuccessful($ch)) {
        $retryCount = 1;
        $retryLimit = 3;
        while (!$result && $retryCount < $retryLimit) {
            $result = retryCurlRequest($ch, $retryCount, $retryLimit);
            $retryCount++;
        }
    }

    if ($result === false) {
        outputStderr("Max retries reached ($retryCount / $retryLimit). Exiting due to cURL network error.");
        exit(1);
    }

    // If everything seems to be ok, proceed...
    curl_close($ch);
    unset($ch);

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
    global $quiet;

    //If quiet option is set, don't output anything on stderr
    if ($quiet === true) {
        return;
    }

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

//Returns list of domains with their subdomains for which we are supposed to perform changes
function getDomains()
{
    if (! defined('DOMAINLIST')) {
        outputWarning("You are using an outdated configuration format (for configuring domain / host). This is deprecated and might become incompatible very soon. Please update to the new configuration format (using 'DOMAINLIST'). Please check the documentation in config.dist.php for more information.");
        if (! defined('DOMAIN')) {
            outputStderr("Your configuration file is incorrect. You did not configure any domains ('DOMAINLIST' or 'DOMAIN' option (deprecated) in the config). Please check the documentation in config.dist.php. Exiting.");
            exit(1);
        }
        if (! defined('HOST')) {
            outputStderr("Your configuration file is incorrect. You did not configure any hosts (subdomains; 'HOST' option in the config). Please check the documentation in config.dist.php. Exiting.");
            exit(1);
        }
        return array(DOMAIN => array(HOST));
    }

    $domains = preg_replace('/\s+/', '', DOMAINLIST);

    $domainsExploded = explode(';', $domains);
    foreach ($domainsExploded as $element) {
        $arr = explode(':', $element);
        $domainlist[$arr[0]] = $arr[1];
    }

    foreach ($domainlist as $domain => $subdomainlist) {
        $subdomainarray = explode(',', $subdomainlist);
        $result[$domain] = $subdomainarray;
    }

    return $result;
}

function isIPV4Valid($ipv4)
{
    if (filter_var($ipv4, FILTER_VALIDATE_IP, FILTER_FLAG_IPV4)) {
        return true;
    } else {
        return false;
    }
}

function isIPV6Valid($ipv6)
{
    if (filter_var($ipv6, FILTER_VALIDATE_IP, FILTER_FLAG_IPV6)) {
        return true;
    } else {
        return false;
    }
}

//Returns current public IPv4 address.
function getCurrentPublicIPv4()
{
    // If user provided an IPv4 address manually as a CLI option
    global $providedIPv4;
    if (isset($providedIPv4)) {
        outputStdout(sprintf('Using manually provided IPv4 address "%s"', $providedIPv4));
        return $providedIPv4;
    }

    outputStdout('Getting IPv4 address from API.');

    $url = 'https://api.ipify.org';
    $ch = initializeCurlHandlerGetIP($url);
    $publicIP = trim(curl_exec($ch));

    if (!wasCurlSuccessful($ch) || !isIPV4Valid($publicIP)) {
        $retryCount = 1;
        $retryLimit = 3;
        while ((!$publicIP || !isIPV4Valid($publicIP)) && $retryCount < $retryLimit) {
            $publicIP = trim(retryCurlRequest($ch, $retryCount, $retryLimit));
            $retryCount++;
        }

        if (!isIPV4Valid($publicIP) || $publicIP === false) {
            outputWarning("https://api.ipify.org didn't return a valid IPv4 address (Try $retryCount / $retryLimit). Trying fallback API https://ipv4.seeip.org");
            $url = 'https://ipv4.seeip.org';
            $ch = initializeCurlHandlerGetIP($url);
            $publicIP = trim(curl_exec($ch));
            if (!wasCurlSuccessful($ch) || !isIPV4Valid($publicIP)) {
                $retryCount = 1;
                $retryLimit = 3;
                while ((!$publicIP || !isIPV4Valid($publicIP)) && $retryCount < $retryLimit) {
                    $publicIP = trim(retryCurlRequest($ch, $retryCount, $retryLimit));
                    $retryCount++;
                }
                if (!isIPV4Valid($publicIP) || $publicIP === false) {
                    return false;
                }
            }
        }
    }
    curl_close($ch);
    unset($ch);
    return $publicIP;
}

//Returns current public IPv6 address
function getCurrentPublicIPv6()
{
    // If user provided an IPv6 address manually as a CLI option
    global $providedIPv6;
    if (isset($providedIPv6)) {
        outputStdout(sprintf('Using manually provided IPv6 address "%s"', $providedIPv6));
        return $providedIPv6;
    }

    outputStdout('Getting IPv6 address from API.');

    $url = 'https://ipv6.seeip.org';
    $ch = initializeCurlHandlerGetIP($url);
    $publicIP = trim(curl_exec($ch));

    if (!wasCurlSuccessful($ch) || !isIPV6Valid($publicIP)) {
        $retryCount = 1;
        $retryLimit = 3;
        while ((!$publicIP || !isIPV6Valid($publicIP)) && $retryCount < $retryLimit) {
            $publicIP = trim(retryCurlRequest($ch, $retryCount, $retryLimit));
            $retryCount++;
        }

        if (!isIPV6Valid($publicIP) || $publicIP === false) {
            outputWarning("https://ipv6.seeip.org didn't return a valid IPv6 address (Try $retryCount / $retryLimit). Trying fallback API https://v6.ident.me/");
            $url = 'https://v6.ident.me/';
            $ch = initializeCurlHandlerGetIP($url);
            $publicIP = trim(curl_exec($ch));
            if (!wasCurlSuccessful($ch) || !isIPV6Valid($publicIP)) {
                $retryCount = 1;
                $retryLimit = 3;
                while ((!$publicIP || !isIPV6Valid($publicIP)) && $retryCount < $retryLimit) {
                    $publicIP = trim(retryCurlRequest($ch, $retryCount, $retryLimit));
                    $retryCount++;
                }
                if (!isIPV6Valid($publicIP) || $publicIP === false) {
                    return false;
                }
            }
        }
    }
    curl_close($ch);
    unset($ch);
    return $publicIP;
}

//Login into netcup domain API and returns Apisessionid
function login($customernr, $apikey, $apipassword)
{
    outputStdout("Logging into netcup CCP DNS API.");

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

    // Error from API: "More than 180 requests per minute. Please wait and retry later. Please contact our customer service to find out if the limitation of requests can be increased."
    if ($result['statuscode'] === 4013) {
        $result['longmessage'] = $result['longmessage'] . ' [ADDITIONAL INFORMATION: This error from the netcup DNS API also often indicates that you have supplied wrong API credentials. Please check them in the config file.]';
    }

    outputStderr(sprintf("Error while logging in: %s Exiting.", $result['longmessage']));
    return false;
}

//Logout of netcup domain API, returns boolean
function logout($customernr, $apikey, $apisessionid)
{
    outputStdout("Logging out from netcup CCP DNS API.");
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
    outputStdout(sprintf('Getting Domain info for "%s".', $domainname));

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
    outputStdout(sprintf('Getting DNS records data for "%s".', $domainname));

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
    outputStdout(sprintf('Updating DNS zone for "%s".', $domainname));

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
    outputStdout(sprintf('Updating DNS records for "%s".', $domainname));

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
