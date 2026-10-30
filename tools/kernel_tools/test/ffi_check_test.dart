import 'package:kernel/kernel.dart';
import 'package:flutter_patcher_kernel_tools/src/patch_checks.dart';

/// Native bindings and FFI calls in module code are rejected; ordinary
/// dart:ffi use (types, pointer arithmetic) and calls into host code are not.
void main() {
  final file = Uri.parse('file:///fixture/main.dart');
  Procedure procedure(String name, {List<Expression> annotations = const []}) {
    final p = Procedure(
      Name(name),
      ProcedureKind.Method,
      FunctionNode(EmptyStatement()),
      isStatic: true,
      fileUri: file,
    );
    for (final a in annotations) {
      p.addAnnotation(a);
    }
    return p;
  }
  final ffi = Library(Uri.parse('dart:ffi'), fileUri: file);
  final core = Library(Uri.parse('dart:core'), fileUri: file);
  final native = Class(name: 'Native', fileUri: file);
  final pragma = Class(name: 'pragma', fileUri: file);
  final pragmaName = Field.immutable(Name('name'), fileUri: file);
  pragma.addField(pragmaName);
  ffi.addClass(native);
  core.addClass(pragma);
  final asFunction = procedure('NativeFunctionPointer|asFunction');
  final elementAt = procedure('Pointer|elementAt');
  ffi
    ..addProcedure(asFunction)
    ..addProcedure(elementAt);
  final host = Library(Uri.parse('package:host/api.dart'), fileUri: file);
  final hostCall = procedure('nativeHome');
  host.addProcedure(hostCall);

  int issues(List<Procedure> procedures) {
    final module = Library(Uri.parse('package:patch.1.app/main.dart'), fileUri: file);
    for (final p in procedures) {
      module.addProcedure(p);
    }
    Component(libraries: [ffi, core, host, module]);
    final check = FfiCheck();
    module.accept(check);
    return check.issues.length;
  }

  Procedure calling(Procedure target) => Procedure(
    Name('main'),
    ProcedureKind.Method,
    FunctionNode(
      ExpressionStatement(StaticInvocation(target, Arguments([]))),
    ),
    isStatic: true,
    fileUri: file,
  );
  final cases = {
    'asFunction call': (issues([calling(asFunction)]), 1),
    '@Native binding': (
      issues([
        procedure(
          'home',
          annotations: [ConstantExpression(InstanceConstant(native.reference, [], {}))],
        ),
      ]),
      1,
    ),
    'lowered vm:ffi:native pragma': (
      issues([
        procedure(
          'home',
          annotations: [
            ConstantExpression(
              InstanceConstant(pragma.reference, [], {
                pragmaName.fieldReference: StringConstant('vm:ffi:native'),
              }),
            ),
          ],
        ),
      ]),
      1,
    ),
    'pointer arithmetic': (issues([calling(elementAt)]), 0),
    'host call': (issues([calling(hostCall)]), 0),
  };
  for (final MapEntry(key: name, value: (actual, expected)) in cases.entries) {
    if (actual != expected) {
      throw StateError('$name: $actual issues, expected $expected');
    }
  }
  print('ffi check: ${cases.length} cases passed');
}
