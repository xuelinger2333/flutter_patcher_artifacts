"""CI-only malformed PatchEntry fixtures; never included in release attachments."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess


def build(dart, tool, platform, interface, fingerprint, seq, out, tier='lean'):
    if len(fingerprint) != 64 or any(c not in '0123456789abcdef' for c in fingerprint) or seq < 1:
        raise ValueError('Invalid fixture identity')
    out.mkdir(parents=True, exist_ok=False)
    if tier not in ['lean', 'whole']: raise ValueError('Invalid tier')
    # Fixtures import only SDK libraries. The validator resolves every listed
    # class, so app/Flutter entries cannot be passed to this minimal component.
    # Project the generated JSON interface without adding any permissions.
    specification = json.loads(interface.read_text())
    core_interface = out / 'core-interface.json'
    core_interface.write_text(json.dumps({section: [row for row in rows
        if row['library'].startswith('dart:')]
        for section, rows in specification.items()}, indent=2))
    prefix = f'1,{seq},"{fingerprint}","{tier}",'
    sources = {
        'entry-short': '<Object?>[1]',
        'entry-not-function': f'<Object?>[{prefix}42,null]',
        'main-throws': f'<Object?>[{prefix}fail,null]',
        'main-hangs': f'<Object?>[{prefix}hang,null]',
    }
    records = {}
    for name, expression in sources.items():
        source = out / f'{name}.dart'
        source.write_text('@pragma("vm:entry-point")\n@pragma("dyn-module:entry-point")\n'
            f'Object? dynamicModuleEntrypoint() => {expression};\n'
            'void fail() { throw StateError("WP9 intentional boot failure"); }\n'
            'void hang() { while (true) {} }\n')
        output = out / f'{name}.bc'
        subprocess.run([str(dart), str(tool), 'bytecode', '--platform', str(platform),
            '--target', 'flutter', '--validate', str(core_interface), '--aot-only',
            '-o', str(output), str(source)], check=True)
        data = output.read_bytes()
        if len(data) < 120 or data[:4] != b'3CBD':
            raise ValueError('Compiler did not emit the pinned DBC3 format')
        records[name] = dict(bytes=len(data), sha256=hashlib.sha256(data).hexdigest())
    (out / 'modules.json').write_text(json.dumps({'schema': 1, 'fingerprint': fingerprint,
        'seq': seq, 'tier': tier, 'files': records}, indent=2) + '\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    for name in ['dart', 'tool', 'platform', 'interface', 'out']:
        parser.add_argument('--' + name, required=True, type=Path)
    parser.add_argument('--fingerprint', required=True)
    parser.add_argument('--seq', required=True, type=int)
    parser.add_argument('--tier', choices=['lean', 'whole'], default='lean')
    build(**vars(parser.parse_args()))
