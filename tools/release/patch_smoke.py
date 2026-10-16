"""Exercise patch compilation and checks with the CI-produced tools dill, without a device or release."""
import json
import subprocess


def exercise(dart, tool, flutter, baseline, work, *, packages=None, four_check_source=None):
    work.mkdir()
    package = work / 'app'
    package.mkdir()
    config = work / 'package_config.json'
    rows = []
    if packages is not None:
        from urllib.parse import urljoin
        for row in json.loads(packages.read_text())['packages']:
            rows.append({**row, 'rootUri': urljoin(packages.as_uri(), row['rootUri'])})
    config.write_text(json.dumps({'configVersion': 2, 'packages': [*rows,
        {'name': 'patch.7.smoke', 'rootUri': package.as_uri() + '/',
         'packageUri': '', 'languageVersion': '3.13'}]}))
    interface = work / 'interface.yaml'
    interface.write_text(json.dumps({name: [{'library': 'dart:core'}] for name in
        ['callable', 'extendable', 'can-be-used-as-type', 'can-be-overridden']}))
    detailed = work / 'compiler-interface.json'
    detailed.write_text('{"callable":[]}')
    allocated = work / 'allocated.json'
    allocated.write_text('{"schema":1,"classes":["dart:core::pragma"]}')
    results = {}
    for tier in ['lean', 'whole']:
        (package / 'main.dart').write_text(
            '@pragma("vm:entry-point")\n@pragma("dyn-module:entry-point")\n'
            'Object? dynamicModuleEntrypoint() => <Object?>[1,7,"' + 'a' * 64 +
            '","' + tier + '",patchedMain,null];\nvoid patchedMain() { print("patch smoke"); }\n')
        request = work / f'{tier}-request.json'
        request.write_text(json.dumps({
            'tier': tier, 'emit': True, 'seq': 7, 'fingerprint': 'a' * 64,
            'entry': 'package:patch.7.smoke/main.dart', 'packages': str(config),
            'platform': str(flutter / 'bin/cache/artifacts/engine/common/flutter_patched_sdk_product/platform_strong.dill'),
            'baseline': str(baseline), 'interface': str(interface),
            'compiler_interface': str(detailed), 'allocated': str(allocated),
            'resources': False, 'own': ['patch.7.smoke'], 'original_own': ['smoke'],
            'out': str(work / f'{tier}.bc')}))
        result = subprocess.run([str(dart), str(tool), 'compile-patch', '--request', str(request)],
                                text=True, capture_output=True, check=True)
        report = json.loads(result.stdout)
        assert report['status'] == 'compiled', report
        assert report['emitted_libraries'] == ['package:patch.7.smoke/main.dart'], report
        assert report['bytes'] > 120, report
        results[tier] = report
    bad = json.loads(request.read_text())
    bad['seq'] = 8
    bad['out'] = str(work / 'must-not-exist.bc')
    invalid = work / 'invalid-entry.json'
    invalid.write_text(json.dumps(bad))
    rejected = subprocess.run([str(dart), str(tool), 'compile-patch', '--request', str(invalid)],
                              text=True, capture_output=True)
    assert rejected.returncode != 0 and not (work / 'must-not-exist.bc').exists()
    if four_check_source is not None:
        (package / 'four_checks.dart').write_text(four_check_source.read_text())
        (package / 'main.dart').write_text('import "four_checks.dart" as sample;\n'
            '@pragma("vm:entry-point")\n@pragma("dyn-module:entry-point")\n'
            'Object? dynamicModuleEntrypoint() => <Object?>[1,7,"' + 'a' * 64 +
            '","lean",sample.main,null];\n')
        check = json.loads(request.read_text())
        check.update(tier='lean', emit=False, resources=True)
        four = work / 'four-checks.json'
        four.write_text(json.dumps(check))
        result = subprocess.run([str(dart), str(tool), 'compile-patch', '--request', str(four)],
                                text=True, capture_output=True, check=True)
        report = json.loads(result.stdout)
        assert report['status'] == 'rejected', report
        for category in ['interface', 'allocation', 'inherited']:
            assert report['checks'][category], report
            assert all(row.get('file') and row.get('line') and row.get('column')
                       for row in report['checks'][category]), report
        assert report['checks']['resources']['verdict'] == 'INJECTABLE_HOLE', report
        results['four_checks'] = report
    (work / 'verification.json').write_text(json.dumps(results, indent=2) + '\n')
    return results
