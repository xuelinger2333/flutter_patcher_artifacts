import 'package:kernel/kernel.dart';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter_patcher_kernel_tools/src/interface_details.dart';
import 'package:flutter_patcher_kernel_tools/src/interface_document.dart';
import 'package:flutter_patcher_kernel_tools/src/extract_surface.dart';
import 'package:flutter_patcher_kernel_tools/src/interface_defaults.dart';
import 'package:flutter_patcher_kernel_tools/src/resolve_interface_hints.dart';

void check(bool value, String message) {
  if (!value) throw StateError(message);
}

void rejects(void Function() action, String label) {
  try {
    action();
  } catch (_) {
    return;
  }
  throw StateError('Expected failure: $label');
}

Library library(String name) =>
    Library(Uri.parse(name), fileUri: Uri.parse('file:///fixture.dart'));
Procedure method(
  String name, {
  ProcedureKind kind = ProcedureKind.Method,
  bool isStatic = false,
}) => Procedure(
  Name(name),
  kind,
  FunctionNode(EmptyStatement()),
  isStatic: isStatic,
  fileUri: Uri.parse('file:///fixture.dart'),
);

void main() {
  var cases = 0;
  void test(String name, void Function() body) {
    body();
    cases++;
    print('PASS $name');
  }

  test('detailed interface keeps final union and accumulated provenance', () {
    final c = Component(libraries: [library('package:app/main.dart')]);
    final a = InterfaceDocument()
      ..add('callable', 'package:app/main.dart', type: 'Widget');
    final b = InterfaceDocument()
      ..add('callable', 'package:app/main.dart', type: 'Widget');
    final first = describeInterface(c, a, {'referenced': a, 'protocol': b});
    final row = (first['entries'] as List).single as Map;
    check(
      jsonEncode(row['sources']) == '["protocol","referenced"]',
      'Union provenance',
    );
    check(row['location'] == null, 'Do not invent missing locations');
    final hint = InterfaceDocument()
      ..add('callable', 'package:app/main.dart', type: 'Extra');
    final result = InterfaceDocument()
      ..merge(a)
      ..merge(hint);
    final second = describeInterface(
      c,
      result,
      {'referenced': a, 'compiler-hint': hint},
      previous: Map<String, dynamic>.from(first),
      previousHash: sha256.convert(utf8.encode(a.encode())).toString(),
    );
    check((second['entries'] as List).length == 2, 'Final union cardinality');
    check(
      jsonEncode(second) ==
          jsonEncode(
            describeInterface(
              c,
              result,
              {'compiler-hint': hint, 'referenced': a},
              previous: Map<String, dynamic>.from(first),
              previousHash: sha256.convert(utf8.encode(a.encode())).toString(),
            ),
          ),
      'Determinism',
    );
    rejects(
      () => describeInterface(
        c,
        result,
        {'referenced': a},
        previous: Map<String, dynamic>.from(first),
        previousHash: 'wrong',
      ),
      'Previous hash',
    );
  });

  test(
    'canonical merge, list expansion, distinct member/class and constructor',
    () {
      final a = InterfaceDocument.parse(
        'callable:\n - library: "dart:core"\n   class: [int, num]\n',
      );
      final b = InterfaceDocument()
        ..add('callable', 'dart:core', type: 'num')
        ..add('callable', 'dart:core', type: 'int');
      check(a.encode() == b.encode(), 'Ordering/list normalization');
      a.merge(b);
      check(a.count('callable') == 2, 'Dedup');
      a.add('callable', 'dart:core', type: 'int', member: '');
      check(
        a.count('callable') == 3,
        'Unnamed constructor is not class-level access',
      );
    },
  );
  test('invalid YAML and unsafe dynamic Object declarations fail', () {
    rejects(
      () => InterfaceDocument.parse('callable: []\ncallable: []'),
      'duplicate section',
    );
    rejects(() => InterfaceDocument.parse('unknown: []'), 'unknown section');
    rejects(() => InterfaceDocument.parse('callable: [42]'), 'invalid row');
    rejects(
      () =>
          InterfaceDocument()
            ..add('dynamically-callable', 'dart:core', type: 'Object'),
      'Object',
    );
    rejects(
      () => InterfaceDocument()..add('dynamically-callable', 'dart:core'),
      'broad core',
    );
  });
  final host = library('package:host/impl.dart');
  final hostClass =
      Class(fileUri: Uri.parse('file:///fixture.dart'), name: 'Host')
        ..addProcedure(method('value', kind: ProcedureKind.Getter))
        ..addProcedure(method('work'));
  host.addClass(hostClass);
  final constant = IntConstant(7);
  for (final name in ['first', 'second', '_private']) {
    host.addField(
      Field.immutable(
        Name(name, host),
        isStatic: true,
        isConst: true,
        initializer: ConstantExpression(constant),
        fileUri: Uri.parse('file:///host.dart'),
      ),
    );
  }
  final own = library('package:own/main.dart');
  final ownClass = Class(
    fileUri: Uri.parse('file:///fixture.dart'),
    name: 'Child',
    supertype: Supertype(hostClass, []),
  )..addProcedure(method('work'));
  own.addClass(ownClass);
  final barrel = library('package:host/host.dart');
  barrel.additionalExports.add(hostClass.reference);
  own.addDependency(LibraryDependency.import(barrel));
  final entry = method('main', isStatic: true);
  entry.function.body = Block([
    ExpressionStatement(ConstantExpression(constant)),
    ExpressionStatement(StaticTearOff(hostClass.procedures.first)),
  ]);
  own.addProcedure(entry);
  final component = Component(libraries: [own, host, barrel]);
  test(
    'constants recover all public declarations; private fields excluded',
    () {
      final rows = extractSurface(component, {
        'own',
      }).interface.rows('callable');
      check(
        rows.any((r) => r['member'] == 'first') &&
            rows.any((r) => r['member'] == 'second'),
        'constant aliases',
      );
      check(!rows.any((r) => r['member'] == '_private'), 'private const');
      check(rows.any((r) => r['member'] == 'get:value'), 'getter key');
    },
  );
  test('inheritance/overrides and separate trim barrel entries', () {
    final result = extractSurface(component, {'own'});
    check(
      result.interface.rows('extendable').any((r) => r['class'] == 'Host'),
      'extendable',
    );
    check(
      result.interface
          .rows('can-be-overridden')
          .any((r) => r['member'] == 'work'),
      'override',
    );
    check(
      !result.interface
          .rows('callable')
          .any((r) => r['library'] == barrel.importUri.toString()),
      'narrow barrel',
    );
    check(
      result.trim
          .rows('callable')
          .any((r) => r['library'] == barrel.importUri.toString()),
      'trim barrel',
    );
    check(
      InterfaceDocument.parse(result.trim.encode()).encode() ==
          result.trim.encode(),
      'single callable key',
    );
    rejects(() => extractSurface(component, {'absent'}), 'wrong own package');
  });
  test('enum type also retained as callable class', () {
    final enumeration = Class(
      fileUri: Uri.parse('file:///fixture.dart'),
      name: 'Choice',
    )..isEnum = true;
    host.addClass(enumeration);
    entry.function.body = ExpressionStatement(
      ConstantExpression(
        TypeLiteralConstant(
          InterfaceType(enumeration, Nullability.nonNullable),
        ),
      ),
    );
    final doc = extractSurface(component, {'own'}).interface;
    check(
      doc
          .rows('callable')
          .any((r) => r['class'] == 'Choice' && !r.containsKey('member')),
      'enum callable',
    );
  });
  test(
    'hint resolution follows barrel exports and rejects unrelated names',
    () {
      final hidden = library('package:unrelated/hidden.dart')
        ..addClass(
          Class(fileUri: Uri.parse('file:///fixture.dart'), name: 'Host'),
        );
      component.libraries.add(hidden);
      final result = resolveInterfaceHints(component, {
        'own',
      }, "list class 'Host' as extendable");
      check(
        result.rows('extendable').single['library'] ==
            host.importUri.toString(),
        'only imported namespace',
      );
      own.addDependency(LibraryDependency.import(hidden));
      rejects(
        () => resolveInterfaceHints(component, {
          'own',
        }, "list class 'Host' as callable"),
        'ambiguity',
      );
      rejects(
        () => resolveInterfaceHints(component, {
          'own',
        }, "list class 'Unknown' as callable"),
        'unresolved',
      );
      rejects(
        () => resolveInterfaceHints(component, {'own'}, 'syntax error'),
        'not an interface error',
      );
      rejects(
        () => resolveInterfaceHints(component, {
          'own',
        }, "list class 'Host' as unsupported"),
        'unknown hint section',
      );
    },
  );
  test(
    'defaults include common controls/core and whole-mode dynamic allowlist',
    () {
      final core = library('dart:core');
      for (final name in ['num', 'int', 'double', 'Enum', 'Object']) {
        core.addClass(
          Class(fileUri: Uri.parse('file:///fixture.dart'), name: name),
        );
      }
      final libs = [core];
      for (final item in commonWidgets.entries) {
        final lib = library('package:flutter/src/${item.key}');
        for (final name in item.value) {
          lib.addClass(
            Class(fileUri: Uri.parse('file:///fixture.dart'), name: name),
          );
        }
        libs.add(lib);
      }
      final c = Component(libraries: libs);
      final lean = interfaceDefaults(c, whole: false);
      final whole = interfaceDefaults(c, whole: true);
      check(
        lean.rows('callable').any((r) => r['class'] == 'Container'),
        'common controls',
      );
      check(
        lean.rows('callable').any((r) => r['library'] == 'dart:core'),
        'core',
      );
      check(lean.count('dynamically-callable') == 0, 'lean dynamic scope');
      check(whole.count('dynamically-callable') == 4, 'whole dynamic scope');
      check(
        !whole.rows('dynamically-callable').any((r) => r['class'] == 'Object'),
        'no Object',
      );
    },
  );
  test('unimported dart:ffi Size cannot shadow exported dart:ui Size', () {
    final ui = library('dart:ui');
    final size = Class(name: 'Size', fileUri: Uri.parse('file:///ui.dart'));
    ui.addClass(size);
    final ffi = library('dart:ffi')
      ..addClass(Class(name: 'Size', fileUri: Uri.parse('file:///ffi.dart')));
    final exports = library('package:shapes/api.dart')
      ..additionalExports.add(size.reference);
    final user = library('package:app/main.dart')
      ..addDependency(LibraryDependency.import(exports));
    final doc = resolveInterfaceHints(
      Component(libraries: [user, exports, ui, ffi]),
      {'app'},
      "list class 'Size' as can-be-used-as-type",
    );
    check(
      doc.rows('can-be-used-as-type').single['library'] == 'dart:ui',
      'import boundary',
    );
  });
  test('exporting Matrix4 does not make vector_math Colors a candidate', () {
    final flutter = library('package:flutter/colors.dart');
    final colors =
        Class(name: 'Colors', fileUri: Uri.parse('file:///colors.dart'))
          ..addField(
            Field.immutable(
              Name('transparent'),
              isStatic: true,
              fileUri: Uri.parse('file:///colors.dart'),
            ),
          );
    flutter.addClass(colors);
    final vector = library('package:vector_math/vector_math_64.dart');
    final matrix = Class(
      name: 'Matrix4',
      fileUri: Uri.parse('file:///vector.dart'),
    );
    vector.addClass(matrix);
    vector.addClass(
      Class(name: 'Colors', fileUri: Uri.parse('file:///vector.dart'))
        ..addProcedure(
          method('transparent', kind: ProcedureKind.Getter, isStatic: true),
        ),
    );
    final barrel = library('package:flutter/material.dart')
      ..additionalExports.add(colors.reference)
      ..additionalExports.add(matrix.reference);
    final user = library('package:app/main.dart')
      ..addDependency(LibraryDependency.import(barrel));
    final doc = resolveInterfaceHints(
      Component(libraries: [user, barrel, flutter, vector]),
      {'app'},
      "list member 'Colors.transparent' as callable",
    );
    check(
      doc.rows('callable').single['library'] == 'package:flutter/colors.dart',
      'exported declarations only',
    );
  });
  print('$cases interface structural cases passed');
}
