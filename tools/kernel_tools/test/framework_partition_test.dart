import 'dart:convert';

import 'package:kernel/kernel.dart';
import 'package:flutter_patcher_kernel_tools/src/framework_partition.dart';

void check(bool value, String message) {
  if (!value) throw StateError(message);
}

final _file = Uri.parse('file:///fixture.dart');

Library library(String uri) => Library(Uri.parse(uri), fileUri: _file);

Procedure method(
  String name, {
  ProcedureKind kind = ProcedureKind.Method,
  bool isStatic = false,
  Statement? body,
}) => Procedure(
  Name(name),
  kind,
  FunctionNode(body ?? EmptyStatement()),
  isStatic: isStatic,
  fileUri: _file,
);

bool hasRow(
  List rows,
  String section,
  String library, {
  String? type,
  String? member,
}) => rows.any(
  (row) =>
      row['section'] == section &&
      row['library'] == library &&
      row['class'] == type &&
      row['member'] == member,
);

void main() {
  var cases = 0;
  void test(String name, void Function() body) {
    body();
    cases++;
    print('PASS $name');
  }

  const hostUri = 'package:flutter/src/material/theme.dart';
  const carryUri = 'package:flutter/src/material/expansion_tile.dart';

  /// Synthetic framework: `theme.dart` is referenced from the signature of
  /// `expansion_tile.dart`, so it must be host; `expansion_tile.dart` has no
  /// incoming signature edge and is carriable. The carried body invokes host
  /// members of every kind the collector must classify.
  Component fixture() {
    final core = library('dart:core');
    final object = Class(name: 'Object', fileUri: _file)
      ..addProcedure(method('noSuchMethod'));
    core.addClass(object);

    final host = library(hostUri);
    final theme = Class(
      name: 'Theme',
      supertype: Supertype(object, const []),
      fileUri: _file,
    );
    final color = method('color', kind: ProcedureKind.Getter);
    final of = method('of', isStatic: true);
    theme
      ..addProcedure(color)
      ..addProcedure(of);
    final affinity = Class(
      name: 'Affinity',
      supertype: Supertype(object, const []),
      fileUri: _file,
    )..isEnum = true;
    final leading = Field.immutable(
      Name('leading'),
      isStatic: true,
      isConst: true,
      fileUri: _file,
    );
    affinity.addField(leading);
    final weird = Class(
      name: 'Weird',
      supertype: Supertype(object, const []),
      fileUri: _file,
    );
    final foo = method('foo');
    weird
      ..addProcedure(method('noSuchMethod'))
      ..addProcedure(foo);
    host
      ..addClass(theme)
      ..addClass(affinity)
      ..addClass(weird);

    final carry = library(carryUri);
    final tile = Class(
      name: 'ExpansionTile',
      supertype: Supertype(object, const []),
      fileUri: _file,
    );
    tile.addField(
      Field.immutable(
        Name('theme'),
        type: InterfaceType(theme, Nullability.nonNullable),
        fileUri: _file,
      ),
    );
    tile.addProcedure(
      method(
        'build',
        body: Block([
          ExpressionStatement(
            InstanceGet(
              InstanceAccessKind.Instance,
              NullLiteral(),
              Name('color'),
              interfaceTarget: color,
              resultType: const DynamicType(),
            ),
          ),
          ExpressionStatement(StaticInvocation(of, Arguments([]))),
          ExpressionStatement(StaticGet(leading)),
          ExpressionStatement(
            InstanceInvocation(
              InstanceAccessKind.Instance,
              NullLiteral(),
              Name('foo'),
              Arguments([]),
              interfaceTarget: foo,
              functionType: FunctionType(
                const [],
                const DynamicType(),
                Nullability.nonNullable,
              ),
            ),
          ),
        ]),
      ),
    );
    carry.addClass(tile);

    final barrel = library('package:flutter/material.dart');
    return Component(libraries: [core, host, carry, barrel]);
  }

  test('signature edges decide host/carry and barrels stay host', () {
    final result = partitionFrameworkComponent(fixture());
    check(
      jsonEncode(result['host']) ==
          jsonEncode(['package:flutter/material.dart', hostUri]),
      'host libraries',
    );
    check(jsonEncode(result['carry']) == jsonEncode([carryUri]), 'carry');
    final rows = (result['libraries'] as List).cast<Map>();
    final tile = rows.singleWhere((r) => r['uri'] == carryUri);
    check(
      jsonEncode(tile['signature_dependencies']) == jsonEncode([hostUri]),
      'carry signature dependency recorded',
    );
    check(
      rows.singleWhere(
            (r) => r['uri'] == hostUri,
          )['incoming_signature_edges'] ==
          1,
      'host incoming edge count',
    );
  });

  test('instance and static members referenced by carry code are callable', () {
    final reuse =
        partitionFrameworkComponent(fixture())['reuse_surface'] as List;
    check(
      hasRow(reuse, 'callable', hostUri, type: 'Theme', member: 'get:color'),
      'statically typed instance getter is callable, not dynamically-callable',
    );
    check(
      !reuse.any((row) => row['section'] == 'dynamically-callable'),
      'no dynamically-callable rows: carried code has no dynamic receivers',
    );
    check(
      hasRow(reuse, 'callable', hostUri, type: 'Theme', member: 'of'),
      'static member is callable',
    );
    check(
      hasRow(reuse, 'can-be-used-as-type', hostUri, type: 'Theme'),
      'referenced class is usable as a type',
    );
  });

  test('enum values become class-level callable entries', () {
    final reuse =
        partitionFrameworkComponent(fixture())['reuse_surface'] as List;
    check(
      hasRow(reuse, 'callable', hostUri, type: 'Affinity', member: 'leading'),
      'enum constant callable',
    );
    check(
      hasRow(reuse, 'can-be-used-as-type', hostUri, type: 'Affinity'),
      'enum type',
    );
  });

  test(
    'noSuchMethod overrides do not block statically typed callable rows',
    () {
      final reuse =
          partitionFrameworkComponent(fixture())['reuse_surface'] as List;
      check(
        hasRow(reuse, 'callable', hostUri, type: 'Weird', member: 'foo'),
        'callable has no noSuchMethod hierarchy restriction',
      );
    },
  );

  test('partition output is deterministic', () {
    final a = jsonEncode(partitionFrameworkComponent(fixture()));
    final b = jsonEncode(partitionFrameworkComponent(fixture()));
    check(a == b, 'same input, same bytes');
  });

  test('a component without package:flutter is rejected', () {
    var rejected = false;
    try {
      partitionFrameworkComponent(
        Component(libraries: [library('package:app/main.dart')]),
      );
    } on FormatException {
      rejected = true;
    }
    check(rejected, 'no framework libraries');
  });

  print('$cases framework partition cases passed');
}
