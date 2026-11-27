import 'package:kernel/kernel.dart';
import 'package:flutter_patcher_kernel_tools/src/kernel_lists.dart';

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_patcher_kernel_tools/src/interface_rows.dart';
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
    supertype: Supertype(hostClass, kernelList(const <DartType>[])),
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
      final runtime = library(
        'package:flutter_patcher/src/patch_bootstrap.dart',
      );
      final ui = library('dart:ui');
      final draw = method('draw', isStatic: true);
      ui.addProcedure(draw);
      final boot = method('boot', isStatic: true);
      boot.function.body = ExpressionStatement(
        StaticInvocation(draw, Arguments(kernelList(<Expression>[]))),
      );
      runtime.addProcedure(boot);
      c.libraries.addAll([runtime, ui]);
      c.libraries.add(
        library('package:flutter/src/services/asset_bundle.dart')
          ..addClass(
            Class(
              name: 'AssetBundle',
              fileUri: Uri.parse('file:///asset.dart'),
            ),
          )
          ..addClass(
            Class(
              name: 'CachingAssetBundle',
              fileUri: Uri.parse('file:///asset.dart'),
            ),
          ),
      );
      final lean = interfaceDefaults(c, whole: false);
      final whole = interfaceDefaults(c, whole: true);
      check(
        lean
            .rows('callable')
            .any(
              (r) =>
                  r['class'] == 'CachingAssetBundle' &&
                  !r.containsKey('member'),
            ),
        'retain asset super constructor and inherited helpers',
      );
      check(
        lean
            .rows('callable')
            .any((r) => r['library'] == 'dart:ui' && r['member'] == 'draw'),
        'bootstrap dependencies retained before freezing host interface',
      );
      check(
        whole
            .rows('callable')
            .any((r) => r['library'] == 'dart:core' && r['class'] == 'num'),
        'platform classes explicitly retained for whole modules',
      );
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
  test('real-app shapes: mixin copies, private hosts, inherited, dynamic', () {
    final uri = Uri.parse('file:///fixture.dart');
    final lib = library('package:get/rx.dart');
    final object = Class(name: 'Object', fileUri: uri);
    final mixin = Class(name: 'RxObjectMixin', fileUri: uri)
      ..addProcedure(method('value', kind: ProcedureKind.Getter));
    final copy = method('value', kind: ProcedureKind.Getter);
    final application = Class(
      name: '_RxImpl&Object&RxObjectMixin',
      fileUri: uri,
      supertype: Supertype(object, kernelList(const <DartType>[])),
      implementedTypes: [Supertype(mixin, kernelList(const <DartType>[]))],
    )..addProcedure(copy);
    application.isEliminatedMixin = true;
    final map = Class(
      name: '_JsonMap',
      fileUri: uri,
      supertype: Supertype(object, kernelList(const <DartType>[])),
    )..addProcedure(method('[]', kind: ProcedureKind.Operator));
    final mock =
        Class(name: 'Mock', fileUri: uri, supertype: Supertype(object, kernelList(const <DartType>[])))
          ..addProcedure(method('[]', kind: ProcedureKind.Operator))
          ..addProcedure(method('noSuchMethod'));
    for (final c in [object, mixin, application, map, mock]) {
      lib.addClass(c);
    }
    check(
      identical(surfaceOrigin(copy), mixin.procedures.single),
      'mixin copy resolves to the mixin declaration',
    );
    final app = library('package:app/main.dart');
    final controller = Class(
      name: 'Controller',
      fileUri: uri,
      supertype: Supertype(application, kernelList(const <DartType>[])),
    );
    app.addClass(controller);
    final main = method('main', isStatic: true);
    main.function.body = ExpressionStatement(
      DynamicInvocation(
        DynamicAccessKind.Dynamic,
        NullLiteral(),
        Name('[]'),
        Arguments(kernelList(<Expression>[IntLiteral(0)])),
      ),
    );
    app.addProcedure(main);
    final doc = extractSurface(Component(libraries: [app, lib]), {
      'app',
    }).interface;
    bool has(String section, String type, String member) => doc
        .rows(section)
        .any((r) => r['class'] == type && r['member'] == member);
    check(
      has('callable', '_RxImpl&Object&RxObjectMixin', 'get:value') &&
          has('callable', 'RxObjectMixin', 'get:value'),
      'inherited host members callable, copy and origin',
    );
    check(has('dynamically-callable', '_JsonMap', '[]'), 'dynamic selector');
    check(!has('dynamically-callable', 'Mock', '[]'), 'noSuchMethod excluded');
  });
  test('a pinned package is listed whole; its privates only as callable', () {
    final uri = Uri.parse('file:///fixture.dart');
    Procedure named(String name, Library owner, {bool isStatic = false}) =>
        Procedure(
          Name(name, owner),
          ProcedureKind.Method,
          FunctionNode(EmptyStatement()),
          isStatic: isStatic,
          fileUri: uri,
        );
    final app = library('package:app/main.dart')
      ..addProcedure(named('main', library('package:app/x.dart'), isStatic: true));
    final pinned = library('package:plugin/plugin.dart');
    final free = library('package:free/free.dart');
    final foreign = library('package:plugin/other.dart');
    pinned
      ..addProcedure(named('_helper', pinned, isStatic: true))
      ..addProcedure(named('helper', pinned, isStatic: true))
      ..addClass(
        Class(name: 'Public', fileUri: uri)
          ..addProcedure(named('open', pinned))
          ..addProcedure(named('_hidden', pinned))
          // A private name of another library, as a mixin application copies
          // one: no row can name it.
          ..addProcedure(named('_copied', foreign)),
      )
      ..addClass(
        Class(name: '_Private', fileUri: uri)
          ..addProcedure(named('open', pinned)),
      );
    free.addClass(Class(name: 'Free', fileUri: uri));
    final doc = extractSurface(
      Component(libraries: [app, pinned, free]),
      {'app'},
      pinned: {'plugin', 'absent'},
    ).interface;
    const whole = [
      'callable',
      'extendable',
      'can-be-overridden',
      'can-be-used-as-type',
    ];
    for (final section in whole) {
      check(
        doc.rows(section).any(
          (r) => r.length == 1 && r['library'] == 'package:plugin/plugin.dart',
        ),
        'library row in $section',
      );
    }
    final named_ = [
      for (final section in InterfaceDocument.sections)
        for (final r in doc.rows(section))
          if (r.length > 1) '$section ${r['class'] ?? ''} ${r['member'] ?? ''}',
    ]..sort();
    check(
      jsonEncode(named_) ==
          jsonEncode([
            'callable  _helper',
            'callable Public _hidden',
            'callable _Private ',
            'callable _Private open',
          ]),
      'private rows: $named_',
    );
    check(
      !doc.rows('callable').any((r) => '${r['library']}'.contains('free')),
      'a free package is not listed',
    );
  });
  test('inherited private host members are callable where they resolve', () {
    // Issue #17: riverpod 3 generates provider subclasses in the app, and
    // riverpod's ProviderContainer calls their inherited _addListener.
    final uri = Uri.parse('file:///fixture.dart');
    final host = library('package:riverpod/src/framework.dart');
    final other = library('package:riverpod/src/other.dart');
    Procedure private(String name, Library owner) => Procedure(
      Name(name, owner),
      ProcedureKind.Method,
      FunctionNode(EmptyStatement()),
      fileUri: uri,
    );
    final object = Class(name: 'Object', fileUri: uri);
    final base = Class(
      name: r'$ProviderBaseImpl',
      fileUri: uri,
      supertype: Supertype(object, kernelList(const <DartType>[])),
    )
      ..addProcedure(private('_addListener', host))
      ..addProcedure(method('read'));
    // A private name of another library, as a mixin application copies it.
    final copy = Class(
      name: r'_Copy&Object&Mixin',
      fileUri: uri,
      supertype: Supertype(base, kernelList(const <DartType>[])),
    )..addProcedure(private('_foreign', host));
    host.addClass(object);
    host.addClass(base);
    other.addClass(copy);
    final app = library('package:app/main.g.dart');
    app.addClass(
      Class(
        name: 'GreetingProvider',
        fileUri: uri,
        supertype: Supertype(copy, kernelList(const <DartType>[])),
      )..addProcedure(private('_own', app)),
    );
    final doc = extractSurface(
      Component(libraries: [app, host, other]),
      {'app'},
    ).interface;
    bool has(String type, String member) => doc
        .rows('callable')
        .any((r) => r['class'] == type && r['member'] == member);
    check(has(r'$ProviderBaseImpl', '_addListener'), 'own-library private');
    check(has(r'$ProviderBaseImpl', 'read'), 'public inherited');
    check(!has(r'_Copy&Object&Mixin', '_foreign'), 'foreign private name');
    check(!doc.rows('callable').any((r) => r['member'] == '_own'), 'own code');
    check(
      indexableMember(base.procedures.first) &&
          !indexableMember(copy.procedures.single),
      'indexableMember',
    );
  });
  test('scanned packages are walked but stay host targets', () {
    final uri = Uri.parse('file:///fixture.dart');
    final hostLib = library('package:flutter/widgets.dart');
    final hostMember = method('build', isStatic: true);
    hostLib.addProcedure(hostMember);
    final freeLib = library('package:get/get.dart');
    final freeMember = method('find', isStatic: true);
    freeMember.function.body = ExpressionStatement(
      StaticInvocation(hostMember, Arguments(kernelList(<Expression>[]))),
    );
    freeLib.addProcedure(freeMember);
    final appLib = library('package:app/main.dart');
    final main = method('main', isStatic: true);
    main.function.body = ExpressionStatement(
      StaticInvocation(freeMember, Arguments(kernelList(<Expression>[]))),
    );
    appLib.addProcedure(main);
    final c = Component(libraries: [appLib, freeLib, hostLib]);
    final rows = extractSurface(c, {'app'}, scan: {'get'})
        .interface
        .rows('callable');
    check(
      rows.any((r) => r['library'] == 'package:get/get.dart'),
      'lean patches call the host copy of a free package',
    );
    check(
      rows.any((r) => r['library'] == 'package:flutter/widgets.dart'),
      'whole patches carry the free package, whose calls are covered',
    );
    check(uri.scheme == 'file', 'fixture');
  });
  test('a member name several members share is listed by its class', () {
    final uri = Uri.parse('file:///fixture.dart');
    const button = 'package:flutter/src/cupertino/button.dart';
    final lib = library(button);
    // A named constructor and a field of one name (issue #14's
    // CupertinoDesktopTextSelectionToolbarButton.text).
    final shadowed = Class(name: 'ToolbarButton', fileUri: uri)
      ..addConstructor(
        Constructor(
          FunctionNode(EmptyStatement()),
          name: Name('text'),
          fileUri: uri,
        ),
      )
      ..addField(Field.immutable(Name('text'), fileUri: uri))
      ..addProcedure(method('onPressed', kind: ProcedureKind.Getter));
    // A factory, a procedure in Kernel, and a field of one name: the SDK
    // would resolve the factory's row to the field without an error.
    final factory = Class(name: 'Shape', fileUri: uri)
      ..addProcedure(
        method('circle', kind: ProcedureKind.Factory, isStatic: true),
      )
      ..addField(Field.immutable(Name('circle'), fileUri: uri))
      ..addProcedure(method('area', kind: ProcedureKind.Getter))
      ..addProcedure(method('area', kind: ProcedureKind.Setter));
    final plain = Class(name: 'Label', fileUri: uri)
      ..addField(Field.immutable(Name('text'), fileUri: uri));
    lib
      ..addClass(shadowed)
      ..addClass(factory)
      ..addClass(plain);
    final doc = InterfaceDocument()
      ..add(
        'dynamically-callable',
        button,
        type: 'ToolbarButton',
        member: 'text',
      )
      ..add('callable', button, type: 'ToolbarButton', member: 'get:onPressed')
      ..add('callable', button, type: 'Shape', member: 'circle')
      ..add('callable', button, type: 'Shape', member: 'get:area')
      ..add('callable', button, type: 'Shape', member: 'set:area')
      ..add('dynamically-callable', button, type: 'Label', member: 'text');
    final conformed = conformRows(Component(libraries: [lib]), doc);
    bool has(String section, String type, String? member) => conformed
        .rows(section)
        .any((r) => r['class'] == type && r['member'] == member);
    check(
      has('dynamically-callable', 'ToolbarButton', null),
      'a field a constructor shadows is widened to its class',
    );
    check(
      !has('dynamically-callable', 'ToolbarButton', 'text'),
      'no row resolving to the constructor',
    );
    check(
      has('callable', 'Shape', null) && !has('callable', 'Shape', 'circle'),
      'a factory a field shadows is widened to its class',
    );
    check(
      has('callable', 'ToolbarButton', 'get:onPressed') &&
          has('callable', 'Shape', 'get:area') &&
          has('callable', 'Shape', 'set:area'),
      'a getter and a setter of one name are two names',
    );
    check(
      has('dynamically-callable', 'Label', 'text'),
      'a name one member has is kept',
    );
    final f = factory.procedures.first, g = factory.procedures[1];
    check(
      memberName(f) == 'circle' &&
          memberName(g) == 'get:area' &&
          memberName(factory.procedures[2]) == 'set:area' &&
          memberName(factory.fields.single) == 'circle' &&
          memberName(shadowed.constructors.single) == 'text',
      'memberName is the name LibraryIndex resolves',
    );
  });
  print('$cases interface structural cases passed');
}
