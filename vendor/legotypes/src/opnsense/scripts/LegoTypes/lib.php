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
 * @param array<string, array{version: string, repo: string, abi: string, product_abi: ?string}> $packages
 *        every installed package
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

/** Seconds a catalogue stamp may be dated ahead of this firewall's clock and still read as published now. */
const LEGOTYPES_STAMP_SKEW = 300;

/** The largest stamp file fetched: the stamp, its signature and its key are each well under 4 KiB. */
const LEGOTYPES_STAMP_MAX_BYTES = 65536;

/** curl's error number for a body over its maximum file size (63), so this library needs no curl extension. */
const LEGOTYPES_CURLE_FILESIZE_EXCEEDED = 63;

/** The finding for a stamp whose signature does not verify with its trusted key. */
const LEGOTYPES_STAMP_BAD_SIGNATURE = 'the catalogue stamp signature does not verify';

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
 * The fingerprints the repository's packages are checked against, as pkg reads them
 * (libpkg/pkg_repo.c, pkg_repo_load_fingerprints): every file in trusted/ and revoked/,
 * dotfiles too; a revoked fingerprint is never trusted.
 *
 * Trusted files are read strictly, so anything pkg might not trust is not trusted here:
 * a line `fingerprint: "<hex>"` (key in any case, optionally quoted, `:` or `=`, an
 * optional `;` or `,`) counts only in a file with a `function: "sha256"` line, the last
 * one in a file wins, and it counts only as 64 lower-case hex digits (pkg compares it
 * exactly with the lower-case sha256 of the key, so nothing else matches). Revoked files
 * are read loosely, so anything pkg might revoke is revoked here: every run of 64 hex
 * digits in them, in either case, whatever UCL spelling surrounds it.
 *
 * @param list<string> $trusted the contents of each file in fingerprints/LegoTypes/trusted
 * @param list<string> $revoked the contents of each file in fingerprints/LegoTypes/revoked
 * @return list<string>
 */
function legotypes_fingerprints(array $trusted, array $revoked): array
{
    $function = '/^[ \t]*"?function"?[ \t]*[:=][ \t]*(?:"sha256"|sha256)[ \t]*[;,]?[ \t]*\r?$/mi';
    $fingerprint = '/^[ \t]*"?fingerprint"?[ \t]*[:=][ \t]*"([^"\r\n]*)"[ \t]*[;,]?[ \t]*\r?$/mi';
    $found = [];
    foreach ($trusted as $content) {
        if (preg_match($function, $content) !== 1 || preg_match_all($fingerprint, $content, $m) < 1) {
            continue;
        }
        $last = $m[1][count($m[1]) - 1];
        if (preg_match('/^[0-9a-f]{64}$/', $last) === 1) {
            $found[] = $last;
        }
    }
    $gone = [];
    foreach ($revoked as $content) {
        if (preg_match_all('/(?<![0-9A-Fa-f])[0-9A-Fa-f]{64}(?![0-9A-Fa-f])/', $content, $m) > 0) {
            array_push($gone, ...array_map('strtolower', $m[0]));
        }
    }
    return array_values(array_diff($found, $gone));
}

/**
 * What the repository's signed catalogue stamp says. A pkg catalogue carries no date, so
 * a replayed old one verifies like a new one; the stamp beside it is signed as pkg has a
 * catalogue file signed (the signature, sha256, over the file's sha256 hex) and dates it.
 *
 * $files holds what the site answered for each of stamp, stamp.sig and stamp.pub that was
 * fetched; $transport, when not null, is the curl failure that stopped the fetch (the file
 * it stopped at, curl's error number and message). Availability is information, anything
 * else short of a valid stamp is a mismatch (Monit alerts):
 * - MISMATCH: a file over LEGOTYPES_STAMP_MAX_BYTES (LEGOTYPES_CURLE_FILESIZE_EXCEEDED);
 *   an answer other than 200 and 5xx (404, a redirect, which is not followed, 403, 410 ...)
 *   for any file fetched; a file neither answered nor stopped at by a transport failure.
 * - INFO "could not fetch the stamp": any other transport failure (DNS, connection
 *   refused, timeout), or a 5xx answer (an outage at the site).
 * - with all three answered 200, MISMATCH for a stamp.pub whose sha256 is not in $trusted,
 *   a signature that does not verify with it, a stamp that is not exactly its three lines,
 *   or one for a tree other than $tree; INFO for a stamp dated more than
 *   LEGOTYPES_STAMP_SKEW seconds after $now (this firewall's clock is behind: the stamp is
 *   dated by GitHub's runner); INFO for a valid stamp: when the catalogue was published
 *   and how long ago.
 *
 * @param array<string, array{status: int, body: string}> $files keyed stamp, stamp.sig, stamp.pub
 * @param ?array{file: string, errno: int, error: string} $transport
 * @param list<string> $trusted the trusted fingerprints (legotypes_fingerprints)
 * @param string $tree the <ABI>/<series> the stamp was fetched for
 * @return list<array{0: 'INFO'|'MISMATCH', 1: string}>
 */
function legotypes_stamp_findings(array $files, ?array $transport, array $trusted, int $now, string $tree): array
{
    if ($transport !== null && $transport['errno'] === LEGOTYPES_CURLE_FILESIZE_EXCEEDED) {
        return [['MISMATCH', "the catalogue stamp file {$transport['file']} is too large (over "
            . LEGOTYPES_STAMP_MAX_BYTES . ' bytes)']];
    }
    $refused = [];
    $outage = null;
    foreach (['stamp', 'stamp.sig', 'stamp.pub'] as $name) {
        if (!isset($files[$name])) {
            if ($transport === null) {
                $refused[] = "{$name}: no answer";
            }
            continue;
        }
        $status = $files[$name]['status'];
        if ($status >= 500 && $status <= 599) {
            $outage ??= "HTTP {$status} for {$name}";
        } elseif ($status !== 200) {
            $refused[] = "{$name}: HTTP {$status}";
        }
    }
    if ($refused !== []) {
        return [['MISMATCH', 'the repository answers without a catalogue stamp (' . implode(', ', $refused) . ')']];
    }
    /* past the refusals, a missing file means a transport failure stopped the fetch */
    $unreachable = $transport !== null ? $transport['error'] : $outage;
    if ($unreachable !== null) {
        return [['INFO', "could not fetch the stamp ({$unreachable})"]];
    }
    $stamp = $files['stamp']['body'];
    $sig = $files['stamp.sig']['body'];
    $pub = $files['stamp.pub']['body'];
    if (!in_array(hash('sha256', $pub), $trusted, true)) {
        return [['MISMATCH', 'the catalogue stamp comes with a key that is not a trusted LegoTypes fingerprint']];
    }
    $key = openssl_pkey_get_public($pub);
    if ($key === false || openssl_verify(hash('sha256', $stamp), $sig, $key, OPENSSL_ALGO_SHA256) !== 1) {
        return [['MISMATCH', LEGOTYPES_STAMP_BAD_SIGNATURE]];
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
        return [['INFO', "catalogue stamp is dated {$m[1]}, ahead of this firewall's clock ("
            . gmdate('Y-m-d\TH:i:s\Z', $now) . ')']];
    }
    $days = intdiv(max(0, $now - $at), 86400);
    return [['INFO', "catalogue published {$m[1]} ({$days} " . ($days === 1 ? 'day' : 'days') . ' ago)']];
}

/**
 * The stamp's findings from one fetch of its three files, or from a second fetch when the
 * first reads as a signature that does not verify: a deploy can land between two of the
 * fetches (a new stamp beside the previous stamp.sig), so such a signature is a mismatch only
 * when the files fetched again still give it. Nothing else is fetched again.
 *
 * @param callable(): array{
 *     0: array<string, array{status: int, body: string}>,
 *     1: ?array{file: string, errno: int, error: string}
 * } $fetch one fetch of the three files, as legotypes_stamp_findings() takes them
 * @param list<string> $trusted the trusted fingerprints (legotypes_fingerprints)
 * @param string $tree the <ABI>/<series> the stamp is fetched for
 * @return list<array{0: 'INFO'|'MISMATCH', 1: string}>
 */
function legotypes_stamp_check(callable $fetch, array $trusted, int $now, string $tree): array
{
    [$files, $transport] = $fetch();
    $r = legotypes_stamp_findings($files, $transport, $trusted, $now, $tree);
    if ($r === [['MISMATCH', LEGOTYPES_STAMP_BAD_SIGNATURE]]) {
        [$files, $transport] = $fetch();
        $r = legotypes_stamp_findings($files, $transport, $trusted, $now, $tree);
    }
    return $r;
}

/**
 * The check's output lines: each mismatch, then each piece of information, and last the line
 * saying the packages fit, only when nothing mismatches at all (the stamp included).
 *
 * @param list<string> $mismatch
 * @param list<string> $info
 * @return list<string>
 */
function legotypes_report(array $mismatch, array $info, string $series, string $abi): array
{
    $lines = [];
    foreach ($mismatch as $m) {
        $lines[] = "MISMATCH: {$m}";
    }
    foreach ($info as $i) {
        $lines[] = "INFO: {$i}";
    }
    if ($mismatch === []) {
        $lines[] = "LegoTypes packages fit series {$series} on {$abi}";
    }
    return $lines;
}
