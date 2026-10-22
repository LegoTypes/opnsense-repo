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
/*
 * the stamp is one file: the body lines, the key PEM, and "signature: <base64>" over the sha256 hex of every
 * byte before it, as pkg's signing_command signs a catalogue file; $seal adds that line to a body
 */
$seal = function (string $signed, OpenSSLAsymmetricKey $k): string {
    openssl_sign(hash('sha256', $signed), $sig, $k, OPENSSL_ALGO_SHA256);
    return $signed . 'signature: ' . base64_encode($sig) . "\n";
};
$at = gmmktime(17, 4, 5, 10, 18, 2026);
$head = "published: 2026-10-18T17:04:05Z\nrun: 18734512345\ntree: FreeBSD:15:amd64/26.7\n";
$stamp = $seal($head . $pub, $key);
$tree = 'FreeBSD:15:amd64/26.7';
/* what the site answered */
$ok = fn (string $body): array => ['status' => 200, 'body' => $body];
$http = fn (int $status): array => ['status' => $status, 'body' => "<html>{$status}</html>"];
/* a stamp the site answered 200 for, or another answer, or a transport failure */
$sf = fn (string $s, array $t, int $now, string $tr = 'FreeBSD:15:amd64/26.7'): array =>
    legotypes_stamp_findings($ok($s), null, $t, $now, $tr);
$fetched = fn (?array $answer, ?array $transport): array => legotypes_stamp_findings($answer, $transport, [$fpr], $at, $tree);
$mismatch = fn (array $r): bool => count($r) === 1 && $r[0][0] === 'MISMATCH';
$info = fn (array $r): bool => count($r) === 1 && $r[0][0] === 'INFO';

check('a valid stamp is information with its age',
    $sf($stamp, [$fpr], $at + 3 * 86400 + 3600) === [['INFO', 'catalogue published 2026-10-18T17:04:05Z (3 days ago)']]);
check('a valid stamp a day old',
    $sf($stamp, [$fpr], $at + 86400) === [['INFO', 'catalogue published 2026-10-18T17:04:05Z (1 day ago)']]);
check('a valid stamp published today',
    $sf($stamp, [$fpr], $at + 60) === [['INFO', 'catalogue published 2026-10-18T17:04:05Z (0 days ago)']]);
check('a stamp a little ahead of this clock is within the skew',
    $sf($stamp, [$fpr], $at - 300) === [['INFO', 'catalogue published 2026-10-18T17:04:05Z (0 days ago)']]);
check('a valid stamp among several trusted fingerprints', $sf($stamp, [$otherFpr, $fpr], $at)[0][0] === 'INFO');
check('a stamp dated beyond the skew means this clock is behind: information', $sf($stamp, [$fpr], $at - 301)
    === [['INFO', "catalogue stamp is dated 2026-10-18T17:04:05Z, ahead of this firewall's clock (2026-10-18T16:59:04Z)"]]);
/* the fingerprint is the sha256 of the key block's bytes, as pkg fingerprints a key and a trusted file names it */
check('the trusted fingerprint is the sha256 of the embedded key block, byte for byte',
    legotypes_fingerprints(["function: \"sha256\"\nfingerprint: \"" . hash('sha256', $pub) . "\"\n"], []) === [$fpr]
    && $sf($stamp, legotypes_fingerprints(["function: \"sha256\"\nfingerprint: \"{$fpr}\"\n"], []), $at)[0][0] === 'INFO');

$bad = fn (array $r): bool => $r === [['MISMATCH', 'the catalogue stamp signature does not verify']];
check('a signature by another key', $bad($sf($seal($head . $pub, $other), [$fpr], $at)));
check('a body edited after signing (its date)',
    $bad($sf(str_replace('2026-10-18T17', '2026-10-20T17', $stamp), [$fpr], $at + 3 * 86400)));
check('a body edited after signing (its tree)', $bad($sf(str_replace('amd64/26.7', 'amd64/26.1', $stamp), [$fpr], $at)));
check('a signature line that is not base64', $mismatch($sf($head . $pub . "signature: not*base64\n", [$fpr], $at)));
check('a signature that is not one', $bad($sf($head . $pub . 'signature: ' . base64_encode('nope') . "\n", [$fpr], $at)));
$r = $sf($seal($head . $otherPub, $other), [$fpr], $at);
check('a key block whose fingerprint is not trusted', $mismatch($r) && str_contains($r[0][1], 'not a trusted'));
check('no trusted fingerprint at all', $mismatch($sf($stamp, [], $at)));
check('a revoked key is not trusted', $mismatch($sf($stamp, legotypes_fingerprints(
    ["function: \"sha256\"\nfingerprint: \"{$fpr}\"\n"], ["fingerprint: \"{$fpr}\"\n"]), $at)));
$notKey = "-----BEGIN PUBLIC KEY-----\nAAAA\n-----END PUBLIC KEY-----\n";
check('a trusted key block that is not a key', $bad($sf($seal($head . $notKey, $key), [hash('sha256', $notKey)], $at)));

check('the valid stamp', $info($fetched($ok($stamp), null)));
$r = $fetched($http(404), null);
check('no stamp (HTTP 404)', $mismatch($r)
    && $r[0][1] === 'the repository answers without a catalogue stamp (HTTP 404)');
$r = $fetched($http(301), null);
check('a redirect (HTTP 301) is not the stamp', $mismatch($r) && str_contains($r[0][1], 'HTTP 301'));
check('HTTP 403 is not the stamp', $mismatch($fetched($http(403), null)));
check('HTTP 410 is not the stamp', $mismatch($fetched($http(410), null)));
check('an outage (HTTP 503) is information', $fetched($http(503), null) === [['INFO', 'could not fetch the stamp (HTTP 503)']]);
check('an outage (HTTP 500) is information', $info($fetched($http(500), null)));

/* the library is pure: curl's "file size exceeded" is its own constant, equal to curl's */
check('the size cap error is curl\'s file size exceeded (63)', LEGOTYPES_CURLE_FILESIZE_EXCEEDED === 63
    && (!defined('CURLE_FILESIZE_EXCEEDED') || constant('CURLE_FILESIZE_EXCEEDED') === LEGOTYPES_CURLE_FILESIZE_EXCEEDED));
$libText = (string)file_get_contents(__DIR__ . '/../src/opnsense/scripts/LegoTypes/lib.php');
check('lib.php names no curl constant or function', preg_match('/(?<![A-Z_])CURL[A-Z]*_|\bcurl_/', $libText) === 0);
check('lib.php keeps every line within 120 characters',
    array_filter(explode("\n", $libText), fn (string $l): bool => strlen($l) > 120) === []);
$r = $fetched(null, ['errno' => LEGOTYPES_CURLE_FILESIZE_EXCEEDED, 'error' => 'Maximum file size exceeded']);
check('a stamp over the cap (curl stopped it) is a mismatch', $mismatch($r) && str_contains($r[0][1], 'too large'));
$r = $sf(str_repeat('A', LEGOTYPES_STAMP_MAX_BYTES + 1), [$fpr], $at);
check('a stamp over the cap (given whole) is a mismatch', $mismatch($r) && str_contains($r[0][1], 'too large'));
check('an unreachable site is information',
    $fetched(null, ['errno' => 6, 'error' => 'Could not resolve host: legotypes.github.io'])
    === [['INFO', 'could not fetch the stamp (Could not resolve host: legotypes.github.io)']]);
check('a refused connection is information',
    $info($fetched(null, ['errno' => 7, 'error' => 'Failed to connect to 127.0.0.1 port 443'])));
check('a timeout is information', $info($fetched(null, ['errno' => 28, 'error' => 'Operation timed out'])));
check('no answer and no transport failure is a mismatch', $mismatch($fetched(null, null)));
check('lib.php fetches nothing again (one atomic file)', !function_exists('legotypes_stamp_check'));

/* the output: mismatches, information, and the fit line only when nothing mismatches, the stamp included */
check('the report with a mismatch has no fit line', legotypes_report(['the catalogue stamp signature does not verify'],
    ['os-a 1.0: update available (1.1)'], '26.7', 'FreeBSD:15:amd64')
    === ['MISMATCH: the catalogue stamp signature does not verify', 'INFO: os-a 1.0: update available (1.1)']);
check('the report with no mismatch ends with the fit line', legotypes_report([], ['catalogue published x (0 days ago)'],
    '26.7', 'FreeBSD:15:amd64')
    === ['INFO: catalogue published x (0 days ago)', 'LegoTypes packages fit series 26.7 on FreeBSD:15:amd64']);
check('the report lists every mismatch before the information', legotypes_report(['a', 'b'], ['c'], '26.7', 'X')
    === ['MISMATCH: a', 'MISMATCH: b', 'INFO: c']);

/* the format: every field once and in order, one key block, the signature line last, printable ASCII and LF only */
$signed = fn (string $body): array => $sf($seal($body, $key), [$fpr], $at);
$malformed = fn (array $r): bool => $r === [['MISMATCH', 'the catalogue stamp is malformed']];
$run = "run: 18734512345\n";
$pubd = "published: 2026-10-18T17:04:05Z\n";
$tr = "tree: FreeBSD:15:amd64/26.7\n";
check('a stamp with no run', $malformed($signed($pubd . $tr . $pub)));
check('a stamp with a field twice', $malformed($signed($pubd . $run . $run . $tr . $pub)));
check('a stamp with its lines out of order', $malformed($signed($run . $pubd . $tr . $pub)));
check('a stamp with two key blocks', $malformed($signed($head . $pub . $pub)));
check('a stamp with no key block', $malformed($signed($head)));
$pl = explode("\n", $pub);
check('a stamp with a key line over 64 characters',
    $malformed($signed($head . $pl[0] . "\n" . $pl[1] . $pl[2] . "\n" . implode("\n", array_slice($pl, 3)))));
check('a stamp with a line after the signature', $malformed($sf($stamp . "note: hello\n", [$fpr], $at)));
check('a stamp with a blank line at the end', $malformed($sf($stamp . "\n", [$fpr], $at)));
check('a stamp with a second signature line', $malformed($sf($stamp . substr($stamp, strrpos(rtrim($stamp, "\n"), "\n") + 1), [$fpr], $at)));
check('a stamp without its final newline', $malformed($sf(rtrim($stamp, "\n"), [$fpr], $at)));
check('a stamp with CRLF lines', $malformed($signed(str_replace("\n", "\r\n", $head . $pub))));
check('a stamp with a byte beyond ASCII', $malformed($signed(str_replace('26.7', "26.7\u{e9}", $head) . $pub)));
check('a stamp with a tab', $malformed($signed(str_replace('run: ', "run:\t", $head) . $pub)));
check('a stamp with a date that is not one',
    $malformed($signed("published: 2026-13-41T17:04:05Z\n" . $run . $tr . $pub)));
check('a stamp with a local time, not UTC',
    $malformed($signed("published: 2026-10-18T17:04:05+02:00\n" . $run . $tr . $pub)));
check('a stamp with a run that is not digits', $malformed($signed($pubd . "run: 1873x\n" . $tr . $pub)));
check('a stamp with an empty tree', $malformed($signed($pubd . $run . "tree: \n" . $pub)));
check('the three-file stamp (no key block, no signature line)', $malformed($sf($head, [$fpr], $at)));
/* a real date and time of day: the same list stamp-check.sh is tested with (stamp-dates.txt) */
$judged = [];
foreach (file(__DIR__ . '/stamp-dates.txt', FILE_IGNORE_NEW_LINES) ?: [] as $line) {
    if (preg_match('/^(valid|invalid) (\S+)$/', $line, $d) !== 1) {
        continue;
    }
    $r = $sf($seal("published: {$d[2]}\n" . $run . $tr . $pub, $key), [$fpr], gmmktime(0, 0, 0, 1, 1, 2200));
    $got = $malformed($r) ? 'invalid' : ($info($r) ? 'valid' : 'other');
    if ($got !== $d[1]) {
        $judged[] = "{$d[2]}:{$got}";
    }
}
check('every date in stamp-dates.txt judged as stamp-check.sh judges it', $judged === []);
check('stamp-dates.txt holds both kinds', count(preg_grep('/^valid /', file(__DIR__ . '/stamp-dates.txt') ?: [])) === 7
    && count(preg_grep('/^invalid /', file(__DIR__ . '/stamp-dates.txt') ?: [])) === 15);
check('an empty stamp', $malformed($sf('', [$fpr], $at)));
$r = $signed("published: 2026-10-18T17:04:05Z\nrun: 18734512345\ntree: FreeBSD:15:amd64/26.1\n" . $pub);
check('a stamp for another tree', $mismatch($r) && str_contains($r[0][1], 'FreeBSD:15:amd64/26.1'));
check('a stamp for another ABI', $mismatch($sf($stamp, [$fpr], $at, 'FreeBSD:16:amd64/26.7')));

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
