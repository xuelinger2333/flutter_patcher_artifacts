"""End-to-end interface extraction and bytecode validation, usable with a CI dill or source entry."""
import argparse
import json
import hashlib
from pathlib import Path
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'engine/scripts'))
import hosts  # noqa: E402


def exercise(dart, entry, flutter, fixtures, source, work):
    work.mkdir(parents=True, exist_ok=False)
    def call(*args):
        result = subprocess.run([str(dart), str(entry), *map(str, args)],
                                capture_output=True, text=True)
        if result.returncode:
            raise RuntimeError(result.stderr + result.stdout)
        return result.stdout
    platform = flutter / 'bin/cache/artifacts/engine/common/flutter_patched_sdk_product/platform_strong.dill'
    index = fixtures / 'shape1.dill'
    packages = source / 'tools/kernel_tools/test/fixtures/.dart_tool/package_config.json'
    module = source / 'tools/kernel_tools/test/fixtures/interfaces/module.dart'
    call('extract-surface', '--dill', index, '--own', 'shape_fixtures',
         '--out-iface', work / 'refs.yaml', '--out-trim-iface', work / 'refs-trim.yaml')
    call('gen-protocol-interface', '--dill', index, '--out', work / 'protocol.yaml')
    call('gen-platform-privates', '--platform', platform, '--out', work / 'privates.yaml')
    # Index the module's imports instead of borrowing the baseline import graph.
    module_index = work / 'module-index.dill'
    index_entry = work / 'index-entry.dart'
    index_entry.write_text(f'import {json.dumps(module.as_uri())};\nvoid main() {{}}\n')
    host = hosts.current()
    frontend = flutter / hosts.toolchain_file(host, 'frontend_server_aot.dart.snapshot')
    subprocess.run([str(hosts.dart_binary(host, flutter, 'dartaotruntime')), str(frontend),
                    '--sdk-root', str(platform.parent) + '/', '--target', 'flutter',
                    '--no-aot', '--no-tfa', '--link-platform', '--packages', str(packages),
                    '--output-dill', str(module_index), str(index_entry)], check=True)
    results = {}
    for mode in ('lean', 'whole'):
        previous = work / 'refs.yaml'
        previous_trim = work / 'refs-trim.yaml'
        additions = []
        previous_details = None
        for iteration in range(1, 6):
            iface = work / f'{mode}-{iteration}.yaml'
            trim = work / f'{mode}-{iteration}-trim.yaml'
            details = work / f'{mode}-{iteration}-details.json'
            common = ['merge-interface', '--dill', index, '--iface', previous,
                      '--trim-iface', previous_trim, '--protocol', work / 'protocol.yaml',
                      '--mode', mode, '--out-iface', iface, '--out-trim-iface', trim,
                      '--out-details', details]
            if previous_details:
                common += ['--details-in', previous_details]
            if mode == 'whole':
                common += ['--platform-privates', work / 'privates.yaml']
            call(*common, *additions)
            # Same inputs must produce byte-identical outputs.
            first = (iface.read_bytes(), trim.read_bytes(), details.read_bytes())
            call(*common, *additions)
            assert first == (iface.read_bytes(), trim.read_bytes(), details.read_bytes())
            detail = json.loads(details.read_text())
            assert detail['interface_sha256'] == hashlib.sha256(iface.read_bytes()).hexdigest()
            assert all(row['sources'] for row in detail['entries'])
            output = work / f'{mode}-{iteration}.bytecode'
            validation_platform = platform
            imports = []
            if mode == 'lean':
                validation_platform = work / f'{mode}-{iteration}-platform.dill'
                imported = work / f'{mode}-{iteration}-host.dill'
                call('trim-interface', '--dill', index, '--platform', platform,
                     '--trim-iface', trim, '--out', imported, '--out-platform', validation_platform)
                imports = ['--import-dill', imported]
            args = ['bytecode', '--platform', validation_platform, *imports, '--target', 'flutter',
                    '--packages', packages, '--validate', iface, '--aot-only',
                    '--prefix-library-uris', 'interface_validation', '-o', output]
            if mode == 'whole':
                args += ['--allow-dynamic-calls-in-dynamic-modules',
                         '--extra-selectors-allowed-in-dynamic-calls=-,+,*,get:index,relativeError,absoluteError']
            result = subprocess.run([str(dart), str(entry), *map(str, args), str(module)],
                                    capture_output=True, text=True)
            log = work / f'{mode}-{iteration}.log'
            log.write_text(result.stderr + '\n' + result.stdout)
            if result.returncode == 0:
                assert output.is_file() and output.stat().st_size > 0
                data = json.loads(iface.read_text())
                assert not any(r.get('class') == 'Object' for r in data['dynamically-callable'])
                results[mode] = {'rounds': iteration, 'bytecode_bytes': output.stat().st_size}
                break
            if iteration == 5:
                raise RuntimeError(f'{mode} did not converge: {log.read_text()}')
            patch = work / f'{mode}-{iteration}-additions.yaml'
            call('resolve-interface-hints', '--dill', module_index, '--own', 'shape_fixtures',
                 '--log', log, '--out', patch)
            previous, previous_trim = iface, trim
            previous_details = details
            additions = ['--additions', patch]
    (work / 'verification.json').write_text(json.dumps(results, indent=2) + '\n')
    return results


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('dart', 'entry', 'flutter', 'fixtures', 'source', 'work'):
        parser.add_argument('--' + name, type=Path, required=True)
    options = parser.parse_args()
    print(json.dumps(exercise(**vars(options)), indent=2))
