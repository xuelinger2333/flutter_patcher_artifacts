import 'dart:io';
import 'dart:convert';
import 'package:flutter_patcher_kernel_tools/src/interface_commands.dart';
import 'package:flutter_patcher_kernel_tools/src/build_inspection.dart';
import 'package:vm/kernel_front_end.dart' as kernelCompiler;

import 'package:dart2bytecode/dart2bytecode.dart' as bytecode;

import '../../generators/gen_platform_privates.dart' as privates;
import '../../generators/protocol_set/generate.dart' as protocol;
import 'kernel_tools.dart' as shapes;

const usage = '''flutter_patcher_tools
  compile-baseline <pinned gen_kernel arguments...>
  detect-shape --dill <input> --own <pkg,...> [--exclude <substring,...>]
  transform-overlay --dill <input> --own <pkg,...> --out <output>
                    --helper-lib <library-uri> --helper-fn <function>
  bytecode <dart2bytecode arguments...>
  gen-protocol-interface --dill <linked-flutter.dill> --out <protocol.yaml>
  gen-platform-privates --platform <platform.dill> --out <privates.yaml>
''';

Future<void> main(List<String> args) async {
  if (args.length == 1 && (args.first == '--help' || args.first == '-h')) {
    stdout.write('$usage$interfaceUsage$buildInspectionUsage');
    return;
  }
  if (args.isEmpty) {
    stderr.write(usage);
    exitCode = 64;
    return;
  }
  final rest = args.sublist(1);
  switch (args.first) {
    case 'compile-baseline':
      try {
        exitCode = await kernelCompiler.runCompiler(
          kernelCompiler.createCompilerArgParser().parse(rest),
          'compile-baseline',
        );
      } catch (error) {
        stderr.writeln(jsonEncode({'error': error.toString()}));
        exitCode = 2;
      }
    case 'inspect-build':
      try {
        stdout.writeln(jsonEncode(await inspectBuild(rest)));
      } catch (error) {
        stderr.writeln(jsonEncode({'error': error.toString()}));
        exitCode = 2;
      }
    case 'extract-surface':
    case 'merge-interface':
    case 'resolve-interface-hints':
    case 'trim-interface':
      if (rest.length == 1 && ['--help', '-h'].contains(rest.first)) {
        stdout.write(interfaceUsage);
        return;
      }
      try {
        stdout.writeln(jsonEncode(await interfaceCommand(args.first, rest)));
      } catch (error) {
        stderr.writeln(jsonEncode({'error': error.toString()}));
        exitCode = error is FormatException ? 2 : 1;
      }
    case 'bytecode':
      // Use the upstream entry point, preserving its argument and exit behavior.
      await bytecode.main(rest);
    case 'gen-protocol-interface':
    case 'gen-platform-privates':
      if (rest.length == 1 && (rest.first == '--help' || rest.first == '-h')) {
        stdout.write(usage);
        return;
      }
      try {
        if (args.first == 'gen-protocol-interface') {
          protocol.main(rest);
        } else {
          privates.main(rest);
        }
      } catch (error) {
        stderr.writeln(error);
        exitCode = error is ArgumentError ? 64 : 1;
      }
    default:
      await shapes.main(args);
  }
}
