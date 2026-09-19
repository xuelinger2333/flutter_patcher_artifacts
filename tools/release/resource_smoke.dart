import 'dart:io';
import 'dart:convert';
import 'package:kernel/kernel.dart';

Future<void> main(List<String> args) async {
  final root = args[0],
      tool = args[1],
      helper = args[4],
      packageConfig = args[5];
  final baseline = args[2];
  final sdk = args[3];
  final work = Directory(
    '$root/tool-smoke-${DateTime.now().microsecondsSinceEpoch}',
  );
  await work.create();
  final app = Directory('${work.path}/app');
  await app.create();
  await File(helper).copy('${app.path}/__patch_overlay.dart');
  await File('${app.path}/main.dart').writeAsString('''
import 'package:flutter/material.dart';
import '__patch_overlay.dart' as overlay;
@pragma('vm:entry-point')
@pragma('dyn-module:entry-point')
Object? dynamicModuleEntrypoint() => <Object?>[1,7,'${'a' * 64}','LEAN',main,overlay.patcherInstallAssets];
void main() {
 if (DateTime.now().millisecond.isEven) {runApp(const MaterialApp(home: Icon(Icons.home)));}
 else {runApp(const MaterialApp(home: Icon(Icons.rocket_launch)));}
}
''');
  final data = jsonDecode(await File(packageConfig).readAsString()) as Map;
  data['packages'] = [
    for (final row in data['packages'] as List)
      {
        ...row as Map,
        'rootUri': File(
          packageConfig,
        ).absolute.uri.resolve(row['rootUri'] as String).toString(),
      },
    {
      'name': 'patch.7.smoke',
      'rootUri': app.uri.toString(),
      'packageUri': '',
      'languageVersion': '3.13',
    },
  ];
  await File('${work.path}/packages.json').writeAsString(jsonEncode(data));
  final component = loadComponentFromBinary(
    '$sdk/bin/cache/artifacts/engine/common/flutter_patched_sdk_product/platform_strong.dill',
  );
  loadComponentFromBinary('$baseline/app.dill', component);
  final libraries = component.libraries;
  final iface = {
    for (final s in [
      'callable',
      'extendable',
      'can-be-used-as-type',
      'can-be-overridden',
    ])
      s: [
        for (final l in libraries) ...[
          {'library': l.importUri.toString()},
          for (final c in l.classes)
            {'library': '${l.importUri}', 'class': c.name},
        ],
      ],
  };
  iface['callable']!.addAll([
    for (final member in ['_fromLiteral', '_fromKeyValues'])
      {'library': 'dart:core', 'class': 'Map', 'member': member},
  ]);
  iface['can-be-overridden']!.add({
    'library': 'dart:collection',
    'class': 'UnmodifiableListView',
    'member': '_source',
  });
  await File('${work.path}/lean.yaml').writeAsString(jsonEncode(iface));
  await File('${work.path}/whole.yaml').writeAsString(
    jsonEncode({
      for (final s in iface.keys)
        s: [
          for (final row in iface[s]!)
            if ((row['library'] as String).startsWith('dart:')) row,
        ],
    }),
  );
  final allocated = {
    'schema': 1,
    'classes': [
      for (final l in libraries)
        for (final c in l.classes) '${l.importUri}::${c.name}',
    ],
  };
  await File(
    '${work.path}/allocated.json',
  ).writeAsString(jsonEncode(allocated));
  await File('${work.path}/compiler.json').writeAsString(
    jsonEncode({
      'callable': [
        for (final l in libraries)
          for (final c in l.classes)
            for (final m in c.members)
              {
                'library': '${l.importUri}',
                'class': c.name,
                'member': m.name.text,
              },
      ],
    }),
  );
  final reports = <String, dynamic>{};
  for (final tier in ['lean', 'whole']) {
    final source = File('${app.path}/main.dart');
    await source.writeAsString(
      (await source.readAsString()).replaceAll(
        tier == 'lean' ? 'LEAN' : "'lean'",
        tier == 'lean' ? 'lean' : "'whole'",
      ),
    );
    final req = {
      'tier': tier,
      'emit': true,
      'seq': 7,
      'fingerprint': 'a' * 64,
      'entry': 'package:patch.7.smoke/main.dart',
      'packages': '${work.path}/packages.json',
      'platform':
          '$sdk/bin/cache/artifacts/engine/common/flutter_patched_sdk_product/platform_strong.dill',
      'baseline': '$baseline/app.dill',
      'interface': '${work.path}/$tier.yaml',
      'compiler_interface': '${work.path}/compiler.json',
      'allocated': '${work.path}/allocated.json',
      'resources': true,
      'own': ['patch.7.smoke'],
      'original_own': ['smoke'],
      'overlay_library': 'package:patch.7.smoke/__patch_overlay.dart',
      'out': '${work.path}/$tier.bc',
      'kernel_out': '${work.path}/$tier.dill',
    };
    final input = File('${work.path}/$tier.json');
    await input.writeAsString(jsonEncode(req));
    final dart = '$sdk/bin/cache/dart-sdk/bin/dart${Platform.isWindows ? '.exe' : ''}';
    final result = await Process.run(dart, [
      tool,
      'compile-patch',
      '--request',
      input.path,
    ]);
    await File(
      '${work.path}/$tier.log',
    ).writeAsString('${result.stdout}\n${result.stderr}');
    if (result.exitCode != 0)
      throw StateError('Compiler failed: ${work.path}/$tier.log');
    final report = jsonDecode(result.stdout as String) as Map;
    if (report['status'] != 'compiled')
      throw StateError('Not compiled: ${work.path}/$tier.log');
    final overlay = report['overlay'] as Map;
    if (tier == 'lean'
        ? overlay['wrapped'] != 2
        : overlay['root_bundle_replaced'] != true) {
      throw StateError('Missing resource transform');
    }
    final points = {
      for (final font in report['fonts'] as List) font['codePoint'],
    };
    if (!points.containsAll([58136, 984413]) ||
        (report['dynamic_fonts'] as List).isNotEmpty) {
      throw StateError('Lost referenced icon codepoints');
    }
    reports[tier] = report;
  }
  await File(
    '$root/tool-smoke.json',
  ).writeAsString(jsonEncode({'work': work.path, 'reports': reports}));
  print('PASS two tiers: ${work.path}');
}
