<?php

const VERSION = '6.1';
const SUCCESS = 'success';
const USERAGENT = "dynamic-dns-netcup-api/" . VERSION ." (by stecklars)";

$quiet = false;
$forceUpdate = false;

//Check passed options
$shortopts = "q4:6:c:vhf";
$longopts = array(
    "quiet",
    "ipv4:",
    "ipv6:",
    "config:",
    "version",
    "help",
    "force"
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
| -q           | --quiet            | The script won't output notices or warnings, only errors  |
| -c           | --config           | Manually provide a path to the config file                |
| -4           | --ipv4             | Manually provide the IPv4 address to set                  |
| -6           | --ipv6             | Manually provide the IPv6 address to set                  |
| -f           | --force            | Force update, bypassing the IP cache                      |
| -h           | --help             | Outputs this help                                         |
| -v           | --version          | Outputs the current version of the script                 |\n\n";
    exit();
}
if (isset($options['quiet']) || isset($options['q'])) {
    $quiet = true;
}
if (isset($options['force']) || isset($options['f'])) {
    $forceUpdate = true;
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
        CURLOPT_USERAGENT => USERAGENT,
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
// $ipResolve can be CURL_IPRESOLVE_V4 or CURL_IPRESOLVE_V6 to force the
// connection to use a specific IP version, preventing dual-stack servers
// from returning the wrong address type.
function initializeCurlHandlerGetIP($url, $ipResolve = CURL_IPRESOLVE_WHATEVER)
{
    $ch = curl_init($url);
    $curlOptions = array(
        CURLOPT_USERAGENT => USERAGENT,
        CURLOPT_TIMEOUT => 30,
        CURLOPT_RETURNTRANSFER => 1,
        CURLOPT_FAILONERROR => 1,
        CURLOPT_IPRESOLVE => $ipResolve
    );
    curl_setopt_array($ch, $curlOptions);
    return $ch;
}

// Executes a curl request with retries. Returns the result string on success, or false after all attempts are exhausted.
function executeCurlWithRetries($ch, $retryLimit = 3)
{
    $accessed_url = curl_getinfo($ch)['url'];

    $result = curl_exec($ch);
    if (!curl_errno($ch) && $result !== false) {
        return $result;
    }

    $retrySleep = defined('RETRY_SLEEP') ? RETRY_SLEEP : 30;

    for ($attempt = 1; $attempt < $retryLimit; $attempt++) {
        if (curl_errno($ch)) {
            outputWarning(sprintf(
                "cURL Error while accessing %s: (%d) %s - Retrying in %d seconds. (Try %d / %d)",
                $accessed_url, curl_errno($ch), curl_error($ch), $retrySleep, $attempt, $retryLimit
            ));
        } else {
            outputWarning("API at $accessed_url returned invalid answer. Retrying in $retrySleep seconds. (Try $attempt / $retryLimit)");
        }

        sleep($retrySleep);
        outputWarning("Retrying now.");
        $result = curl_exec($ch);

        if (!curl_errno($ch) && $result !== false) {
            return $result;
        }
    }

    if (curl_errno($ch)) {
        outputWarning(sprintf(
            "cURL Error while accessing %s: (%d) %s (Try %d / %d)",
            $accessed_url, curl_errno($ch), curl_error($ch), $retryLimit, $retryLimit
        ));
    }

    return false;
}

// Sends $request to netcup Domain API and returns the result
function sendRequest($request, $apiSessionRetry = false)
{
    $ch = initializeCurlHandlerPostNetcupAPI($request);
    $result = executeCurlWithRetries($ch);

    if ($result === false) {
        outputStderr("Max retries reached. Exiting due to cURL network error.");
        @curl_close($ch);
        exit(1);
    }

    $result = json_decode($result, true);

    // Clean up API error messages: collapse newlines and excessive whitespace
    // into single spaces (the netcup API sometimes returns messages with
    // trailing newlines and padding whitespace)
    if (isset($result['longmessage'])) {
        $result['longmessage'] = trim(preg_replace('/\s+/', ' ', $result['longmessage']));
    }
    if (isset($result['shortmessage'])) {
        $result['shortmessage'] = trim(preg_replace('/\s+/', ' ', $result['shortmessage']));
    }

    // Due to a bug in the netcup CCP DNS API, sometimes sessions expire too early (statuscode 4001, error message: "The session id is not in a valid format.")
    // We work around this bug by trying to login again once.
    // See Github issue #21.
    if ($result['statuscode'] === 4001 && $apiSessionRetry === false) {
        @curl_close($ch);
        outputWarning("Received API error 4001: The session id is not in a valid format. Most likely the session expired. Logging in again and retrying once.");
        $newApisessionid = login(CUSTOMERNR, APIKEY, APIPASSWORD);

        global $apisessionid;
        $apisessionid = $newApisessionid;

        $request = json_decode($request, true);
        $request['param']['apisessionid'] = $newApisessionid;
        $request = json_encode($request);

        return sendRequest($request, true);
    }

    @curl_close($ch);

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

    $domainlist = array();
    $domainsExploded = explode(';', $domains);
    foreach ($domainsExploded as $element) {
        $arr = explode(':', $element);
        $domainlist[$arr[0]] = $arr[1];
    }

    $result = array();
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

// Fetches IP address from primary URL with retries, falls back to fallback URL if validation fails.
// Retries on both cURL errors and invalid IP responses (e.g. service returning an error page).
// $validator is a callable that returns true if the IP string is valid.
function fetchIPWithFallback($primaryUrl, $fallbackUrl, $validator, $ipResolve = CURL_IPRESOLVE_WHATEVER)
{
    $retryLimit = 3;
    $retrySleep = defined('RETRY_SLEEP') ? RETRY_SLEEP : 30;

    foreach ([$primaryUrl, $fallbackUrl] as $index => $url) {
        $ch = initializeCurlHandlerGetIP($url, $ipResolve);

        for ($attempt = 0; $attempt < $retryLimit; $attempt++) {
            if ($attempt > 0) {
                if (curl_errno($ch)) {
                    outputWarning(sprintf(
                        "cURL Error while accessing %s: (%d) %s - Retrying in %d seconds. (Try %d / %d)",
                        $url, curl_errno($ch), curl_error($ch), $retrySleep, $attempt, $retryLimit
                    ));
                } else {
                    outputWarning("$url didn't return a valid IP address. Retrying in $retrySleep seconds. (Try $attempt / $retryLimit)");
                }
                sleep($retrySleep);
                outputWarning("Retrying now.");
            }

            $result = curl_exec($ch);

            if (!curl_errno($ch) && $result !== false) {
                $publicIP = trim($result);
                if ($validator($publicIP)) {
                    @curl_close($ch);
                    return $publicIP;
                }
            }
        }

        @curl_close($ch);

        if ($index === 0) {
            outputWarning("$primaryUrl didn't return a valid IP address. Trying fallback $fallbackUrl");
        }
    }

    return false;
}

//Returns current public IPv4 address.
function getCurrentPublicIPv4()
{
    global $providedIPv4;
    if (isset($providedIPv4)) {
        outputStdout(sprintf('Using manually provided IPv4 address "%s"', $providedIPv4));
        return $providedIPv4;
    }

    outputStdout('Getting IPv4 address from ' . IPV4_ADDRESS_URL . '.');
    return fetchIPWithFallback(IPV4_ADDRESS_URL, IPV4_ADDRESS_URL_FALLBACK, 'isIPV4Valid', CURL_IPRESOLVE_V4);
}

//Returns current public IPv6 address
function getCurrentPublicIPv6()
{
    global $providedIPv6;
    if (isset($providedIPv6)) {
        outputStdout(sprintf('Using manually provided IPv6 address "%s"', $providedIPv6));
        return $providedIPv6;
    }

    outputStdout('Getting IPv6 address from ' . IPV6_ADDRESS_URL . '.');
    return fetchIPWithFallback(IPV6_ADDRESS_URL, IPV6_ADDRESS_URL_FALLBACK, 'isIPV6Valid', CURL_IPRESOLVE_V6);
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

//Finds, creates, or updates a DNS record for a given subdomain and record type (A or AAAA).
function updateDnsRecordsForIP($infoDnsRecords, $subdomain, $domain, $apisessionid, $recordType, $publicIP)
{
    $ipVersion = ($recordType === 'A') ? 'IPv4' : 'IPv6';

    $foundHosts = array();

    foreach ($infoDnsRecords['responsedata']['dnsrecords'] as $record) {
        if ($record['hostname'] === $subdomain && $record['type'] === $recordType) {
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

    if (count($foundHosts) === 0) {
        outputStdout(sprintf("%s record for host %s doesn't exist, creating necessary DNS record.", $recordType, $subdomain));
        $foundHosts[] = array(
            'hostname' => $subdomain,
            'type' => $recordType,
            'destination' => 'newly created Record',
        );
    }

    if (count($foundHosts) > 1) {
        outputStderr(sprintf("Found multiple %s records for the host %s – Please specify a host for which only a single %s record exists in config.php. Exiting.", $recordType, $subdomain, $recordType));
        exit(1);
    }

    $ipChanged = false;

    foreach ($foundHosts as $record) {
        if ($record['destination'] !== $publicIP) {
            $ipChanged = true;
            outputStdout(sprintf("%s address has changed. Before: %s; Now: %s", $ipVersion, $record['destination'], $publicIP));
        } else {
            outputStdout(sprintf("%s address hasn't changed. Current %s address: %s", $ipVersion, $ipVersion, $publicIP));
        }
    }

    if ($ipChanged === true) {
        $foundHosts[0]['destination'] = $publicIP;
        if (updateDnsRecords($domain, CUSTOMERNR, APIKEY, $apisessionid, $foundHosts)) {
            outputStdout(sprintf("%s address updated successfully!", $ipVersion));
        } else {
            exit(1);
        }
    }
}
