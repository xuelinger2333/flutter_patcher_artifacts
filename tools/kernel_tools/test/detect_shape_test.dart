// Structural regression tests independent of the Flutter fixture compiler.
import 'package:kernel/kernel.dart';
import 'package:flutter_patcher_kernel_tools/src/detect_shape.dart';

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

void main() {
  final binding = Library(Uri.parse('package:flutter/src/widgets/binding.dart'),
      fileUri: Uri.parse('file:///binding.dart'));
  final runApp = Procedure(
      Name('runApp'), ProcedureKind.Method, FunctionNode(EmptyStatement()),
      isStatic: true, fileUri: Uri.parse('file:///binding.dart'));
  binding.addProcedure(runApp);
  final services = Library(
      Uri.parse('package:flutter/src/services/asset_bundle.dart'),
      fileUri: Uri.parse('file:///assets.dart'));
  final bundle = Field.mutable(Name('rootBundle'),
      isStatic: true, fileUri: Uri.parse('file:///assets.dart'));
  services.addField(bundle);

  Map<String, Object?> scan(List<Statement> statements,
      {String library = 'package:own/main.dart',
      List<String> excluded = const []}) {
    final own =
        Library(Uri.parse(library), fileUri: Uri.parse('file:///main.dart'));
    own.addProcedure(Procedure(
        Name('main'), ProcedureKind.Method, FunctionNode(Block(statements)),
        isStatic: true, fileUri: Uri.parse('file:///main.dart')));
    return detectShape(Component(libraries: [binding, services, own]), {'own'},
        excluded: excluded);
  }

  Statement inject(int offset) => ExpressionStatement(
      StaticInvocation(runApp, Arguments([]))..fileOffset = offset);
  Statement bypass(int offset) =>
      ExpressionStatement(StaticGet(bundle)..fileOffset = offset);
  check(scan([])['verdict'] == 'UPGRADE', 'No entry point must upgrade');
  check(
      scan([inject(20)])['verdict'] == 'INJECTABLE', 'Direct call must inject');
  final before = scan([bypass(10), inject(20)]);
  check(before['verdict'] == 'INJECTABLE_HOLE', 'Pre-read must be a hole');
  check(((before['bypasses'] as List).single as Map)['timing'] == 'before',
      'Pre-read timing');
  final after = scan([inject(10), bypass(20)]);
  check(((after['bypasses'] as List).single as Map)['timing'] == 'unordered',
      'Post-read remains a bypass');
  check((scan([inject(10), inject(20)])['injectionPoints'] as List).length == 2,
      'All direct calls');
  check(
      scan([inject(1)], library: 'package:other/main.dart')['verdict'] ==
          'UPGRADE',
      'Package boundary');
  check(scan([inject(1)], excluded: ['main.dart'])['verdict'] == 'UPGRADE',
      'Excluded helper');
  final tearOff = scan([inject(1), ExpressionStatement(StaticTearOff(runApp))]);
  check(tearOff['verdict'] == 'UPGRADE',
      'Mixed direct call and tear-off must upgrade');
  final constant = StaticTearOffConstant(runApp);
  final folded = scan([ExpressionStatement(ConstantExpression(constant))]);
  check(
      folded['verdict'] == 'UPGRADE' &&
          (folded['tearOffs'] as List).length == 1,
      'Folded function constant must remain visible');
  print('detect_shape structural tests: 9 passed');
}
