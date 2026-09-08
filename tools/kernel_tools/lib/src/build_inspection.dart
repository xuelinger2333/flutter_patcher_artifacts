import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:kernel/kernel.dart';

void need(bool value, String reason) {
  if (!value) throw FormatException(reason);
}

/// Pinned VM trace format: four cells per entity; only bare class references
/// represent AddInstantiatedClass. A C event consumes a function reference.
List<String> allocatedClasses(Map<String, dynamic> data) {
  final entities = data['entities'],
      strings = data['strings'],
      trace = data['trace'];
  need(
    entities is List &&
        entities.length % 4 == 0 &&
        strings is List &&
        strings.every((v) => v is String) &&
        trace is List,
    'Malformed precompiler trace tables',
  );
  final e = entities as List, s = strings as List, t = trace as List;
  String stringAt(dynamic index) {
    need(
      index is int && index >= 0 && index < s.length,
      'Invalid trace string reference',
    );
    return s[index as int] as String;
  }

  void entity(dynamic id) => need(
    id is int && id >= 0 && id * 4 < e.length,
    'Invalid trace entity reference',
  );
  final result = <String>{};
  var ended = false;
  for (var i = 0; i < t.length; i++) {
    final item = t[i];
    if (item is String) {
      switch (item) {
        case 'R':
          break;
        case 'E':
          need(i == t.length - 1, 'Trailing trace events');
          ended = true;
        case 'C':
        case 'S':
        case 'T':
          need(i + 1 < t.length, 'Truncated trace event');
          entity(t[++i]);
        default:
          throw FormatException('Unknown trace event $item');
      }
    } else {
      entity(item);
      final id = item as int;
      if (e[id * 4] == 'C') {
        final library = stringAt(e[id * 4 + 1]), type = stringAt(e[id * 4 + 2]);
        need(
          (library.startsWith('dart:') || library.startsWith('package:')) &&
              type.isNotEmpty,
          'Class identity is not portable: $library::$type',
        );
        result.add('$library::$type');
      }
    }
  }
  need(ended && result.isNotEmpty, 'Incomplete/empty allocation trace');
  return result.toList()..sort();
}

const buildInspectionUsage =
    '  inspect-build --dill <app-only.dill> --packages <package_config.json> --out <directory> [--trace <json>] [--compiler-interface <json>]\n';
Future<Map<String, Object?>> inspectBuild(List<String> args) async {
  final options = <String, String>{};
  for (var i = 0; i < args.length; i += 2) {
    need(
      i + 1 < args.length &&
          [
            '--dill',
            '--packages',
            '--out',
            '--trace',
            '--compiler-interface',
          ].contains(args[i]) &&
          !options.containsKey(args[i]),
      'Invalid inspect-build options',
    );
    options[args[i]] = args[i + 1];
  }
  String required(String key) {
    need(options[key]?.isNotEmpty == true, 'Missing $key');
    return options[key]!;
  }

  final component = loadComponentFromBinary(required('--dill'));
  need(
    !component.libraries.any((l) => l.importUri.scheme == 'dart'),
    'Baseline must not link platform libraries',
  );
  final configFile = File(required('--packages')).absolute;
  final config = jsonDecode(configFile.readAsStringSync()) as Map;
  final roots = <String, Uri>{};
  for (final row in config['packages'] as List) {
    final packageRoot = configFile.uri.resolve(row['rootUri'] as String);
    final root = Uri.parse(
      '${packageRoot.toString().replaceFirst(RegExp(r"/+$"), "")}/',
    ).resolve(row['packageUri'] as String? ?? '');
    roots[row['name'] as String] = root;
  }
  final hashes = <String, String>{};
  for (final uri in component.uriToSource.keys) {
    if (uri.scheme != 'file' || !uri.path.endsWith('.dart')) continue;
    final candidates =
        roots.entries
            .where((r) => uri.toString().startsWith(r.value.toString()))
            .toList()
          ..sort(
            (a, b) =>
                b.value.toString().length.compareTo(a.value.toString().length),
          );
    if (candidates.isEmpty) {
      // SDK internal sources are bound by the selected SDK/platform identity.
      need(
        uri.path.contains('/bin/cache/dart-sdk/'),
        'Source is outside resolved packages: $uri',
      );
      continue;
    }
    final match = candidates.first;
    final relative = uri.toString().substring(match.value.toString().length);
    final file = File.fromUri(uri);
    need(file.existsSync(), 'Compiled source disappeared: $uri');
    hashes['package:${match.key}/$relative'] = sha256
        .convert(file.readAsBytesSync())
        .toString();
  }
  need(hashes.isNotEmpty, 'No portable source hashes found');
  final out = Directory(required('--out'))..createSync(recursive: true);
  void write(String name, Object value) => File(
    '${out.path}/$name',
  ).writeAsStringSync('${jsonEncode(value)}\n', flush: true);
  write('source_hashes.json', {
    'schema': 1,
    'files': {for (final key in hashes.keys.toList()..sort()) key: hashes[key]},
  });
  if (options.containsKey('--trace')) {
    write('allocate_finalized.json', {
      'schema': 1,
      'classes': allocatedClasses(
        jsonDecode(File(options['--trace']!).readAsStringSync())
            as Map<String, dynamic>,
      ),
    });
  }
  if (options.containsKey('--compiler-interface')) {
    final value = jsonDecode(
      File(options['--compiler-interface']!).readAsStringSync(),
    );
    need(
      value is Map &&
          value.isNotEmpty &&
          value.values.every(
            (v) =>
                v is List &&
                v.every((r) => r is Map && r.values.every((x) => x is String)),
          ),
      'Invalid compiler dynamic interface dump',
    );
  }
  final receipt = {
    'app_only': true,
    'libraries': component.libraries.length,
    'source_files': hashes.length,
    'main_library': component.mainMethod?.enclosingLibrary.importUri.toString(),
  };
  write('kernel_receipt.json', receipt);
  return receipt;
}
