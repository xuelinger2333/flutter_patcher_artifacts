import 'dart:convert';
import 'dart:io';
import 'package:kernel/kernel.dart';
import 'package:kernel/class_hierarchy.dart';
import 'package:kernel/core_types.dart';
import 'package:dart2bytecode/bytecode_serialization.dart';
import 'package:dart2bytecode/declarations.dart' as bc;
import 'patch_checks.dart';

const patchCheckUsage =
    '''  check-allocations --dill <linked-analysis.dill> --own <packages> --allocated <allocate_finalized.json>
  check-inherited --dill <linked-analysis.dill> --own <packages> --iface <yaml> --compiler-interface <json>
  verify-structure --bytecode <module.bc> --expect-prefix <package:patch.seq.> --forbid-prefix <package:app/>
''';

Future<Map<String, Object?>> patchCheckCommand(
  String command,
  List<String> args,
) async {
  final allowed = command == 'verify-structure'
      ? {'--bytecode', '--expect-prefix', '--forbid-prefix'}
      : command == 'check-allocations'
      ? {'--dill', '--own', '--allocated'}
      : {'--dill', '--own', '--iface', '--compiler-interface'};
  final options = <String, String>{};
  for (var i = 0; i < args.length; i += 2) {
    if (i + 1 >= args.length ||
        !allowed.contains(args[i]) ||
        options.containsKey(args[i]))
      throw FormatException('Invalid analysis options');
    options[args[i]] = args[i + 1];
  }
  String need(String name) {
    if (options[name]?.isNotEmpty != true)
      throw FormatException('Missing $name');
    return options[name]!;
  }

  if (command == 'verify-structure') {
    final decoded = bc.Component.read(
      BufferedReader(
        LinkReader(),
        await File(need('--bytecode')).readAsBytes(),
      ),
    );
    final uris = decoded.libraries
        .map((l) => (l.importUri as dynamic).value as String)
        .toList();
    final expected = need('--expect-prefix'),
        forbidden = need('--forbid-prefix');
    final count = uris.where((u) => u.startsWith(forbidden)).length;
    final ok =
        uris.isNotEmpty &&
        count == 0 &&
        uris.every((u) => u.startsWith(expected)) &&
        decoded.dynModuleEntryPoint != null &&
        decoded.sourcePositions.isEmpty;
    return {
      'ok': ok,
      'counts': {
        'libraries': uris.length,
        'forbidden': count,
        'source_positions': decoded.sourcePositions.length,
      },
      'libraries': uris,
    };
  }
  final component = loadComponentFromBinary(need('--dill'));
  final names = need('--own').split(',').toSet();
  final own = component.libraries
      .where(
        (l) =>
            l.importUri.scheme == 'package' &&
            names.contains(l.importUri.pathSegments.first),
      )
      .toList();
  if (own.isEmpty) throw FormatException('No module libraries match --own');
  final host = component.libraries.where((l) => !own.contains(l)).toSet();
  if (command == 'check-allocations') {
    final data =
        jsonDecode(await File(need('--allocated')).readAsString()) as Map;
    final check = AllocationCheck(
      host,
      (data['classes'] as List).cast<String>().toSet(),
    );
    for (final lib in own) lib.accept(check);
    return {'violations': check.issues};
  }
  return {
    'violations': inheritedCheck(
      component,
      ClassHierarchy(component, CoreTypes(component)),
      host,
      own,
      await File(need('--iface')).readAsString(),
      await File(need('--compiler-interface')).readAsString(),
    ),
  };
}
