<?php

use Netcup\API;
use Netcup\Model\DnsRecord;
use Netcup\Model\Domain;

//Load necessary functions
require_once './vendor/autoload.php';
require_once './config.php';
require_once './functions.php';

outputStdout("=============================================");
outputStdout("Running dynamic DNS client for netcup 2.0");
outputStdout("This script is not affiliated with netcup.");
outputStdout("=============================================\n");

outputStdout(sprintf("Updating DNS records for host %s on domain %s\n", HOST, DOMAIN));

// Let's get infos about the DNS zone
$domain = DynDns::getAPI()->infoDomain(DOMAIN);

DynDns::checkAndUpdateTTL($domain);
DynDns::doIPv4Update($domain);
DynDns::doIPv6Update($domain);

if(DynDns::getAPI()->logout()) {
    outputStdout("Logged out successfully!");
}

class DynDns {

    private static API|null $api = null;

    public static function getAPI(): API {
        if(self::$api == null) {
            self::$api = new API(APIKEY, APIPASSWORD, CUSTOMERNR);
            if(self::$api->isLoggedIn()) {
                outputStdout("Logged in successfully!");
            } else {
                exit(1);
            }
        }
        return self::$api;
    }

    public static function checkAndUpdateTTL(Domain $domain) {
        $infoDnsZoneResponse = self::$api->infoDnsZone($domain->getDomainName());
        if(!$infoDnsZoneResponse->wasSuccessful()) {
            outputStderr(sprintf("Error while getting DNS Zone info: %s Exiting.", $infoDnsZoneResponse->getLongMessage()));
            exit(1);
        }
        outputStdout("Successfully received Domain info.");

        //TTL Warning
        if(CHANGE_TTL !== true && $infoDnsZoneResponse->getData()->ttl > 300) {
            outputStdout("TTL is higher than 300 seconds - this is not optimal for dynamic DNS, since DNS updates will take a long time. Ideally, change TTL to lower value. You may set CHANGE_TTL to True in config.php, in which case TTL will be set to 300 seconds automatically.");
        }

        //If user wants it, then we lower TTL, in case it doesn't have correct value
        if(CHANGE_TTL === true && $infoDnsZoneResponse->getData()->ttl !== "300") {
            $payload = $infoDnsZoneResponse->getData();
            $payload->ttl = 300;
            $updateDnsZoneResponse = self::$api->updateDnsZone($domain->getDomainName(), $payload);

            if($updateDnsZoneResponse->wasSuccessful()) {
                outputStdout("Lowered TTL to 300 seconds successfully.");
            } else {
                outputStderr(sprintf("Error while updating DNS Zone: %s", $updateDnsZoneResponse->getLongMessage()));
                outputStderr("Failed to set TTL... Continuing.");
            }
        }
    }

    public static function doIPv4Update(Domain $domain) {
        //Find the host defined in config.php
        $foundHostsV4 = array();

        //Let's get the DNS record data.
        $dnsRecords = DynDns::getAPI()->infoDnsRecords(DOMAIN);
        foreach($dnsRecords as $record) {
            if($record->getHostname() == HOST && $record->getType() === "A") {
                $foundHostsV4[] = $record;
            }
        }

        //If we couldn't determine a valid public IPv4 address
        if(!$publicIPv4 = getCurrentPublicIPv4()) {
            outputStderr("Main API and fallback API didn't return a valid IPv4 address. Exiting.");
            exit(1);
        }

        //If we can't find the host, create it.
        if(count($foundHostsV4) === 0) {
            outputStdout(sprintf("A record for host %s doesn't exist, creating necessary DNS record.", HOST));
            $res = $domain->createNewDnsRecord(new DnsRecord(hostname: HOST, type: 'A', destination: $publicIPv4));
            if($res) {
                outputStdout(sprintf("A record for host %s was created successfully.", HOST));
            } else {
                outputStdout(sprintf("There was an error while creating A record for host %s.", HOST));
            }
            return;
        }

        //If the host with A record exists more than one time...
        if(count($foundHostsV4) > 1) {
            outputStderr(sprintf("Found multiple A records for the host %s – Please specify a host for which only a single A record exists in config.php. Exiting.", HOST));
            exit(1);
        }

        $recordToChange = $foundHostsV4[0];
        if($recordToChange->getDestination() == $publicIPv4) {
            outputStdout("IPv4 address hasn't changed. Current IPv4 address: " . $publicIPv4);
            return;
        }
        outputStdout(sprintf("IPv4 address has changed. Before: %s; Now: %s", $recordToChange->getDestination(), $publicIPv4));
        $res = $recordToChange->update(destination: $publicIPv4);
        if(!$res) {
            outputStderr("There was an error while updating IPv4 address!");
            return;
        }
        outputStdout("IPv4 address updated successfully!");
    }

    public static function doIPv6Update(Domain $domain) {
        if(USE_IPV6 !== true) {
            return;
        }
        //Find the host defined in config.php
        $foundHostsV6 = array();

        //Let's get the DNS record data.
        $dnsRecords = DynDns::getAPI()->infoDnsRecords(DOMAIN);
        foreach($dnsRecords as $record) {
            if($record->getHostname() == HOST && $record->getType() === "AAAA") {
                $foundHostsV6[] = $record;
            }
        }

        //If we couldn't determine a valid public IPv6 address
        if(!$publicIPv6 = getCurrentPublicIPv6()) {
            outputStderr("Main API and fallback API didn't return a valid IPv6 address. Exiting.");
            exit(1);
        }

        //If we can't find the host, create it.
        if(count($foundHostsV6) === 0) {
            outputStdout(sprintf("AAAA record for host %s doesn't exist, creating necessary DNS record.", HOST));
            $res = $domain->createNewDnsRecord(new DnsRecord(hostname: HOST, type: 'AAAA', destination: $publicIPv6));
            if($res) {
                outputStdout(sprintf("AAAA record for host %s was created successfully.", HOST));
            } else {
                outputStdout(sprintf("There was an error while creating AAAA record for host %s.", HOST));
            }
            return;
        }

        //If the host with A record exists more than one time...
        if(count($foundHostsV6) > 1) {
            outputStderr(sprintf("Found multiple AAAA records for the host %s – Please specify a host for which only a single AAAA record exists in config.php. Exiting.", HOST));
            exit(1);
        }

        $recordToChange = $foundHostsV6[0];
        if($recordToChange->getDestination() == $foundHostsV6) {
            outputStdout("IPv6 address hasn't changed. Current IPv6 address: " . $publicIPv6);
            return;
        }
        outputStdout(sprintf("IPv6 address has changed. Before: %s; Now: %s", $recordToChange->getDestination(), $publicIPv6));
        $res = $recordToChange->update(destination: $publicIPv6);
        if(!$res) {
            outputStderr("There was an error while updating IPv6 address!");
            return;
        }
        outputStdout("IPv6 address updated successfully!");
    }

}