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
function legotypes_findings(
    string $series,
    string $abi,
    ?string $urlSeries,
    array $packages,
    array $remote,
    callable $vercmp
): array {
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
                $mismatch[] = "{$name} {$p['version']} was built for series {$p['product_abi']}; "
                    . "this firewall runs {$series}";
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

/** The largest stamp fetched: a real one, its body, key and signature, is well under 2 KiB. */
const LEGOTYPES_STAMP_MAX_BYTES = 65536;

/** curl's error number for a body over its maximum file size (63), so this library needs no curl extension. */
const LEGOTYPES_CURLE_FILESIZE_EXCEEDED = 63;


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
 * The catalogue stamp's grammar: ONE file, so a CDN that caches each file on its own can
 * never serve parts of two deploys. At most LEGOTYPES_STAMP_MAX_BYTES of printable ASCII and
 * LF (no CR, tab or byte beyond ASCII), every line LF-terminated, exactly these lines in
 * this order (the same grammar as scripts/stamp-check.sh in opnsense-repo, which checks
 * every stamp sign-catalogue.sh writes):
 *   published: <YYYY-MM-DDTHH:MM:SSZ>   the publication time, UTC: a real date and time
 *                                       (it must survive a round trip through
 *                                       DateTimeImmutable, as stamp-check.sh checks it)
 *   run: <digits>                       the workflow run that signed it
 *   tree: <printable, no space>         <ABI>/<series>, the tree it stamps
 *   -----BEGIN PUBLIC KEY-----          the signing key, byte for byte as published
 *   <1 to 64 base64 characters>         (one key block, at least one line in it); its
 *   ...                                 sha256 is the fingerprint pkg would compute for
 *   -----END PUBLIC KEY-----            the key, and must be trusted
 *   signature: <base64, one line>       the last line; nothing follows it
 * The signature (RSA, sha256) is over the sha256 hex of every byte before the signature
 * line, as pkg has a catalogue file signed. A field missing, repeated or out of order, a
 * second key block, anything after the signature line, a date or time that does not exist:
 * malformed (both sides are tested on one list of dates, tests/stamp-dates.txt).
 */
const LEGOTYPES_STAMP_GRAMMAR = '/\Apublished: ([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z)\n'
    . 'run: [0-9]+\ntree: ([!-~]+)\n'
    . '(-----BEGIN PUBLIC KEY-----\n(?:[A-Za-z0-9+\/=]{1,64}\n)+-----END PUBLIC KEY-----\n)'
    . 'signature: ([A-Za-z0-9+\/]+={0,2})\n\z/';

/**
 * What the repository's signed catalogue stamp says. A pkg catalogue carries no date, so
 * a replayed old one verifies like a new one; the stamp beside it (LEGOTYPES_STAMP_GRAMMAR)
 * dates it, and is signed as pkg has a catalogue file signed.
 *
 * $answer is what the site answered for the stamp, or null when it gave none; $transport,
 * when not null, is the curl failure that stopped the fetch (curl's error number and
 * message). Availability is information, anything else short of a valid stamp is a
 * mismatch (Monit alerts):
 * - MISMATCH: a stamp over LEGOTYPES_STAMP_MAX_BYTES (curl stopped it with
 *   LEGOTYPES_CURLE_FILESIZE_EXCEEDED, or it came whole); an answer other than 200 and
 *   5xx (404, a redirect, which is not followed, 403, 410 ...); no answer and no transport
 *   failure.
 * - INFO "could not fetch the stamp": any other transport failure (DNS, connection
 *   refused, timeout), or a 5xx answer (an outage at the site).
 * - answered 200: MISMATCH for a stamp that is not the grammar's, a key block whose sha256
 *   is not in $trusted, a signature that does not verify with it, a time that is not one,
 *   or a stamp for a tree other than $tree; INFO for a stamp dated more than
 *   LEGOTYPES_STAMP_SKEW seconds after $now (this firewall's clock is behind: the stamp is
 *   dated by GitHub's runner); INFO for a valid stamp: when the catalogue was published
 *   and how long ago. The stamp is one file, fetched once: a signature that does not
 *   verify is a real finding, never two deploys mixed.
 *
 * @param ?array{status: int, body: string} $answer
 * @param ?array{errno: int, error: string} $transport
 * @param list<string> $trusted the trusted fingerprints (legotypes_fingerprints)
 * @param string $tree the <ABI>/<series> the stamp was fetched for
 * @return list<array{0: 'INFO'|'MISMATCH', 1: string}>
 */
function legotypes_stamp_findings(?array $answer, ?array $transport, array $trusted, int $now, string $tree): array
{
    $tooLarge = [['MISMATCH', 'the catalogue stamp is too large (over ' . LEGOTYPES_STAMP_MAX_BYTES . ' bytes)']];
    if ($transport !== null && $transport['errno'] === LEGOTYPES_CURLE_FILESIZE_EXCEEDED) {
        return $tooLarge;
    }
    if ($answer === null) {
        return $transport !== null ? [['INFO', "could not fetch the stamp ({$transport['error']})"]]
            : [['MISMATCH', 'the repository gave no answer for the catalogue stamp']];
    }
    $status = $answer['status'];
    if ($status >= 500 && $status <= 599) {
        return [['INFO', "could not fetch the stamp (HTTP {$status})"]];
    }
    if ($status !== 200) {
        return [['MISMATCH', "the repository answers without a catalogue stamp (HTTP {$status})"]];
    }
    $stamp = $answer['body'];
    if (strlen($stamp) > LEGOTYPES_STAMP_MAX_BYTES) {
        return $tooLarge;
    }
    if (preg_match(LEGOTYPES_STAMP_GRAMMAR, $stamp, $m) !== 1) {
        return [['MISMATCH', 'the catalogue stamp is malformed']];
    }
    [, $time, $stampTree, $pem, $sig64] = $m;
    if (!in_array(hash('sha256', $pem), $trusted, true)) {
        return [['MISMATCH', 'the catalogue stamp comes with a key that is not a trusted LegoTypes fingerprint']];
    }
    $signed = substr($stamp, 0, strlen($stamp) - strlen("signature: {$sig64}\n"));
    $sig = base64_decode($sig64, true);
    $key = openssl_pkey_get_public($pem);
    if ($sig === false || $key === false
        || openssl_verify(hash('sha256', $signed), $sig, $key, OPENSSL_ALGO_SHA256) !== 1) {
        return [['MISMATCH', 'the catalogue stamp signature does not verify']];
    }
    $published = DateTimeImmutable::createFromFormat('!Y-m-d\TH:i:s\Z', $time, new DateTimeZone('UTC'));
    if ($published === false || $published->format('Y-m-d\TH:i:s\Z') !== $time) {
        return [['MISMATCH', 'the catalogue stamp is malformed']];
    }
    if ($stampTree !== $tree) {
        return [['MISMATCH', "the catalogue stamp is for {$stampTree}; the repository url names {$tree}"]];
    }
    $at = $published->getTimestamp();
    if ($at - $now > LEGOTYPES_STAMP_SKEW) {
        return [['INFO', "catalogue stamp is dated {$time}, ahead of this firewall's clock ("
            . gmdate('Y-m-d\TH:i:s\Z', $now) . ')']];
    }
    $days = intdiv(max(0, $now - $at), 86400);
    return [['INFO', "catalogue published {$time} ({$days} " . ($days === 1 ? 'day' : 'days') . ' ago)']];
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
