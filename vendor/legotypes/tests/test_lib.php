<?php

declare(strict_types=1);

/*
 * Copyright (C) 2026 cayossarian (Bill Flood)
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

echo ($total - $fail) . "/{$total} passed\n";
exit($fail === 0 ? 0 : 1);
