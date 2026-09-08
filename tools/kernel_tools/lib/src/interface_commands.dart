import 'dart:io';
import 'package:kernel/kernel.dart';
import 'extract_surface.dart';
import 'interface_document.dart';
import 'interface_defaults.dart';
import 'resolve_interface_hints.dart';
import 'trim_interface.dart';

const interfaceUsage = '''
  extract-surface --dill <app.dill> --own <pkg,...> --out-iface <yaml> --out-trim-iface <yaml>
  merge-interface --dill <linked.dill> --iface <yaml> --trim-iface <yaml> --protocol <yaml>
                  --mode lean|whole [--platform-privates <yaml>] [--additions <yaml>]
                  --out-iface <yaml> --out-trim-iface <yaml>
  resolve-interface-hints --dill <module-index.dill> --own <pkg,...> --log <file> --out <yaml>
  trim-interface --dill <app.dill> --platform <platform.dill> --trim-iface <yaml>
                 --out <app-trim.dill> --out-platform <platform-trim.dill>
''';

Future<Map<String, Object?>> interfaceCommand(
  String command,
  List<String> args,
) async {
  final allowed = switch (command) {
    'trim-interface' => {
      '--dill',
      '--platform',
      '--trim-iface',
      '--out',
      '--out-platform',
    },
    'extract-surface' => {'--dill', '--own', '--out-iface', '--out-trim-iface'},
    'resolve-interface-hints' => {'--dill', '--own', '--log', '--out'},
    'merge-interface' => {
      '--dill',
      '--iface',
      '--trim-iface',
      '--protocol',
      '--mode',
      '--platform-privates',
      '--additions',
      '--out-iface',
      '--out-trim-iface',
    },
    _ => throw FormatException('Unknown interface command: $command'),
  };
  final options = <String, String>{};
  for (var i = 0; i < args.length; i += 2) {
    if (!allowed.contains(args[i]) ||
        options.containsKey(args[i]) ||
        i + 1 >= args.length ||
        args[i + 1].startsWith('--')) {
      throw FormatException('Invalid or duplicate option: ${args[i]}');
    }
    options[args[i]] = args[i + 1];
  }
  String required(String name) {
    final v = options[name];
    if (v == null || v.isEmpty) throw FormatException('Missing $name');
    return v;
  }

  Set<String> own() {
    final result = required('--own').split(',').toSet();
    if (result.any((s) => !RegExp(r'^[a-zA-Z_][a-zA-Z_0-9]*$').hasMatch(s))) {
      throw const FormatException('Invalid --own packages');
    }
    return result;
  }

  if (command == 'trim-interface') {
    await trimInterface(
      required('--dill'),
      required('--platform'),
      required('--trim-iface'),
      required('--out'),
      required('--out-platform'),
    );
    return {'trimmed': true};
  }
  final component = loadComponentFromBinary(required('--dill'));
  InterfaceDocument read(String option) =>
      InterfaceDocument.parse(File(required(option)).readAsStringSync());
  void write(String option, InterfaceDocument doc) {
    final f = File(required(option));
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(doc.encode(), flush: true);
  }

  if (command == 'resolve-interface-hints') {
    final doc = resolveInterfaceHints(
      component,
      own(),
      File(required('--log')).readAsStringSync(),
    );
    write('--out', doc);
    return {
      'resolved': InterfaceDocument.sections.fold<int>(
        0,
        (n, s) => n + doc.count(s),
      ),
    };
  }
  final out = File(required('--out-iface')).absolute.path;
  if (out == File(required('--out-trim-iface')).absolute.path) {
    throw const FormatException('Interface outputs must be distinct');
  }
  if (command == 'extract-surface') {
    final surface = extractSurface(component, own());
    write('--out-iface', surface.interface);
    write('--out-trim-iface', surface.trim);
    return surface.counts;
  }
  final mode = required('--mode');
  if (!['lean', 'whole'].contains(mode))
    throw const FormatException('Invalid --mode');
  final doc = read('--iface')
    ..merge(read('--protocol'))
    ..merge(interfaceDefaults(component, whole: mode == 'whole'));
  if (mode == 'whole') doc.merge(read('--platform-privates'));
  if (options.containsKey('--additions')) doc.merge(read('--additions'));
  final trim = read('--trim-iface')..merge(doc);
  write('--out-iface', doc);
  write('--out-trim-iface', trim);
  return {
    'entries': InterfaceDocument.sections.fold<int>(
      0,
      (n, s) => n + doc.count(s),
    ),
    'mode': mode,
    'dynamic_selectors': mode == 'whole' ? dynamicSelectors : <String>[],
  };
}
