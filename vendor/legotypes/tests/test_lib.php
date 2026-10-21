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
$tree = 'FreeBSD:15:amd64/26.7';
/* what the site answered for one file */
$ok = fn (string $body): array => ['status' => 200, 'body' => $body];
$http = fn (int $status): array => ['status' => $status, 'body' => "<html>{$status}</html>"];
$valid = ['stamp' => $ok($stamp), 'stamp.sig' => $ok($sig), 'stamp.pub' => $ok($pub)];
/* three files the site answered 200 for */
$sf = fn (string $s, string $g, string $p, array $t, int $now, string $tr = 'FreeBSD:15:amd64/26.7'): array =>
    legotypes_stamp_findings(['stamp' => $ok($s), 'stamp.sig' => $ok($g), 'stamp.pub' => $ok($p)], null, $t, $now, $tr);
/* the valid answers with some replaced, or only the files given, and a transport failure */
$answers = fn (array $over): array => legotypes_stamp_findings(array_replace($valid, $over), null, [$fpr], $at, $tree);
$fetched = fn (array $files, ?array $transport): array => legotypes_stamp_findings($files, $transport, [$fpr], $at, $tree);
$mismatch = fn (array $r): bool => count($r) === 1 && $r[0][0] === 'MISMATCH';
$info = fn (array $r): bool => count($r) === 1 && $r[0][0] === 'INFO';

check('a valid stamp is information with its age',
    $sf($stamp, $sig, $pub, [$fpr], $at + 3 * 86400 + 3600) === [['INFO', 'catalogue published 2026-10-18T17:04:05Z (3 days ago)']]);
check('a valid stamp a day old',
    $sf($stamp, $sig, $pub, [$fpr], $at + 86400) === [['INFO', 'catalogue published 2026-10-18T17:04:05Z (1 day ago)']]);
check('a valid stamp published today',
    $sf($stamp, $sig, $pub, [$fpr], $at + 60) === [['INFO', 'catalogue published 2026-10-18T17:04:05Z (0 days ago)']]);
check('a stamp a little ahead of this clock is within the skew',
    $sf($stamp, $sig, $pub, [$fpr], $at - 300) === [['INFO', 'catalogue published 2026-10-18T17:04:05Z (0 days ago)']]);
check('a valid stamp among several trusted fingerprints', $sf($stamp, $sig, $pub, [$otherFpr, $fpr], $at)[0][0] === 'INFO');
check('a stamp dated beyond the skew means this clock is behind: information', $sf($stamp, $sig, $pub, [$fpr], $at - 301)
    === [['INFO', "catalogue stamp is dated 2026-10-18T17:04:05Z, ahead of this firewall's clock (2026-10-18T16:59:04Z)"]]);

check('a signature by another key', $mismatch($sf($stamp, $sign($stamp, $other), $pub, [$fpr], $at)));
check('a stamp changed after signing',
    $mismatch($sf(str_replace('2026-10-18', '2026-10-20', $stamp), $sig, $pub, [$fpr], $at + 3 * 86400)));
check('a signature that is not one', $mismatch($sf($stamp, 'not a signature', $pub, [$fpr], $at)));
check('an empty signature', $mismatch($sf($stamp, '', $pub, [$fpr], $at)));
$r = $sf($stamp, $sign($stamp, $other), $otherPub, [$fpr], $at);
check('a stamp signed and keyed by an untrusted key', $mismatch($r) && str_contains($r[0][1], 'not a trusted'));
check('no trusted fingerprint at all', $mismatch($sf($stamp, $sig, $pub, [], $at)));
check('a trusted stamp.pub that is not a key', $mismatch($sf($stamp, $sig, 'not a key', [hash('sha256', 'not a key')], $at)));

check('the valid answers', $info($answers([])));
$r = $answers(['stamp' => $http(404)]);
check('no stamp (HTTP 404)', $mismatch($r) && str_contains($r[0][1], '(stamp: HTTP 404)'));
$r = $answers(['stamp.sig' => $http(404)]);
check('no stamp.sig (HTTP 404)', $mismatch($r) && str_contains($r[0][1], '(stamp.sig: HTTP 404)'));
$r = $answers(['stamp.pub' => $http(404)]);
check('no stamp.pub (HTTP 404)', $mismatch($r) && str_contains($r[0][1], '(stamp.pub: HTTP 404)'));
$r = $answers(['stamp' => $http(404), 'stamp.sig' => $http(404), 'stamp.pub' => $http(404)]);
check('none of the three (HTTP 404)', $mismatch($r)
    && $r[0][1] === 'the repository answers without a catalogue stamp (stamp: HTTP 404, stamp.sig: HTTP 404, stamp.pub: HTTP 404)');
$r = $answers(['stamp' => $http(301)]);
check('a redirect (HTTP 301) is not the stamp', $mismatch($r) && str_contains($r[0][1], 'stamp: HTTP 301'));
$r = $answers(['stamp.sig' => $http(403)]);
check('HTTP 403 is not the stamp', $mismatch($r) && str_contains($r[0][1], 'stamp.sig: HTTP 403'));
$r = $answers(['stamp.pub' => $http(410)]);
check('HTTP 410 is not the stamp', $mismatch($r) && str_contains($r[0][1], 'stamp.pub: HTTP 410'));
check('an outage (HTTP 503) is information', $answers(['stamp.sig' => $http(503)])
    === [['INFO', 'could not fetch the stamp (HTTP 503 for stamp.sig)']]);
check('an outage (HTTP 500) is information', $info($answers(['stamp' => $http(500)])));
check('a 404 beside an outage is a mismatch', $mismatch($answers(['stamp' => $http(404), 'stamp.sig' => $http(503)])));

/* the library is pure: curl's "file size exceeded" is its own constant, equal to curl's */
check('the size cap error is curl\'s file size exceeded (63)', LEGOTYPES_CURLE_FILESIZE_EXCEEDED === 63
    && (!defined('CURLE_FILESIZE_EXCEEDED') || constant('CURLE_FILESIZE_EXCEEDED') === LEGOTYPES_CURLE_FILESIZE_EXCEEDED));
$libText = (string)file_get_contents(__DIR__ . '/../src/opnsense/scripts/LegoTypes/lib.php');
check('lib.php names no curl constant or function', preg_match('/(?<![A-Z_])CURL[A-Z]*_|\bcurl_/', $libText) === 0);
check('lib.php keeps its doc lines within 120 characters', array_filter(explode("\n", $libText),
    fn (string $l): bool => preg_match('/^\s*(\/\*\*|\*)/', $l) === 1 && strlen($l) > 120) === []);
$big = ['file' => 'stamp.pub', 'errno' => LEGOTYPES_CURLE_FILESIZE_EXCEEDED, 'error' => 'Maximum file size exceeded'];
$r = $fetched(['stamp' => $ok($stamp), 'stamp.sig' => $ok($sig)], $big);
check('a stamp file over the cap is a mismatch', $mismatch($r) && str_contains($r[0][1], 'stamp.pub is too large'));
check('an unreachable site is information',
    $fetched([], ['file' => 'stamp', 'errno' => 6, 'error' => 'Could not resolve host: legotypes.github.io'])
    === [['INFO', 'could not fetch the stamp (Could not resolve host: legotypes.github.io)']]);
check('a refused connection is information',
    $info($fetched([], ['file' => 'stamp', 'errno' => 7, 'error' => 'Failed to connect to 127.0.0.1 port 443'])));
check('a fetch that timed out after the stamp came is information',
    $info($fetched(['stamp' => $ok($stamp)], ['file' => 'stamp.sig', 'errno' => 28, 'error' => 'Connection timed out after 3001 milliseconds'])));
check('a 404 before a fetch timed out is a mismatch',
    $mismatch($fetched(['stamp' => $http(404)], ['file' => 'stamp.sig', 'errno' => 28, 'error' => 'Operation timed out'])));
$r = $fetched(['stamp' => $ok($stamp), 'stamp.pub' => $ok($pub)], null);
check('a file with no answer and no transport failure is a mismatch', $mismatch($r) && str_contains($r[0][1], 'stamp.sig: no answer'));

/*
 * a signature that does not verify is fetched once more before it is a mismatch: a deploy can land
 * between the fetches (a new stamp beside the old stamp.sig); nothing else is fetched again
 */
$calls = 0;
$fetches = function (array ...$answers) use (&$calls): callable {
    $calls = 0;
    return function () use (&$calls, $answers): array {
        $calls++;
        return [$answers[min($calls, count($answers)) - 1], null];
    };
};
$newer = "published: 2026-10-18T18:00:00Z\nrun: 18734512399\ntree: FreeBSD:15:amd64/26.7\n";
$torn = ['stamp' => $ok($newer), 'stamp.sig' => $ok($sig), 'stamp.pub' => $ok($pub)];
$deployed = ['stamp' => $ok($newer), 'stamp.sig' => $ok($sign($newer, $key)), 'stamp.pub' => $ok($pub)];
$r = legotypes_stamp_check($fetches($torn, $deployed), [$fpr], $at + 3600, $tree);
check('a deploy between the fetches: fetched again, the new stamp',
    $r === [['INFO', 'catalogue published 2026-10-18T18:00:00Z (0 days ago)']] && $calls === 2);
$r = legotypes_stamp_check($fetches($torn, $torn), [$fpr], $at + 3600, $tree);
check('a signature that still does not verify is a mismatch',
    $r === [['MISMATCH', 'the catalogue stamp signature does not verify']] && $calls === 2);
$r = legotypes_stamp_check($fetches($valid), [$fpr], $at, $tree);
check('a valid stamp is fetched once', $r === [['INFO', 'catalogue published 2026-10-18T17:04:05Z (0 days ago)']]
    && $calls === 1);
$r = legotypes_stamp_check($fetches(array_replace($valid, ['stamp' => $http(404)]), $valid), [$fpr], $at, $tree);
check('a 404 is not fetched again', $mismatch($r) && str_contains($r[0][1], 'stamp: HTTP 404') && $calls === 1);
$r = legotypes_stamp_check($fetches($valid, $valid), [$otherFpr], $at, $tree);
check('an untrusted key is not fetched again', $mismatch($r) && str_contains($r[0][1], 'not a trusted') && $calls === 1);
$r = legotypes_stamp_check($fetches($torn, array_replace($valid, ['stamp.sig' => $http(503)])), [$fpr], $at, $tree);
check('fetched again during an outage: information, as any outage',
    $r === [['INFO', 'could not fetch the stamp (HTTP 503 for stamp.sig)']] && $calls === 2);

/* the output: mismatches, information, and the fit line only when nothing mismatches, the stamp included */
check('the report with a mismatch has no fit line', legotypes_report(['the catalogue stamp signature does not verify'],
    ['os-a 1.0: update available (1.1)'], '26.7', 'FreeBSD:15:amd64')
    === ['MISMATCH: the catalogue stamp signature does not verify', 'INFO: os-a 1.0: update available (1.1)']);
check('the report with no mismatch ends with the fit line', legotypes_report([], ['catalogue published x (0 days ago)'],
    '26.7', 'FreeBSD:15:amd64')
    === ['INFO: catalogue published x (0 days ago)', 'LegoTypes packages fit series 26.7 on FreeBSD:15:amd64']);
check('the report lists every mismatch before the information', legotypes_report(['a', 'b'], ['c'], '26.7', 'X')
    === ['MISMATCH: a', 'MISMATCH: b', 'INFO: c']);

$signed = fn (string $s): array => $sf($s, $sign($s, $key), $pub, [$fpr], $at);
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
check('a stamp for another ABI', $mismatch($sf($stamp, $sig, $pub, [$fpr], $at, 'FreeBSD:16:amd64/26.7')));

/* fingerprint files: trusted read as strictly as pkg trusts (anything else is not trusted), revoked read loosely */
$t = "function: \"sha256\"\nfingerprint: \"{$fpr}\"\n";
$o = "function: \"sha256\"\nfingerprint: \"{$otherFpr}\"\n";
check('trusted fingerprints are read from their files', legotypes_fingerprints([$t, $o], []) === [$fpr, $otherFpr]);
check('a revoked fingerprint is not trusted', legotypes_fingerprints([$t, $o], [$o]) === [$fpr]);
check('a file with no fingerprint adds none', legotypes_fingerprints(["function: \"sha256\"\n", ''], []) === []);
check('a revocation written fingerprint = "...";',
    legotypes_fingerprints([$t, $o], ["function = \"sha256\";\nfingerprint = \"{$otherFpr}\";\n"]) === [$fpr]);
check('a revocation written as JSON on one line',
    legotypes_fingerprints([$t, $o], ["{\"function\": \"sha256\", \"fingerprint\": \"{$otherFpr}\"}"]) === [$fpr]);
check('a revocation in upper case', legotypes_fingerprints([$t, $o], ['fingerprint: "' . strtoupper($otherFpr) . "\"\n"]) === [$fpr]);
check('a revocation with no function line', legotypes_fingerprints([$t], ["fingerprint: {$fpr}\n"]) === []);
check('trusted: keys in any case, written with =, quoted keys',
    legotypes_fingerprints(["FUNCTION = \"SHA256\";\nFingerprint = \"{$fpr}\";\n", "\"function\": \"sha256\",\n\"fingerprint\": \"{$otherFpr}\",\n"], [])
    === [$fpr, $otherFpr]);
check('trusted: no function line, not trusted (as pkg)', legotypes_fingerprints(["fingerprint: \"{$fpr}\"\n"], []) === []);
check('trusted: another function, not trusted', legotypes_fingerprints(["function: \"sha1\"\nfingerprint: \"{$fpr}\"\n"], []) === []);
check('trusted: a commented-out fingerprint is not trusted',
    legotypes_fingerprints(["function: \"sha256\"\n# fingerprint: \"{$fpr}\"\n"], []) === []);
check('trusted: upper case never matches a key (pkg compares exactly)',
    legotypes_fingerprints(['function: "sha256"' . "\nfingerprint: \"" . strtoupper($fpr) . "\"\n"], []) === []);
$shipped = glob(__DIR__ . '/../src/etc/pkg/fingerprints/LegoTypes/trusted/*') ?: [];
check('every shipped trusted file gives its fingerprint', $shipped !== []
    && count(legotypes_fingerprints(array_map(fn (string $f): string => (string)file_get_contents($f), $shipped), [])) === count($shipped));
check('trusted: the last fingerprint in a file is the one (as pkg)', legotypes_fingerprints([$t . "fingerprint: \"{$otherFpr}\"\n"], []) === [$otherFpr]);

echo ($total - $fail) . "/{$total} passed\n";
exit($fail === 0 ? 0 : 1);
