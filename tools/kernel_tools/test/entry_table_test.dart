import 'package:kernel/kernel.dart';
import 'package:kernel/core_types.dart';
import 'package:flutter_patcher_kernel_tools/src/patch_checks.dart';

/// The PatchEntry's table: every vm:entry-point static method of the module
/// and its main, keyed by the host's declaration, as the engine hook asks.
void main() {
  final file = Uri.parse('file:///fixture/main.dart');
  final core = Library(Uri.parse('dart:core'), fileUri: file);
  final pragma = Class(name: 'pragma', fileUri: file);
  final name = Field.immutable(Name('name'), fileUri: file);
  pragma.addField(name);
  core.addClass(pragma);
  // What CoreTypes reads for the table's key and value types.
  core.addClass(Class(name: 'String', fileUri: file));
  core.addClass(Class(name: 'Function', fileUri: file));
  core.addClass(Class(name: 'Map', fileUri: file));
  ConstantExpression mark(String value) => ConstantExpression(
    InstanceConstant(pragma.reference, [], {
      name.fieldReference: StringConstant(value),
    }),
  );
  Procedure method(
    String text, {
    bool entry = true,
    bool isStatic = true,
    ProcedureKind kind = ProcedureKind.Method,
    Library? library,
  }) => Procedure(
    Name(text, library),
    kind,
    FunctionNode(EmptyStatement()),
    isStatic: isStatic,
    fileUri: file,
  )..annotations = [if (entry) mark('vm:entry-point')];

  final app = Library(
    Uri.parse('package:patch.4.app/main.dart'),
    fileUri: file,
  );
  final bg = Library(
    Uri.parse('package:patch.4.app/src/bg.dart'),
    fileUri: file,
  );
  final carried = Library(
    Uri.parse('package:patch.4.http/http.dart'),
    fileUri: file,
  );
  final appMain = method('main', entry: false);
  app.addProcedure(appMain);
  bg.addProcedure(method('callbackDispatcher'));
  bg.addProcedure(method('_privateCallback', library: bg));
  bg.addProcedure(method('plain', entry: false));
  bg.addProcedure(method('getter', kind: ProcedureKind.Getter));
  final worker = Class(name: 'Worker', fileUri: file);
  worker.addProcedure(method('run'));
  worker.addProcedure(method('instance', isStatic: false));
  bg.addClass(worker);
  carried.addProcedure(method('carriedEntry'));
  final slots = <Expression>[
    IntLiteral(1),
    IntLiteral(4),
    StringLiteral('fp'),
    StringLiteral('lean'),
    StaticTearOff(appMain),
    NullLiteral(),
  ];
  final list = ListLiteral(slots);
  final entry = Procedure(
    Name('dynamicModuleEntrypoint'),
    ProcedureKind.Method,
    FunctionNode(ReturnStatement(list)),
    isStatic: true,
    fileUri: file,
  )..annotations = [mark('vm:entry-point'), mark('dyn-module:entry-point')];
  final patch = Library(
    Uri.parse('package:patch.4.app/patch_entry.dart'),
    fileUri: file,
  )..addProcedure(entry);
  final module = [app, bg, carried, patch];

  final entries = entryPoints(module, slots);
  final expected = [
    'package:app/main.dart#main',
    'package:app/src/bg.dart#Worker.run',
    'package:app/src/bg.dart#_privateCallback',
    'package:app/src/bg.dart#callbackDispatcher',
    'package:http/http.dart#carriedEntry',
  ];
  final keys = entries.keys.toList()..sort();
  if (keys.join(',') != expected.join(','))
    throw StateError('Entry keys differ: $keys');
  if (entryKey(
        method('x')
          ..parent = Library(Uri.parse('package:host/a.dart'), fileUri: file),
      ) !=
      'package:host/a.dart#x')
    throw StateError('A host library key must stay as it is');

  final types = CoreTypes(Component(libraries: [core, ...module]));
  installEntryTable(slots, entries, types);
  final table = list.expressions[5];
  if (table is! ConstantExpression || table.constant is! MapConstant)
    throw StateError('No entry table: $table');
  final built = {
    for (final e in (table.constant as MapConstant).entries)
      (e.key as StringConstant).value:
          (e.value as StaticTearOffConstant).target,
  };
  if (built.keys.join(',') != expected.join(',') ||
      built['package:app/main.dart#main'] != appMain)
    throw StateError('Entry table differs: $built');
  try {
    installEntryTable(list.expressions, entries, types);
    throw StateError('A filled table was replaced again');
  } on StateError catch (e) {
    if (!'$e'.contains('not empty')) rethrow;
  }
  print('PASS entry points, host keys and the PatchEntry table');
}
