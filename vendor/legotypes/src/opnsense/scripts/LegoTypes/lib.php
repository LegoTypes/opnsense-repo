<?php

declare(strict_types=1);

/*
 * Copyright (C) 2026 cayossarian
 * All rights reserved.
 * BSD 2-Clause License
 *
 * Shared by the firmware repository hook and the runtime check, so the series the
 * hook writes and the series the check reads are parsed the same way; and the check's
 * reading of the repository's signed catalogue stamp. Pure.
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

/** Seconds a catalogue stamp may be dated ahead of this firewall's clock before that is a mismatch. */
const LEGOTYPES_STAMP_SKEW = 300;

/**
 * The repository's tree URL from its config, with ${ABI} resolved as pkg resolves it
 * (pkg config ABI) and no trailing slash; null when the config names no https url or
 * leaves any other variable unresolved. The stamp is served beside packagesite.pkg.
 */
function legotypes_tree_url(string $conf, string $abi): ?string
{
    if (preg_match('/^\s*url:\s*"([^"]*)"/m', $conf, $m) !== 1) {
        return null;
    }
    $url = rtrim(str_replace('${ABI}', $abi, $m[1]), '/');
    return str_starts_with($url, 'https://') && !str_contains($url, '$') ? $url : null;
}

/**
 * The fingerprints pkg trusts for the repository: every `fingerprint: "<sha256 hex>"` in
 * a trusted file that is in no revoked file.
 *
 * @param list<string> $trusted the contents of each file in fingerprints/LegoTypes/trusted
 * @param list<string> $revoked the contents of each file in fingerprints/LegoTypes/revoked
 * @return list<string>
 */
function legotypes_fingerprints(array $trusted, array $revoked): array
{
    $read = function (array $files): array {
        $found = [];
        foreach ($files as $content) {
            if (preg_match_all('/^fingerprint:\s*"([0-9a-f]{64})"\s*$/m', $content, $m) > 0) {
                array_push($found, ...$m[1]);
            }
        }
        return $found;
    };
    return array_values(array_diff($read($trusted), $read($revoked)));
}

/**
 * What the repository's signed catalogue stamp says. A pkg catalogue carries no date, so
 * a replayed old one verifies like a new one; the stamp beside it is signed as pkg has a
 * catalogue file signed (the signature, sha256, over the file's sha256 hex) and dates it.
 *
 * - $fetchError not null: the site could not be reached (DNS failure, connection refused,
 *   timeout, or an HTTP status other than 200 and 404); information, whatever was fetched.
 * - otherwise a null file is one the site answered 404 for: a mismatch, as is a stamp.pub
 *   whose sha256 is not in $trusted, a signature that does not verify with it, a stamp that
 *   is not exactly its three lines, one for a tree other than $tree, or one dated more
 *   than LEGOTYPES_STAMP_SKEW seconds after $now.
 * - a valid stamp is information: when the catalogue was published and how long ago.
 *
 * @param list<string> $trusted the trusted fingerprints (legotypes_fingerprints)
 * @param string $tree the <ABI>/<series> the stamp was fetched for
 * @return list<array{0: 'INFO'|'MISMATCH', 1: string}>
 */
function legotypes_stamp_findings(?string $stamp, ?string $sig, ?string $pub, array $trusted, int $now, ?string $fetchError, string $tree): array
{
    if ($fetchError !== null) {
        return [['INFO', "could not fetch the stamp ({$fetchError})"]];
    }
    $missing = [];
    foreach (['stamp' => $stamp, 'stamp.sig' => $sig, 'stamp.pub' => $pub] as $name => $content) {
        if ($content === null) {
            $missing[] = $name;
        }
    }
    if ($stamp === null || $sig === null || $pub === null) {
        return [['MISMATCH', 'the repository serves no catalogue stamp (not found: ' . implode(', ', $missing) . ')']];
    }
    if (!in_array(hash('sha256', $pub), $trusted, true)) {
        return [['MISMATCH', 'the catalogue stamp comes with a key that is not a trusted LegoTypes fingerprint']];
    }
    $key = openssl_pkey_get_public($pub);
    if ($key === false || openssl_verify(hash('sha256', $stamp), $sig, $key, OPENSSL_ALGO_SHA256) !== 1) {
        return [['MISMATCH', 'the catalogue stamp signature does not verify']];
    }
    $line = '/\Apublished: ([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z)\nrun: [0-9]+\ntree: ([^\n]*)\n\z/';
    $utc = new DateTimeZone('UTC');
    $published = preg_match($line, $stamp, $m) === 1
        ? DateTimeImmutable::createFromFormat('!Y-m-d\TH:i:s\Z', $m[1], $utc) : false;
    if ($published === false || $published->format('Y-m-d\TH:i:s\Z') !== $m[1]) {
        return [['MISMATCH', 'the catalogue stamp is malformed']];
    }
    if ($m[2] !== $tree) {
        return [['MISMATCH', "the catalogue stamp is for {$m[2]}; the repository url names {$tree}"]];
    }
    $at = $published->getTimestamp();
    if ($at - $now > LEGOTYPES_STAMP_SKEW) {
        return [['MISMATCH', "the catalogue stamp is dated {$m[1]}, ahead of this firewall's clock ("
            . gmdate('Y-m-d\TH:i:s\Z', $now) . ')']];
    }
    $days = intdiv(max(0, $now - $at), 86400);
    return [['INFO', "catalogue published {$m[1]} ({$days} " . ($days === 1 ? 'day' : 'days') . ' ago)']];
}
