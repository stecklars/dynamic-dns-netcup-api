#!/usr/bin/env php
<?php

function failHealthcheck($message)
{
    fwrite(STDERR, $message . PHP_EOL);
    exit(1);
}

function getEnvValue($name, $default = null)
{
    $value = getenv($name);
    if ($value === false || $value === '') {
        return $default;
    }

    return $value;
}

function getAppDir()
{
    return getEnvValue('APP_DIR', __DIR__);
}

function getDataDir()
{
    return getEnvValue('DATA_DIR', getAppDir() . '/data');
}

function getHeartbeatPath()
{
    return getEnvValue('HEALTHCHECK_FILE', getDataDir() . '/last_success.json');
}

function getNowTimestamp()
{
    $override = getEnvValue('HEALTHCHECK_NOW');
    if ($override === null) {
        return time();
    }

    if (preg_match('/^-?\d+$/', $override)) {
        return (int) $override;
    }

    $dateTime = date_create_immutable($override);
    if ($dateTime === false) {
        failHealthcheck(sprintf('Invalid HEALTHCHECK_NOW value "%s".', $override));
    }

    return $dateTime->getTimestamp();
}

function formatTimestamp($timestamp)
{
    return date(DATE_ATOM, $timestamp);
}

function initializeTimezone()
{
    $timezoneName = getEnvValue('TZ');
    if ($timezoneName !== null) {
        if (!@date_default_timezone_set($timezoneName)) {
            failHealthcheck(sprintf('Invalid TZ value "%s".', $timezoneName));
        }
    }

    return new DateTimeZone(date_default_timezone_get());
}

function resolveConfigPath()
{
    $appDir = getAppDir();
    $candidates = array(
        getEnvValue('CONFIG_PATH'),
        $appDir . '/config.docker.php',
        $appDir . '/config.php',
    );

    foreach ($candidates as $candidate) {
        if ($candidate !== null && is_file($candidate)) {
            return $candidate;
        }
    }

    return null;
}

function loadDockerConfigIfAvailable()
{
    $configPath = resolveConfigPath();
    if ($configPath !== null) {
        include_once $configPath;
    }
}

function getGraceSeconds()
{
    $override = getEnvValue('HEALTHCHECK_GRACE_SECONDS');
    if ($override !== null) {
        if (!preg_match('/^\d+$/', $override)) {
            failHealthcheck(sprintf('Invalid HEALTHCHECK_GRACE_SECONDS value "%s".', $override));
        }

        return (int) $override;
    }

    $jitterMax = defined('JITTER_MAX') ? (int) JITTER_MAX : 30;
    return $jitterMax + 120;
}

function writeHeartbeat()
{
    $heartbeatPath = getHeartbeatPath();
    $directory = dirname($heartbeatPath);

    if (!is_dir($directory) && !mkdir($directory, 0777, true) && !is_dir($directory)) {
        failHealthcheck(sprintf('Could not create heartbeat directory "%s".', $directory));
    }

    $timestamp = getNowTimestamp();
    $payload = json_encode(array(
        'timestamp' => $timestamp,
        'datetime' => formatTimestamp($timestamp),
    ));

    if ($payload === false) {
        failHealthcheck(sprintf('Could not encode heartbeat payload for "%s".', $heartbeatPath));
    }

    // Write to a sibling tmp file and rename it into place. file_put_contents
    // truncates the destination first, so a healthcheck that fires between
    // the truncate and the write would otherwise observe an empty file and
    // declare the container unhealthy. rename() is atomic on POSIX as long
    // as both paths share a filesystem (we keep them in the same directory).
    $tmpPath = $heartbeatPath . '.tmp';
    if (file_put_contents($tmpPath, $payload) === false) {
        failHealthcheck(sprintf('Could not write heartbeat tmp file "%s".', $tmpPath));
    }

    if (!rename($tmpPath, $heartbeatPath)) {
        @unlink($tmpPath);
        failHealthcheck(sprintf('Could not rename heartbeat tmp file to "%s".', $heartbeatPath));
    }
}

function readHeartbeatTimestamp()
{
    $heartbeatPath = getHeartbeatPath();
    if (!is_file($heartbeatPath)) {
        failHealthcheck(sprintf('Heartbeat file "%s" does not exist yet.', $heartbeatPath));
    }

    $contents = file_get_contents($heartbeatPath);
    if ($contents === false) {
        failHealthcheck(sprintf('Could not read heartbeat file "%s".', $heartbeatPath));
    }

    $contents = trim($contents);
    if ($contents === '') {
        failHealthcheck(sprintf('Heartbeat file "%s" is empty.', $heartbeatPath));
    }

    if (preg_match('/^-?\d+$/', $contents)) {
        return (int) $contents;
    }

    $decoded = json_decode($contents, true);
    if (!is_array($decoded) || !isset($decoded['timestamp']) || !is_numeric($decoded['timestamp'])) {
        failHealthcheck(sprintf('Heartbeat file "%s" has invalid contents.', $heartbeatPath));
    }

    return (int) $decoded['timestamp'];
}

function resolveCronValue($rawValue, $aliases = array())
{
    $rawValue = strtoupper(trim($rawValue));
    if ($rawValue === '') {
        return false;
    }

    if (isset($aliases[$rawValue])) {
        return $aliases[$rawValue];
    }

    if (!preg_match('/^\d+$/', $rawValue)) {
        return false;
    }

    return (int) $rawValue;
}

function normalizeCronValue($value, $normalizeDayOfWeek = false)
{
    if ($normalizeDayOfWeek && $value === 7) {
        return 0;
    }

    return $value;
}

function parseCronField($field, $min, $max, $aliases = array(), $normalizeDayOfWeek = false)
{
    $values = array();
    $segments = explode(',', strtoupper($field));

    foreach ($segments as $segment) {
        if ($segment === '') {
            return false;
        }

        $step = 1;
        $hasStep = false;
        if (strpos($segment, '/') !== false) {
            $stepParts = explode('/', $segment, 2);
            if (count($stepParts) !== 2 || $stepParts[0] === '' || $stepParts[1] === '') {
                return false;
            }

            if (!preg_match('/^\d+$/', $stepParts[1]) || (int) $stepParts[1] <= 0) {
                return false;
            }

            $segment = $stepParts[0];
            $step = (int) $stepParts[1];
            $hasStep = true;
        }

        if ($segment === '*') {
            $start = $min;
            $end = $max;
        } elseif (strpos($segment, '-') !== false) {
            $rangeParts = explode('-', $segment, 2);
            if (count($rangeParts) !== 2) {
                return false;
            }

            $start = resolveCronValue($rangeParts[0], $aliases);
            $end = resolveCronValue($rangeParts[1], $aliases);
        } else {
            $start = resolveCronValue($segment, $aliases);
            // Vixie/busybox cron treats "M/N" as "M-MAX/N", not as the
            // single value M. Without this, schedules like "30/15" parse
            // as {30} here while crond fires at minutes {30, 45}, leading
            // to false unhealthies.
            $end = $hasStep ? $max : $start;
        }

        if ($start === false || $end === false || $start < $min || $end > $max || $start > $end) {
            return false;
        }

        for ($value = $start; $value <= $end; $value += $step) {
            $values[normalizeCronValue($value, $normalizeDayOfWeek)] = true;
        }
    }

    if (count($values) === 0) {
        return false;
    }

    $expectedCount = $normalizeDayOfWeek ? 7 : ($max - $min + 1);

    return array(
        'values' => $values,
        'all' => count($values) === $expectedCount,
    );
}

function parseCronExpression($expression)
{
    $parts = preg_split('/\s+/', trim($expression));
    if ($parts === false || count($parts) !== 5) {
        return false;
    }

    $monthAliases = array(
        'JAN' => 1,
        'FEB' => 2,
        'MAR' => 3,
        'APR' => 4,
        'MAY' => 5,
        'JUN' => 6,
        'JUL' => 7,
        'AUG' => 8,
        'SEP' => 9,
        'OCT' => 10,
        'NOV' => 11,
        'DEC' => 12,
    );
    $dayAliases = array(
        'SUN' => 0,
        'MON' => 1,
        'TUE' => 2,
        'WED' => 3,
        'THU' => 4,
        'FRI' => 5,
        'SAT' => 6,
    );

    $schedule = array(
        'minute' => parseCronField($parts[0], 0, 59),
        'hour' => parseCronField($parts[1], 0, 23),
        'dayOfMonth' => parseCronField($parts[2], 1, 31),
        'month' => parseCronField($parts[3], 1, 12, $monthAliases),
        'dayOfWeek' => parseCronField($parts[4], 0, 7, $dayAliases, true),
    );

    foreach ($schedule as $field) {
        if ($field === false) {
            return false;
        }
    }

    return $schedule;
}

function cronFieldMatches($field, $value)
{
    return isset($field['values'][$value]);
}

function cronMatchesDate($schedule, DateTimeImmutable $dateTime)
{
    if (!cronFieldMatches($schedule['minute'], (int) $dateTime->format('i'))) {
        return false;
    }

    if (!cronFieldMatches($schedule['hour'], (int) $dateTime->format('G'))) {
        return false;
    }

    if (!cronFieldMatches($schedule['month'], (int) $dateTime->format('n'))) {
        return false;
    }

    $dayOfMonthMatches = cronFieldMatches($schedule['dayOfMonth'], (int) $dateTime->format('j'));
    $dayOfWeekMatches = cronFieldMatches($schedule['dayOfWeek'], (int) $dateTime->format('w'));

    if ($schedule['dayOfMonth']['all'] && $schedule['dayOfWeek']['all']) {
        return true;
    }

    if ($schedule['dayOfMonth']['all']) {
        return $dayOfWeekMatches;
    }

    if ($schedule['dayOfWeek']['all']) {
        return $dayOfMonthMatches;
    }

    return $dayOfMonthMatches || $dayOfWeekMatches;
}

function findNextScheduledRun($schedule, DateTimeImmutable $after)
{
    $candidate = $after->setTime((int) $after->format('H'), (int) $after->format('i'), 0);
    $candidate = $candidate->modify('+1 minute');

    $maxSearchMinutes = 366 * 24 * 60 * 2;
    for ($minute = 0; $minute < $maxSearchMinutes; $minute++) {
        if (cronMatchesDate($schedule, $candidate)) {
            return $candidate;
        }

        $candidate = $candidate->modify('+1 minute');
    }

    return false;
}

initializeTimezone();

if (in_array('--mark-success', $argv, true)) {
    writeHeartbeat();
    exit(0);
}

loadDockerConfigIfAvailable();

$scheduleExpression = getEnvValue('CRON_SCHEDULE', '*/5 * * * *');
$schedule = parseCronExpression($scheduleExpression);
if ($schedule === false) {
    failHealthcheck(sprintf('Invalid CRON_SCHEDULE value "%s". Expected a standard 5-field cron expression.', $scheduleExpression));
}

$heartbeatTimestamp = readHeartbeatTimestamp();
$graceSeconds = getGraceSeconds();
$nowTimestamp = getNowTimestamp();

$timezone = new DateTimeZone(date_default_timezone_get());
$lastSuccess = (new DateTimeImmutable('@' . $heartbeatTimestamp))->setTimezone($timezone);
$nextScheduledRun = findNextScheduledRun($schedule, $lastSuccess);
if ($nextScheduledRun === false) {
    failHealthcheck(sprintf('Could not determine the next scheduled run for CRON_SCHEDULE "%s".', $scheduleExpression));
}

$deadlineTimestamp = $nextScheduledRun->getTimestamp() + $graceSeconds;
if ($nowTimestamp > $deadlineTimestamp) {
    failHealthcheck(sprintf(
        'Last successful run was %s. The next scheduled run was %s and exceeded the %d second grace period.',
        formatTimestamp($heartbeatTimestamp),
        $nextScheduledRun->format(DATE_ATOM),
        $graceSeconds
    ));
}

exit(0);
