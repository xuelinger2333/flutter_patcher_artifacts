import 'dart:io';

import 'package:dart2bytecode/dart2bytecode.dart' as bytecode;

import '../../generators/gen_platform_privates.dart' as privates;
import '../../generators/protocol_set/generate.dart' as protocol;
import 'kernel_tools.dart' as shapes;

const usage = '''flutter_patcher_tools
  detect-shape --dill <input> --own <pkg,...> [--exclude <substring,...>]
  transform-overlay --dill <input> --own <pkg,...> --out <output>
                    --helper-lib <library-uri> --helper-fn <function>
  bytecode <dart2bytecode arguments...>
  gen-protocol-interface --dill <linked-flutter.dill> --out <protocol.yaml>
  gen-platform-privates --platform <platform.dill> --out <privates.yaml>
''';

Future<void> main(List<String> args) async {
  if (args.length == 1 && (args.first == '--help' || args.first == '-h')) {
    stdout.write(usage);
    return;
  }
  if (args.isEmpty) {
    stderr.write(usage);
    exitCode = 64;
    return;
  }
  final rest = args.sublist(1);
  switch (args.first) {
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
