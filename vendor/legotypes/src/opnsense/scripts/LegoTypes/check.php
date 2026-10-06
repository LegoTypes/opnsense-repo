#!/usr/local/bin/php
<?php

declare(strict_types=1);

/*
 * Copyright (C) 2026 cayossarian (Bill Flood)
 * All rights reserved.
 * BSD 2-Clause License
 *
 * Read-only: do the LegoTypes packages fit this firewall? Compares the running
 * series and package ABI with the repository config and every installed LegoTypes
 * package, and lists available updates and hand-installed packages. Prints its
 * findings; exits 1 on a mismatch (Monit alerts when that starts and when it ends),
 * 0 otherwise.
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

$series = trim(lt_run('/usr/local/sbin/opnsense-version -a'));
$abi = trim(lt_run('/usr/local/sbin/pkg config ABI'));
if ($series === '' || $abi === '') {
    echo "MISMATCH: cannot read this firewall's series or package ABI\n";
    exit(1);
}
$conf = '/usr/local/etc/pkg/repos/LegoTypes.conf';
$urlSeries = is_readable($conf) ? legotypes_url_series((string)file_get_contents($conf)) : null;

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
foreach ($r['mismatch'] as $m) {
    echo "MISMATCH: {$m}\n";
}
foreach ($r['info'] as $i) {
    echo "INFO: {$i}\n";
}
if ($r['mismatch'] === []) {
    echo "LegoTypes packages fit series {$series} on {$abi}\n";
}
exit($r['mismatch'] === [] ? 0 : 1);
