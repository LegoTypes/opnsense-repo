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
 * repository's signed catalogue stamp: when the catalogue was published, a mismatch if
 * the stamp is missing (HTTP 404) or does not verify, information only if the site
 * cannot be reached. Prints its findings; exits 1 on a mismatch (Monit alerts when
 * that starts and when it ends), 0 otherwise.
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
 * The stamp's three files from beside the catalogue: [name => contents, null for one
 * the site answered 404 for; null] or [[]; why the site could not be reached (curl's
 * error, or an HTTP status other than 200 and 404)]. Each fetch connects within 3 s and
 * ends within 6 s, so the check never holds Monit up; redirects are not followed.
 *
 * @return array{0: array<string, ?string>, 1: ?string}
 */
function lt_fetch_stamp(string $url): array
{
    $ch = curl_init();
    if ($ch === false) {
        return [[], 'curl could not start'];
    }
    $files = [];
    foreach (['stamp', 'stamp.sig', 'stamp.pub'] as $name) {
        curl_setopt_array($ch, [
            CURLOPT_URL => "{$url}/{$name}",
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_FOLLOWLOCATION => false,
            CURLOPT_CONNECTTIMEOUT => 3,
            CURLOPT_TIMEOUT => 6,
            CURLOPT_MAXFILESIZE => 65536,
        ]);
        $body = curl_exec($ch);
        if (!is_string($body)) {
            $error = curl_error($ch);
            return [[], $error !== '' ? $error : (string)curl_strerror(curl_errno($ch))];
        }
        $status = curl_getinfo($ch, CURLINFO_RESPONSE_CODE);
        if ($status === 404) {
            $files[$name] = null;
        } elseif ($status === 200) {
            $files[$name] = $body;
        } else {
            return [[], "HTTP {$status} for {$name}"];
        }
    }
    return [$files, null];
}

/** @return list<string> the contents of each file in a fingerprint directory */
function lt_fingerprint_files(string $dir): array
{
    $files = [];
    foreach (glob($dir . '/*') ?: [] as $path) {
        if (is_file($path)) {
            $files[] = (string)file_get_contents($path);
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
$fit = $r['mismatch'] === [];

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
        [$files, $error] = lt_fetch_stamp($url);
        $stamp = legotypes_stamp_findings($files['stamp'] ?? null, $files['stamp.sig'] ?? null, $files['stamp.pub'] ?? null,
            $trusted, time(), $error, "{$abi}/{$urlSeries}");
    }
    foreach ($stamp as [$level, $text]) {
        $r[$level === 'MISMATCH' ? 'mismatch' : 'info'][] = $text;
    }
}

foreach ($r['mismatch'] as $m) {
    echo "MISMATCH: {$m}\n";
}
foreach ($r['info'] as $i) {
    echo "INFO: {$i}\n";
}
if ($fit) {
    echo "LegoTypes packages fit series {$series} on {$abi}\n";
}
exit($r['mismatch'] === [] ? 0 : 1);
