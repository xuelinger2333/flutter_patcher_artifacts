import 'dart:convert';
import 'dart:typed_data';
import 'package:kernel/kernel.dart';
import 'package:flutter_patcher_kernel_tools/src/patch_checks.dart';

void main() {
  final file = Uri.parse('file:///fixture/main.dart');
  final host = Library(Uri.parse('package:host/api.dart'), fileUri: file);
  final app = Library(
    Uri.parse('package:patch.1.app/main.dart'),
    fileUri: file,
  );
  final cls = Class(name: 'Host', fileUri: file);
  final ctor = Constructor(
    FunctionNode(EmptyStatement()),
    name: Name(''),
    fileUri: file,
  );
  cls.addConstructor(ctor);
  host.addClass(cls);
  final factory = Procedure(
    Name('factory'),
    ProcedureKind.Factory,
    FunctionNode(EmptyStatement()),
    fileUri: file,
    isStatic: true,
  );
  cls.addProcedure(factory);
  final calls = [
    ExpressionStatement(
      ConstructorInvocation(ctor, Arguments([]))..fileOffset = 3,
    ),
    ExpressionStatement(
      StaticInvocation(factory, Arguments([]))..fileOffset = 5,
    ),
    ExpressionStatement(
      ConstantExpression(
        ListConstant(const DynamicType(), [
          InstanceConstant(cls.reference, [], {}),
        ]),
      )..fileOffset = 7,
    ),
    ExpressionStatement(ConstructorTearOff(ctor)..fileOffset = 9),
  ];
  app.addProcedure(
    Procedure(
      Name('main'),
      ProcedureKind.Method,
      FunctionNode(Block(calls)),
      isStatic: true,
      fileUri: file,
    )..fileOffset = 0,
  );
  final component = Component(libraries: [host, app]);
  component.uriToSource[file] = Source(
    [0, 16],
    Uint8List.fromList(utf8.encode('0123456789abcdef')),
    app.importUri,
    file,
  );
  final missing = AllocationCheck({host}, {});
  app.accept(missing);
  if (missing.issues.length != 3)
    throw StateError(
      'Expected new/constant/tearoff; factory must not be counted: ${missing.issues}',
    );
  if (missing.issues.any((r) => r['line'] != 1 || r['file'] != file.toString()))
    throw StateError('Source location missing');
  final safe = AllocationCheck({host}, {'package:host/api.dart::Host'});
  app.accept(safe);
  if (safe.issues.isNotEmpty) throw StateError('Allocated class rejected');
  final local = AllocationCheck({}, {});
  app.accept(local);
  if (local.issues.isNotEmpty)
    throw StateError('Module class mistaken for host');
  print(
    'PASS allocation sites, constant graph, factory semantics and locations',
  );
}
