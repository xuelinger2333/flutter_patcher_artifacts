import 'dart:convert';
import 'dart:io';

import 'package:kernel/kernel.dart';
import 'package:flutter_patcher_kernel_tools/src/detect_shape.dart';
import 'package:flutter_patcher_kernel_tools/src/transform_overlay.dart';

const usage = '''flutter_patcher_kernel_tools
  detect-shape --dill <input> --own <pkg,...> [--exclude <substring,...>]
  transform-overlay --dill <input> --own <pkg,...> --out <output>
                    --helper-lib <library-uri> --helper-fn <function>
Results are JSON. Only the WP-1b migrated shape tools are available in this version.
''';

Future<void> main(List<String> args) async {
  if (args.length == 1 && (args[0] == '--help' || args[0] == '-h')) {
    stdout.write(usage);
    return;
  }
  try {
    if (args.isEmpty) throw const FormatException('A subcommand is required');
    final command = args.first;
    final allowed = switch (command) {
      'detect-shape' => {'--dill', '--own', '--exclude'},
      'transform-overlay' => {
          '--dill',
          '--own',
          '--out',
          '--helper-lib',
          '--helper-fn'
        },
      _ => throw FormatException('Unknown subcommand: $command'),
    };
    final values = <String, String>{};
    for (var i = 1; i < args.length; i += 2) {
      if (!allowed.contains(args[i]) ||
          values.containsKey(args[i]) ||
          i + 1 >= args.length ||
          args[i + 1].startsWith('--')) {
        throw FormatException('Invalid or duplicate option: ${args[i]}');
      }
      values[args[i]] = args[i + 1];
    }
    String required(String key) {
      final value = values[key];
      if (value == null || value.isEmpty) throw FormatException('Missing $key');
      return value;
    }

    final input = required('--dill');
    final own = required('--own').split(',').toSet();
    if (own.any((p) => !RegExp(r'^[a-zA-Z_][a-zA-Z_0-9]*$').hasMatch(p))) {
      throw const FormatException('Invalid package name in --own');
    }
    final result = command == 'detect-shape'
        ? detectShape(loadComponentFromBinary(input), own,
            excluded: values['--exclude']?.split(',') ?? const [])
        : await transformOverlay(input, required('--out'), own,
            required('--helper-lib'), required('--helper-fn'));
    stdout.writeln(jsonEncode(result));
  } catch (error) {
    stderr.writeln(jsonEncode({'error': error.toString()}));
    exitCode = error is FormatException ? 64 : 1;
  }
}
