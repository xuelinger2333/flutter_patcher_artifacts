import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:kernel/kernel.dart';

/// Framework partition metadata generator.
///
/// The partition is deliberately library-granular. A framework library is
/// considered host-provided when a public signature in another Flutter
/// library refers to one of its declarations. Libraries with no incoming
/// signature edge are carry candidates; barrels remain host-provided because
/// they only describe the package surface.
Future<Map<String, Object?>> generateFrameworkPartition(
  List<String> args,
) async {
  final options = <String, String>{};
  const allowed = {'--platform', '--dill', '--out', '--flutter-version'};
  for (var i = 0; i < args.length; i += 2) {
    if (i + 1 >= args.length ||
        !allowed.contains(args[i]) ||
        options.containsKey(args[i]) ||
        args[i + 1].startsWith('--')) {
      throw const FormatException('Invalid gen-framework-partition options');
    }
    options[args[i]] = args[i + 1];
  }
  String required(String key) {
    final value = options[key];
    if (value == null || value.isEmpty) throw FormatException('Missing $key');
    return value;
  }

  final dill = File(required('--dill')).absolute;
  final platform = File(required('--platform')).absolute;
  if (!await dill.exists() || !await platform.exists()) {
    throw const FormatException('Partition inputs do not exist');
  }
  final partition = partitionFrameworkComponent(
    loadComponentFromBinary(dill.path),
  );
  final data = <String, Object?>{
    'schema': 1,
    if (options['--flutter-version'] != null)
      'flutter_version': options['--flutter-version'],
    'platform_sha256': sha256.convert(await platform.readAsBytes()).toString(),
    'source_dill_sha256': sha256.convert(await dill.readAsBytes()).toString(),
    ...partition,
  };
  final output = File(required('--out')).absolute;
  await output.parent.create(recursive: true);
  await output.writeAsString(
    '${const JsonEncoder.withIndent('  ').convert(data)}\n',
    flush: true,
  );
  return {
    'schema': 1,
    'host_libraries': (partition['host'] as List).length,
    'carry_libraries': (partition['carry'] as List).length,
    'reuse_surface': (partition['reuse_surface'] as List).length,
    'platform_sha256': data['platform_sha256'],
  };
}

/// Pure partition of the `package:flutter` libraries in [component].
///
/// Returns `host`, `carry`, `reuse_surface` and per-library `libraries` rows
/// in deterministic order. Kept separate from file handling so the split can
/// be tested on synthetic Kernel without a linked Flutter dill.
Map<String, Object?> partitionFrameworkComponent(Component component) {
  final flutter = component.libraries.where((library) {
    final uri = library.importUri;
    return uri.scheme == 'package' &&
        uri.pathSegments.isNotEmpty &&
        uri.pathSegments.first == 'flutter';
  }).toList()..sort((a, b) => '${a.importUri}'.compareTo('${b.importUri}'));
  if (flutter.isEmpty)
    throw const FormatException('No package:flutter libraries in dill');

  final byLibrary = <String, Library>{
    for (final library in flutter) '${library.importUri}': library,
  };
  final edges = <String, Set<String>>{
    for (final uri in byLibrary.keys) uri: <String>{},
  };

  void collectType(DartType? type, String owner) {
    if (type == null) return;
    final visitor = _FrameworkTypeVisitor((library) {
      final uri = '${library.importUri}';
      if (uri != owner && byLibrary.containsKey(uri)) edges[owner]!.add(uri);
    });
    type.accept(visitor);
  }

  void collectFunction(FunctionNode function, String owner) {
    collectType(function.returnType, owner);
    for (final parameter in function.positionalParameters) {
      collectType(parameter.type, owner);
    }
    for (final parameter in function.namedParameters) {
      collectType(parameter.type, owner);
    }
    for (final parameter in function.typeParameters) {
      collectType(parameter.bound, owner);
    }
  }

  bool public(String name) => !name.startsWith('_');
  for (final library in flutter) {
    final owner = '${library.importUri}';
    for (final field in library.fields.where((f) => public(f.name.text))) {
      collectType(field.type, owner);
    }
    for (final procedure in library.procedures.where(
      (p) => public(p.name.text),
    )) {
      collectFunction(procedure.function, owner);
    }
    for (final clazz in library.classes.where((c) => public(c.name))) {
      collectType(clazz.supertype?.asInterfaceType, owner);
      collectType(clazz.mixedInType?.asInterfaceType, owner);
      for (final parameter in clazz.typeParameters)
        collectType(parameter.bound, owner);
      for (final field in clazz.fields.where((f) => public(f.name.text))) {
        collectType(field.type, owner);
      }
      for (final procedure in clazz.procedures.where(
        (p) => public(p.name.text),
      )) {
        collectFunction(procedure.function, owner);
      }
      for (final constructor in clazz.constructors.where(
        (c) => public(c.name.text),
      )) {
        collectFunction(constructor.function, owner);
      }
    }
  }

  final incoming = <String, int>{for (final uri in byLibrary.keys) uri: 0};
  for (final targets in edges.values) {
    for (final target in targets) incoming[target] = incoming[target]! + 1;
  }
  final host = <String>[];
  final carry = <String>[];
  final rows = <Map<String, Object?>>[];
  for (final library in flutter) {
    final uri = '${library.importUri}';
    final declarations = <String>[
      ...library.classes
          .where((c) => public(c.name))
          .map((c) => 'class:${c.name}'),
      ...library.procedures
          .where((p) => public(p.name.text))
          .map((p) => 'procedure:${p.name.text}'),
      ...library.fields
          .where((f) => public(f.name.text))
          .map((f) => 'field:${f.name.text}'),
    ]..sort();
    final isBarrel = declarations.isEmpty;
    final isHost = isBarrel || incoming[uri]! > 0;
    (isHost ? host : carry).add(uri);
    rows.add({
      'uri': uri,
      'role': isHost ? 'host' : 'carry',
      'incoming_signature_edges': incoming[uri],
      'declarations_sha256': sha256
          .convert(utf8.encode(declarations.join('\n')))
          .toString(),
      'declarations': declarations,
      'signature_dependencies': (edges[uri]!.toList()..sort()),
    });
  }
  host.sort();
  carry.sort();

  // R is the host declaration surface actually used by carried code.  The
  // public signatures above are not enough: a carried library may invoke a
  // host method from its body. Walk only carried libraries and retain the
  // canonical Kernel targets, rather than exposing every host member.
  final reuse = <Map<String, String>>[];
  final collector = _FrameworkReuseCollector(host.toSet(), reuse);
  for (final library in flutter) {
    if (carry.contains('${library.importUri}')) library.accept(collector);
  }
  final uniqueReuse = <String, Map<String, String>>{
    for (final row in reuse) jsonEncode(row): row,
  };
  reuse
    ..clear()
    ..addAll(uniqueReuse.values);
  reuse.sort((a, b) => jsonEncode(a).compareTo(jsonEncode(b)));
  return {
    'host': host,
    'carry': carry,
    'reuse_surface': reuse,
    'libraries': rows,
  };
}

class _FrameworkTypeVisitor extends RecursiveVisitor {
  final void Function(Library) onLibrary;
  _FrameworkTypeVisitor(this.onLibrary);
  @override
  void visitInterfaceType(InterfaceType node) {
    onLibrary(node.classNode.enclosingLibrary);
    super.visitInterfaceType(node);
  }
}

/// Collects only declarations whose canonical Kernel nodes are referenced by
/// a carried library.  `dynamically-callable` intentionally receives instance
/// members only; static members and constructors belong to `callable`.
class _FrameworkReuseCollector extends RecursiveVisitor {
  final Set<String> hostUris;
  final List<Map<String, String>> rows;
  _FrameworkReuseCollector(this.hostUris, this.rows);

  bool _public(Member member) {
    final library = member.enclosingLibrary;
    final clazz = member.enclosingClass;
    return hostUris.contains('${library.importUri}') &&
        publicName(member.name.text) &&
        (clazz == null || publicName(clazz.name));
  }

  void addType(Class? clazz) {
    if (clazz == null ||
        !hostUris.contains('${clazz.enclosingLibrary.importUri}'))
      return;
    if (!publicName(clazz.name)) return;
    rows.add({
      'library': '${clazz.enclosingLibrary.importUri}',
      'section': 'can-be-used-as-type',
      'class': clazz.name,
    });
    // Enum values are represented as static fields in Kernel.  Carry code
    // commonly switches on those values, so expose the class-level callable
    // surface as well as the type itself.
    if (clazz.isEnum) {
      for (final field in clazz.fields.where(
        (f) => f.isStatic && f.isConst && publicName(f.name.text),
      )) {
        rows.add({
          'library': '${field.enclosingLibrary.importUri}',
          'section': 'callable',
          'class': clazz.name,
          'member': field.name.text,
        });
      }
    }
  }

  void addMember(Member? member) {
    if (member == null || !_public(member)) return;
    final clazz = member.enclosingClass;
    final key = member is Procedure
        ? (member.isGetter
              ? 'get:${member.name.text}'
              : member.isSetter
              ? 'set:${member.name.text}'
              : member.name.text)
        : member.name.text;
    // The VM rejects exposing a class that declares or inherits
    // noSuchMethod as dynamically-callable.  Such a class cannot safely be
    // part of the reusable host surface; the compiler will report it as a
    // normal non-carriable dependency when a patch actually needs it.
    if (member.isInstanceMember && clazz != null && _hasNoSuchMethod(clazz)) {
      return;
    }
    rows.add({
      'library': '${member.enclosingLibrary.importUri}',
      'section': member.isInstanceMember ? 'dynamically-callable' : 'callable',
      if (clazz != null) 'class': clazz.name,
      'member': key,
    });
    addType(clazz);
  }

  static bool _isCoreObject(Class clazz) =>
      clazz.name == 'Object' &&
      '${clazz.enclosingLibrary.importUri}' == 'dart:core';

  bool _hasNoSuchMethod(Class clazz, [Set<Class>? seen]) {
    final visited = seen ?? <Class>{};
    if (!visited.add(clazz)) return false;
    // Object.noSuchMethod is inherited by every Dart class and does not
    // make the VM reject a dynamic interface entry. Only an explicit
    // override in a non-Object class makes dynamic dispatch unsafe.
    if (!_isCoreObject(clazz) &&
        clazz.members.any((m) => m.name.text == 'noSuchMethod'))
      return true;
    for (final sup in clazz.supers) {
      if (_hasNoSuchMethod(sup.classNode, visited)) return true;
    }
    return false;
  }

  @override
  void visitInterfaceType(InterfaceType node) {
    addType(node.classNode);
    super.visitInterfaceType(node);
  }

  @override
  void visitInstanceInvocation(InstanceInvocation node) {
    addMember(node.interfaceTarget);
    super.visitInstanceInvocation(node);
  }

  @override
  void visitInstanceGet(InstanceGet node) {
    addMember(node.interfaceTarget);
    super.visitInstanceGet(node);
  }

  @override
  void visitInstanceSet(InstanceSet node) {
    addMember(node.interfaceTarget);
    super.visitInstanceSet(node);
  }

  @override
  void visitInstanceTearOff(InstanceTearOff node) {
    addMember(node.interfaceTarget);
    super.visitInstanceTearOff(node);
  }

  @override
  void visitEqualsCall(EqualsCall node) {
    addMember(node.interfaceTarget);
    super.visitEqualsCall(node);
  }

  @override
  void visitStaticInvocation(StaticInvocation node) {
    addMember(node.target);
    super.visitStaticInvocation(node);
  }

  @override
  void visitStaticGet(StaticGet node) {
    addMember(node.target);
    super.visitStaticGet(node);
  }

  @override
  void visitStaticSet(StaticSet node) {
    addMember(node.target);
    super.visitStaticSet(node);
  }

  @override
  void visitStaticTearOff(StaticTearOff node) {
    addMember(node.target);
    super.visitStaticTearOff(node);
  }

  @override
  void visitConstructorInvocation(ConstructorInvocation node) {
    addMember(node.target);
    addType(node.target.enclosingClass);
    super.visitConstructorInvocation(node);
  }

  @override
  void visitSuperMethodInvocation(SuperMethodInvocation node) {
    addMember(node.interfaceTarget);
    super.visitSuperMethodInvocation(node);
  }

  @override
  void visitSuperPropertyGet(SuperPropertyGet node) {
    addMember(node.interfaceTarget);
    super.visitSuperPropertyGet(node);
  }

  @override
  void visitSuperPropertySet(SuperPropertySet node) {
    addMember(node.interfaceTarget);
    super.visitSuperPropertySet(node);
  }

  @override
  void visitConstantExpression(ConstantExpression node) {
    _visitConstant(node.constant, <Constant>{});
    super.visitConstantExpression(node);
  }

  void _visitConstant(Constant constant, Set<Constant> seen) {
    if (!seen.add(constant)) return;
    if (constant is InstanceConstant) {
      addType(constant.classNode);
      for (final entry in constant.fieldValues.entries) {
        addMember(entry.key.asField);
        _visitConstant(entry.value, seen);
      }
    } else if (constant is StaticTearOffConstant) {
      addMember(constant.target);
    } else if (constant is TypeLiteralConstant) {
      constant.type.accept(this);
    } else if (constant is ListConstant) {
      for (final value in constant.entries) _visitConstant(value, seen);
    } else if (constant is SetConstant) {
      for (final value in constant.entries) _visitConstant(value, seen);
    } else if (constant is MapConstant) {
      for (final entry in constant.entries) {
        _visitConstant(entry.key, seen);
        _visitConstant(entry.value, seen);
      }
    } else if (constant is InstantiationConstant) {
      _visitConstant(constant.tearOffConstant, seen);
    }
  }
}

bool publicName(String name) => !name.startsWith('_');
