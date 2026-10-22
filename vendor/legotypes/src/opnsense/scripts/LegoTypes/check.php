#!/usr/local/bin/php
<?php

declare(strict_types=1);

/*
 * Copyright (C) 2026 cayossarian
 * All rights reserved.
 * BSD 2-Clause License
 *
 * Read-only: do the LegoTypes packages fit this firewall? Compares the running
 * series and package ABI with the repository config and every installed LegoTypes
 * package, and lists available updates and hand-installed packages. Then reads the
 * repository's signed catalogue stamp: when the catalogue was published; a mismatch if
 * the site answers without a valid stamp (404, any answer but 200 and 5xx, a forged or
 * malformed stamp); information only if the site cannot be reached or has an outage. The
 * stamp is one file, fetched once. Prints its findings, and that the packages fit only when
 * nothing mismatches; exits 1 on a mismatch (Monit alerts when that starts and when it
 * ends), 0 otherwise.
 */

require_once __DIR__ . '/lib.php';

function lt_run(string $cmd): string
{
    return (string)shell_exec($cmd . ' 2>/dev/null');
}

/** @return list<list<string>> the lines of a command's output, split on "|" */
function lt_rows(string $cmd, int $fields): array
{
    $rows = [];
    foreach (explode("\n", trim(lt_run($cmd))) as $line) {
        $f = explode('|', $line);
        if (count($f) === $fields) {
            $rows[] = $f;
        }
    }
    return $rows;
}

/**
 * Fetch the stamp, one file beside the catalogue, recording only what happened: [the
 * site's answer (status and body), or null; null, or the transport failure that stopped
 * the fetch (curl's error number and message)]. Classifying it is
 * legotypes_stamp_findings()'s. The fetch connects within 3 s and ends within 6 s, so the
 * check never holds Monit up; redirects are not followed; a body over
 * LEGOTYPES_STAMP_MAX_BYTES stops the transfer (CURLE_FILESIZE_EXCEEDED: libcurl 8.4 and
 * later enforce CURLOPT_MAXFILESIZE with or without a Content-Length; 26.7 ships 8.22).
 *
 * @return array{0: ?array{status: int, body: string}, 1: ?array{errno: int, error: string}}
 */
function lt_fetch_stamp(string $url): array
{
    $ch = curl_init();
    if ($ch === false) {
        return [null, ['errno' => CURLE_FAILED_INIT, 'error' => 'curl could not start']];
    }
    curl_setopt_array($ch, [
        CURLOPT_URL => "{$url}/stamp",
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_FOLLOWLOCATION => false,
        CURLOPT_CONNECTTIMEOUT => 3,
        CURLOPT_TIMEOUT => 6,
        CURLOPT_MAXFILESIZE => LEGOTYPES_STAMP_MAX_BYTES,
    ]);
    $body = curl_exec($ch);
    if (!is_string($body)) {
        $errno = curl_errno($ch);
        $error = curl_error($ch);
        return [null, ['errno' => $errno, 'error' => $error !== '' ? $error : (string)curl_strerror($errno)]];
    }
    return [['status' => (int)curl_getinfo($ch, CURLINFO_RESPONSE_CODE), 'body' => $body], null];
}

/**
 * @return list<string> the contents of every file in a fingerprint directory, dotfiles
 * too, as pkg reads it; none for a directory that is absent (revoked/ may be)
 */
function lt_fingerprint_files(string $dir): array
{
    $files = [];
    foreach ((is_dir($dir) ? scandir($dir) : false) ?: [] as $entry) {
        if ($entry !== '.' && $entry !== '..' && is_file("{$dir}/{$entry}")) {
            $files[] = (string)file_get_contents("{$dir}/{$entry}");
        }
    }
    return $files;
}

$series = trim(lt_run('/usr/local/sbin/opnsense-version -a'));
$abi = trim(lt_run('/usr/local/sbin/pkg config ABI'));
if ($series === '' || $abi === '') {
    echo "MISMATCH: cannot read this firewall's series or package ABI\n";
    exit(1);
}
$conf = '/usr/local/etc/pkg/repos/LegoTypes.conf';
$confText = is_readable($conf) ? (string)file_get_contents($conf) : null;
$urlSeries = $confText !== null ? legotypes_url_series($confText) : null;

$packages = [];
foreach (lt_rows("/usr/local/sbin/pkg query '%n|%v|%R|%q'", 4) as [$name, $version, $repo, $pabi]) {
    $packages[$name] = ['version' => $version, 'repo' => $repo, 'abi' => $pabi, 'product_abi' => null];
}
foreach (lt_rows("/usr/local/sbin/pkg query '%n|%At|%Av'", 3) as [$name, $tag, $value]) {
    if ($tag === 'product_abi' && isset($packages[$name])) {
        $packages[$name]['product_abi'] = $value;
    }
}
$remote = [];
foreach (lt_rows("/usr/local/sbin/pkg rquery -r LegoTypes '%n|%v'", 2) as [$name, $version]) {
    $remote[$name] = $version;
}
$vercmp = fn (string $a, string $b): string =>
    trim(lt_run('/usr/local/sbin/pkg version -t ' . escapeshellarg($a) . ' ' . escapeshellarg($b)));

$r = legotypes_findings($series, $abi, $urlSeries, $packages, $remote, $vercmp);

/* the stamp of the tree the repository config names (a config naming none is a mismatch above) */
if ($confText !== null && $urlSeries !== null) {
    $url = legotypes_tree_url($confText, $abi);
    if ($url === null) {
        $stamp = [['MISMATCH', 'the LegoTypes repository url is not an https url this check can resolve, '
            . 'so its catalogue stamp cannot be fetched']];
    } else {
        $fingerprints = '/usr/local/etc/pkg/fingerprints/LegoTypes';
        $trusted = legotypes_fingerprints(lt_fingerprint_files("{$fingerprints}/trusted"),
            lt_fingerprint_files("{$fingerprints}/revoked"));
        [$answer, $transport] = lt_fetch_stamp($url);
        $stamp = legotypes_stamp_findings($answer, $transport, $trusted, time(), "{$abi}/{$urlSeries}");
    }
    foreach ($stamp as [$level, $text]) {
        $r[$level === 'MISMATCH' ? 'mismatch' : 'info'][] = $text;
    }
}

foreach (legotypes_report($r['mismatch'], $r['info'], $series, $abi) as $line) {
    echo "{$line}\n";
}
exit($r['mismatch'] === [] ? 0 : 1);
