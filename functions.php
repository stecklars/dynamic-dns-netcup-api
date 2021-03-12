<?php

//Declare possible options
$quiet = false;

//Check passed options
if(isset($argv)) {
    foreach($argv as $option) {
        if($option === "--quiet") {
            $quiet = true;
        }
    }
}

//Outputs $text to Stdout
function outputStdout($message): void {
    global $quiet;

    //If quiet option is set, don't output anything on stdout
    if($quiet === true) {
        return;
    }

    $date = date("Y/m/d H:i:s O");
    $output = sprintf("[%s][NOTICE] %s\n", $date, $message);
    echo $output;
}

//Outputs warning to stderr
function outputWarning($message): void {
    $date = date("Y/m/d H:i:s O");
    $output = sprintf("[%s][WARNING] %s\n", $date, $message);

    fwrite(STDERR, $output);
}

//Outputs error to Stderr
function outputStderr($message): void {
    $date = date("Y/m/d H:i:s O");
    $output = sprintf("[%s][ERROR] %s\n", $date, $message);

    fwrite(STDERR, $output);
}

//Returns current public IPv4 address.
function getCurrentPublicIPv4(): bool|string {
    $publicIP = rtrim(file_get_contents('https://api.ipify.org'));

    //Let's check that this is really a IPv4 address, just in case...
    if(filter_var($publicIP, FILTER_VALIDATE_IP, FILTER_FLAG_IPV4)) {
        return $publicIP;
    }

    outputWarning("https://api.ipify.org didn't return a valid IPv4 address. Trying fallback API https://ip4.seeip.org");
    //If IP is invalid, try another API
    //The API adds an empty line, so we remove that with rtrim
    $publicIP = rtrim(file_get_contents('https://ip4.seeip.org'));

    //Let's check the result of the second API
    if(filter_var($publicIP, FILTER_VALIDATE_IP, FILTER_FLAG_IPV4)) {
        return $publicIP;
    }

    //Still no valid IP?
    return false;
}

//Returns current public IPv6 address
function getCurrentPublicIPv6(): bool|string {
    $publicIP = rtrim(file_get_contents('https://ip6.seeip.org'));

    if(filter_var($publicIP, FILTER_VALIDATE_IP, FILTER_FLAG_IPV6)) {
        return $publicIP;
    }

    outputWarning("https://ip6.seeip.org didn't return a valid IPv6 address.");
    //If IP is invalid, try another API
    $publicIP = rtrim(file_get_contents('https://v6.ident.me/'));

    //Let's check the result of the second API
    if(filter_var($publicIP, FILTER_VALIDATE_IP, FILTER_FLAG_IPV6)) {
        return $publicIP;
    }

    //Still no valid IP?
    return false;
}
