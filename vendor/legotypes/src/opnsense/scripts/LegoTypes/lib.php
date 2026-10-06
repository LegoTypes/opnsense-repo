<?php

declare(strict_types=1);

/*
 * Copyright (C) 2026 cayossarian (Bill Flood)
 * All rights reserved.
 * BSD 2-Clause License
 *
 * Shared by the firmware repository hook and the runtime check, so the series the
 * hook writes and the series the check reads are parsed the same way. Pure.
 */

/** The series in a LegoTypes repository config's url, or null when it names none. */
function legotypes_url_series(string $conf): ?string
{
    return preg_match('#/([0-9]+\.[0-9]+)/latest"#', $conf, $m) === 1 ? $m[1] : null;
}

/** The repository config for a series: the sample with its series replaced (unchanged for a malformed series). */
function legotypes_conf_for(string $sample, string $series): string
{
    if (preg_match('/^[0-9]+\.[0-9]+$/', $series) !== 1) {
        return $sample;
    }
    return (string)preg_replace('#/[0-9]+\.[0-9]+/latest"#', '/' . $series . '/latest"', $sample);
}

/**
 * Do the LegoTypes packages fit this firewall?
 *
 * @param array<string, array{version: string, repo: string, abi: string, product_abi: ?string}> $packages every installed package
 * @param array<string, string> $remote the LegoTypes catalogue, name => version
 * @param callable(string, string): string $vercmp '<', '=' or '>'
 * @return array{mismatch: list<string>, info: list<string>}
 */
function legotypes_findings(string $series, string $abi, ?string $urlSeries, array $packages, array $remote, callable $vercmp): array
{
    $mismatch = [];
    $info = [];
    if ($urlSeries === null) {
        $mismatch[] = 'the LegoTypes repository config is missing or names no series';
    } elseif ($urlSeries !== $series) {
        $mismatch[] = "the LegoTypes repository points at series {$urlSeries}; this firewall runs {$series}";
    }
    foreach ($packages as $name => $p) {
        if ($p['repo'] === 'LegoTypes') {
            if ($p['product_abi'] !== null && $p['product_abi'] !== $series) {
                $mismatch[] = "{$name} {$p['version']} was built for series {$p['product_abi']}; this firewall runs {$series}";
            }
            if (!fnmatch($p['abi'], $abi)) {
                $mismatch[] = "{$name} {$p['version']} is built for {$p['abi']}; this firewall is {$abi}";
            }
            if (isset($remote[$name]) && $vercmp($p['version'], $remote[$name]) === '<') {
                $info[] = "{$name} {$p['version']}: update available ({$remote[$name]})";
            }
        } elseif ($p['repo'] === 'unknown-repository') {
            $info[] = "{$name} {$p['version']} was installed by hand (no repository)";
        }
    }
    return ['mismatch' => $mismatch, 'info' => $info];
}
