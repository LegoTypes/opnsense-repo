<?php

declare(strict_types=1);

/*
 * Copyright (C) 2026 cayossarian
 * All rights reserved.
 * BSD 2-Clause License
 *
 * os-legotypes library tests: php vendor/legotypes/tests/test_lib.php (on the test VM).
 */

require __DIR__ . '/../src/opnsense/scripts/LegoTypes/lib.php';

$fail = 0;
$total = 0;
function check(string $name, bool $ok): void
{
    global $fail, $total;
    $total++;
    if (!$ok) {
        $fail++;
        echo "FAIL: {$name}\n";
    }
}

$sample = "LegoTypes: {\n  url: \"https://legotypes.github.io/opnsense-repo/\${ABI}/26.7/latest\",\n  enabled: yes\n}\n";
check('url series', legotypes_url_series($sample) === '26.7');
check('url series absent', legotypes_url_series("LegoTypes: {}\n") === null);
check('conf for a new series', legotypes_url_series(legotypes_conf_for($sample, '27.1')) === '27.1');
check('conf keeps the rest', str_contains(legotypes_conf_for($sample, '27.1'), '${ABI}/27.1/latest')
    && str_contains(legotypes_conf_for($sample, '27.1'), 'enabled: yes'));
check('conf for an unreadable series is the sample', legotypes_conf_for($sample, '') === $sample);

$cmp = fn (string $a, string $b): string => version_compare($a, $b) < 0 ? '<' : (version_compare($a, $b) > 0 ? '>' : '=');
$lt = fn (string $v, ?string $pa = '26.7', string $abi = 'FreeBSD:15:amd64'): array =>
    ['version' => $v, 'repo' => 'LegoTypes', 'abi' => $abi, 'product_abi' => $pa];

$r = legotypes_findings('26.7', 'FreeBSD:15:amd64', '26.7', ['os-a' => $lt('1.0')], ['os-a' => '1.0'], $cmp);
check('everything fits', $r === ['mismatch' => [], 'info' => []]);
$r = legotypes_findings('27.1', 'FreeBSD:15:amd64', '26.7', ['os-a' => $lt('1.0')], [], $cmp);
check('the firewall moved to a new series: the repository and the package mismatch', count($r['mismatch']) === 2);
$r = legotypes_findings('26.7', 'FreeBSD:16:amd64', '26.7', ['os-a' => $lt('1.0')], [], $cmp);
check('an ABI mismatch', count($r['mismatch']) === 1 && str_contains($r['mismatch'][0], 'FreeBSD:15:amd64'));
$r = legotypes_findings('26.7', 'FreeBSD:15:amd64', null, [], [], $cmp);
check('a missing repository config is a mismatch, not an error', count($r['mismatch']) === 1);
$r = legotypes_findings('26.7', 'FreeBSD:15:amd64', '26.7', ['os-a' => $lt('1.0')], ['os-a' => '1.1'], $cmp);
check('an update is information', $r['mismatch'] === [] && $r['info'] === ['os-a 1.0: update available (1.1)']);
$r = legotypes_findings('26.7', 'FreeBSD:15:amd64', '26.7',
    ['os-x' => ['version' => '0.1', 'repo' => 'unknown-repository', 'abi' => 'FreeBSD:*:*', 'product_abi' => null]], [], $cmp);
check('a hand-installed package is information', $r['mismatch'] === [] && count($r['info']) === 1);
$r = legotypes_findings('26.7', 'FreeBSD:15:amd64', '26.7', ['os-a' => $lt('1.0', null, 'FreeBSD:*:*')], [], $cmp);
check('a wildcard ABI and no product_abi fit', $r['mismatch'] === []);

check('tree url resolves ${ABI}', legotypes_tree_url($sample, 'FreeBSD:15:amd64')
    === 'https://legotypes.github.io/opnsense-repo/FreeBSD:15:amd64/26.7/latest');
check('tree url drops a trailing slash', legotypes_tree_url("  url: \"https://example.invalid/r/\${ABI}/26.7/latest/\",\n", 'FreeBSD:15:amd64')
    === 'https://example.invalid/r/FreeBSD:15:amd64/26.7/latest');
check('tree url absent', legotypes_tree_url("LegoTypes: {}\n", 'FreeBSD:15:amd64') === null);
check('tree url other than https', legotypes_tree_url("  url: \"http://example.invalid/\${ABI}/26.7/latest\",\n", 'FreeBSD:15:amd64') === null);
check('tree url with a variable left unresolved',
    legotypes_tree_url("  url: \"https://example.invalid/\${ABI}/\${ARCH}/latest\",\n", 'FreeBSD:15:amd64') === null);

/* a throwaway key pair for the stamp tests, and a second one that is not trusted */
$rsa = ['private_key_bits' => 2048, 'private_key_type' => OPENSSL_KEYTYPE_RSA];
$key = openssl_pkey_new($rsa);
$other = openssl_pkey_new($rsa);
if ($key === false || $other === false) {
    echo "FAIL: cannot generate a test key\n";
    exit(1);
}
$pub = openssl_pkey_get_details($key)['key'];
$otherPub = openssl_pkey_get_details($other)['key'];
$fpr = hash('sha256', $pub);
$otherFpr = hash('sha256', $otherPub);
/* sign as pkg's signing_command does: the signature (sha256) over the file's sha256 hex */
$sign = function (string $content, OpenSSLAsymmetricKey $k): string {
    openssl_sign(hash('sha256', $content), $sig, $k, OPENSSL_ALGO_SHA256);
    return $sig;
};
$at = gmmktime(17, 4, 5, 10, 18, 2026);
$stamp = "published: 2026-10-18T17:04:05Z\nrun: 18734512345\ntree: FreeBSD:15:amd64/26.7\n";
$sig = $sign($stamp, $key);
$sf = fn (?string $s, ?string $g, ?string $p, array $t, int $now, ?string $err, string $tree = 'FreeBSD:15:amd64/26.7'): array =>
    legotypes_stamp_findings($s, $g, $p, $t, $now, $err, $tree);
$mismatch = fn (array $r): bool => count($r) === 1 && $r[0][0] === 'MISMATCH';

check('a valid stamp is information with its age',
    $sf($stamp, $sig, $pub, [$fpr], $at + 3 * 86400 + 3600, null) === [['INFO', 'catalogue published 2026-10-18T17:04:05Z (3 days ago)']]);
check('a valid stamp a day old',
    $sf($stamp, $sig, $pub, [$fpr], $at + 86400, null) === [['INFO', 'catalogue published 2026-10-18T17:04:05Z (1 day ago)']]);
check('a valid stamp published today',
    $sf($stamp, $sig, $pub, [$fpr], $at + 60, null) === [['INFO', 'catalogue published 2026-10-18T17:04:05Z (0 days ago)']]);
check('a stamp a little ahead of this clock is within the skew',
    $sf($stamp, $sig, $pub, [$fpr], $at - 300, null) === [['INFO', 'catalogue published 2026-10-18T17:04:05Z (0 days ago)']]);
check('a valid stamp among several trusted fingerprints', $sf($stamp, $sig, $pub, [$otherFpr, $fpr], $at, null)[0][0] === 'INFO');
check('a stamp dated in the future beyond the skew', $mismatch($sf($stamp, $sig, $pub, [$fpr], $at - 301, null)));

check('a signature by another key', $mismatch($sf($stamp, $sign($stamp, $other), $pub, [$fpr], $at, null)));
check('a stamp changed after signing',
    $mismatch($sf(str_replace('2026-10-18', '2026-10-20', $stamp), $sig, $pub, [$fpr], $at + 3 * 86400, null)));
check('a signature that is not one', $mismatch($sf($stamp, 'not a signature', $pub, [$fpr], $at, null)));
check('an empty signature', $mismatch($sf($stamp, '', $pub, [$fpr], $at, null)));
$r = $sf($stamp, $sign($stamp, $other), $otherPub, [$fpr], $at, null);
check('a stamp signed and keyed by an untrusted key', $mismatch($r) && str_contains($r[0][1], 'not a trusted'));
check('no trusted fingerprint at all', $mismatch($sf($stamp, $sig, $pub, [], $at, null)));
check('a trusted stamp.pub that is not a key', $mismatch($sf($stamp, $sig, 'not a key', [hash('sha256', 'not a key')], $at, null)));

$r = $sf(null, $sig, $pub, [$fpr], $at, null);
check('no stamp (HTTP 404)', $mismatch($r) && str_contains($r[0][1], 'not found: stamp)'));
$r = $sf($stamp, null, $pub, [$fpr], $at, null);
check('no stamp.sig (HTTP 404)', $mismatch($r) && str_contains($r[0][1], 'not found: stamp.sig)'));
$r = $sf($stamp, $sig, null, [$fpr], $at, null);
check('no stamp.pub (HTTP 404)', $mismatch($r) && str_contains($r[0][1], 'not found: stamp.pub)'));
$r = $sf(null, null, null, [$fpr], $at, null);
check('none of the three (HTTP 404)', $mismatch($r) && str_contains($r[0][1], 'not found: stamp, stamp.sig, stamp.pub)'));

$signed = fn (string $s): array => $sf($s, $sign($s, $key), $pub, [$fpr], $at, null);
check('a stamp with no run', $mismatch($signed("published: 2026-10-18T17:04:05Z\ntree: FreeBSD:15:amd64/26.7\n")));
check('a stamp with an extra line', $mismatch($signed($stamp . "note: hello\n")));
check('a stamp with a blank line at the end', $mismatch($signed($stamp . "\n")));
check('a stamp without its final newline', $mismatch($signed(rtrim($stamp, "\n"))));
check('a stamp with CRLF lines', $mismatch($signed(str_replace("\n", "\r\n", $stamp))));
check('a stamp with its lines out of order',
    $mismatch($signed("run: 18734512345\npublished: 2026-10-18T17:04:05Z\ntree: FreeBSD:15:amd64/26.7\n")));
check('a stamp with a date that is not one',
    $mismatch($signed("published: 2026-13-41T17:04:05Z\nrun: 18734512345\ntree: FreeBSD:15:amd64/26.7\n")));
check('a stamp with a local time, not UTC',
    $mismatch($signed("published: 2026-10-18T17:04:05+02:00\nrun: 18734512345\ntree: FreeBSD:15:amd64/26.7\n")));
check('a stamp with a run that is not digits',
    $mismatch($signed("published: 2026-10-18T17:04:05Z\nrun: 1873x\ntree: FreeBSD:15:amd64/26.7\n")));
check('an empty stamp', $mismatch($signed('')));
$r = $signed("published: 2026-10-18T17:04:05Z\nrun: 18734512345\ntree: FreeBSD:15:amd64/26.1\n");
check('a stamp for another tree', $mismatch($r) && str_contains($r[0][1], 'FreeBSD:15:amd64/26.1'));
check('a stamp for another ABI', $mismatch($sf($stamp, $sig, $pub, [$fpr], $at, null, 'FreeBSD:16:amd64/26.7')));

check('an unreachable site is information',
    $sf(null, null, null, [$fpr], $at, 'Could not resolve host: legotypes.github.io')
    === [['INFO', 'could not fetch the stamp (Could not resolve host: legotypes.github.io)']]);
check('a fetch that failed part way is information, whatever was fetched',
    $sf($stamp, null, null, [$fpr], $at, 'Connection timed out after 3001 milliseconds')[0][0] === 'INFO');

$t = "function: \"sha256\"\nfingerprint: \"{$fpr}\"\n";
$o = "function: \"sha256\"\nfingerprint: \"{$otherFpr}\"\n";
check('trusted fingerprints are read from their files', legotypes_fingerprints([$t, $o], []) === [$fpr, $otherFpr]);
check('a revoked fingerprint is not trusted', legotypes_fingerprints([$t, $o], [$o]) === [$fpr]);
check('a file with no fingerprint adds none', legotypes_fingerprints(["function: \"sha256\"\n", ''], []) === []);

echo ($total - $fail) . "/{$total} passed\n";
exit($fail === 0 ? 0 : 1);
