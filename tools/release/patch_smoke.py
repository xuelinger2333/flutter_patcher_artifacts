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
    interface.write_text(json.dumps({name: [{'library': 'dart:core'},
                                            {'library': 'package:shape_fixtures/host_fields.dart'}] for name in
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
            '","' + tier + '",patchedMain,null];\n'
            'void patchedMain() { print(const String.fromEnvironment("SMOKE_DEFINE", defaultValue: "smoke-undefined")); }\n')
        request = work / f'{tier}-request.json'
        request.write_text(json.dumps({
            'tier': tier, 'emit': True, 'seq': 7, 'fingerprint': 'a' * 64, 'target_os': 'android',
            'entry': 'package:patch.7.smoke/main.dart', 'packages': str(config),
            'platform': str(flutter / 'bin/cache/artifacts/engine/common/flutter_patched_sdk_product/platform_strong.dill'),
            'baseline': str(baseline), 'interface': str(interface),
            'compiler_interface': str(detailed), 'allocated': str(allocated),
            'own': ['patch.7.smoke'], 'original_own': ['smoke'],
            'environment_defines': {'SMOKE_DEFINE': 'smoke-defined'},
            'out': str(work / f'{tier}.bc')}))
        result = subprocess.run([str(dart), str(tool), 'compile-patch', '--request', str(request)],
                                text=True, capture_output=True, check=True)
        report = json.loads(result.stdout)
        assert report['status'] == 'compiled', report
        assert report['emitted_libraries'] == ['package:patch.7.smoke/main.dart'], report
        assert report['bytes'] > 120, report
        # The request's defines are the ones the module is compiled with.
        module = (work / f'{tier}.bc').read_bytes()
        assert b'smoke-defined' in module and b'smoke-undefined' not in module, 'environment_defines not applied'
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
        check.update(tier='lean', emit=False)
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
        results['four_checks'] = report
    # Host static fields are read as the device's host has them: directly
    # where its AOT build folded the initializer to a literal, through the
    # getter where the VM initializes lazily (issue #19).
    entry = ('import "package:shape_fixtures/host_fields.dart";\n'
             '@pragma("vm:entry-point")\n@pragma("dyn-module:entry-point")\n'
             'Object? dynamicModuleEntrypoint() => <Object?>[1,7,"' + 'a' * 64 +
             '","lean",patchedMain,null];\n')
    (package / 'main.dart').write_text(entry + 'void patchedMain() { print([HostFields.hostFoldedNull, '
                                      'HostFields.hostFoldedPlatform, HostFields.hostConstRef]); }\n')
    fields = json.loads(request.read_text())
    fields.update(tier='lean', emit=True, out=str(work / 'host-fields.bc'))
    host_fields = work / 'host-fields.json'
    host_fields.write_text(json.dumps(fields))
    result = subprocess.run([str(dart), str(tool), 'compile-patch', '--request', str(host_fields)],
                            text=True, capture_output=True, check=True)
    report = json.loads(result.stdout)
    assert report['status'] == 'compiled', report
    module = (work / 'host-fields.bc').read_bytes()
    assert b'get:hostConstRef' in module, 'lazy host field read without its getter'
    assert b'get:hostFolded' not in module, 'getter the host folded away is called'
    # The host keeps no setter for a static field: assigning one that needs it is rejected.
    (package / 'main.dart').write_text(entry + 'void patchedMain() { HostFields.hostLateFinal = 1; }\n')
    fields.update(emit=False)
    host_fields.write_text(json.dumps(fields))
    result = subprocess.run([str(dart), str(tool), 'compile-patch', '--request', str(host_fields)],
                            text=True, capture_output=True, check=True)
    report = json.loads(result.stdout)
    assert report['status'] == 'rejected' and report['checks']['host_fields'][0]['line'], report
    results['host_fields'] = report
    (work / 'verification.json').write_text(json.dumps(results, indent=2) + '\n')
    return results
