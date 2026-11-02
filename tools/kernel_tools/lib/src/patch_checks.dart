import 'dart:convert';
import 'package:kernel/kernel.dart';
import 'package:kernel/class_hierarchy.dart';
import 'package:kernel/core_types.dart';
import 'package:front_end/src/kernel/dynamic_module_validator.dart';

import 'extract_surface.dart' show surfaceOrigin;

Map<String, Object?> site(TreeNode node, String code, String message) {
  final loc = node.location;
  return {
    'code': code,
    'message': message,
    'file': loc?.file.toString(),
    'line': loc?.line,
    'column': loc?.column,
    'col': loc?.column,
  };
}

/// FFI call sites a module must not contain: in an AOT runtime the VM cannot
/// make an FFI call from interpreted code (its FfiCall runtime entry is
/// UNREACHABLE), so the app would abort. Host code may still make them, and a
/// module may call that host code. Names cover both the public API and the
/// forms the VM's FFI transformations lower it to; extension members are
/// matched after their `Extension|` prefix.
const _ffiCallSites = {
  'asFunction',
  'lookupFunction',
  'fromFunction',
  'listener',
  'isolateLocal',
  '_asFunctionInternal',
  '_ffiCall',
  '_pointerFromFunction',
  '_nativeCallbackFunction',
  '_nativeAsyncCallbackFunction',
  '_nativeIsolateLocalCallbackFunction',
  '_createNativeCallableListener',
  '_createNativeCallableIsolateLocal',
};

bool _isFfiCallSite(Member target) =>
    target.enclosingLibrary.importUri.toString() == 'dart:ffi' &&
    _ffiCallSites.contains(target.name.text.split('|').last);

bool _isNativeBinding(Member member) => member.annotations.any((a) {
  if (a is! ConstantExpression || a.constant is! InstanceConstant) return false;
  final c = a.constant as InstanceConstant;
  final library = c.classNode.enclosingLibrary.importUri.toString();
  if (library == 'dart:ffi') return c.classNode.name == 'Native';
  return library == 'dart:core' &&
      c.classNode.name == 'pragma' &&
      c.fieldValues.values.any(
        (v) => v is StringConstant && v.value == 'vm:ffi:native',
      );
});

/// Rejects native bindings and FFI calls in module code.
class FfiCheck extends RecursiveVisitor {
  final List<Map<String, Object?>> issues = [];

  void _report(TreeNode at, String what) => issues.add(
    site(
      at,
      'PATCH_FFI_CALL',
      '$what: FFI must stay in host code, which a patch may call; a new '
          'native binding requires a new host release',
    ),
  );

  @override
  void defaultMember(Member node) {
    if (_isNativeBinding(node))
      _report(node, 'Native binding ${node.name.text}');
    super.defaultMember(node);
  }

  @override
  void visitStaticInvocation(StaticInvocation node) {
    if (_isFfiCallSite(node.target))
      _report(node, 'FFI call ${node.target.name.text}');
    super.visitStaticInvocation(node);
  }

  @override
  void visitStaticTearOff(StaticTearOff node) {
    if (_isFfiCallSite(node.target))
      _report(node, 'FFI call ${node.target.name.text}');
    super.visitStaticTearOff(node);
  }

  @override
  void visitConstructorInvocation(ConstructorInvocation node) {
    if (_isFfiCallSite(node.target))
      _report(node, 'FFI call ${node.target.name.text}');
    super.visitConstructorInvocation(node);
  }

  @override
  void visitInstanceInvocation(InstanceInvocation node) {
    if (_isFfiCallSite(node.interfaceTarget)) {
      _report(node, 'FFI call ${node.interfaceTarget.name.text}');
    }
    super.visitInstanceInvocation(node);
  }
}

/// The patched VM checks generative constructor references, not factories.
class AllocationCheck extends RecursiveVisitor {
  final Set<Library> host;
  final Set<String> allocated;
  final List<Map<String, Object?>> issues = [];
  final List<Map<String, Object?>> fonts = [];
  final List<Map<String, Object?>> dynamicFonts = [];
  AllocationCheck(this.host, this.allocated);
  void reference(Class cls, TreeNode at, String kind) {
    final key = '${cls.enclosingLibrary.importUri}::${cls.name}';
    if (host.contains(cls.enclosingLibrary) && !allocated.contains(key)) {
      TreeNode? context = at;
      while (context != null && context is! Member) context = context.parent;
      issues.add({
        ...site(at, 'HOST_NOT_ALLOCATED', '$key ($kind)'),
        'class': cls.name,
        'library': cls.enclosingLibrary.importUri.toString(),
        'member': context is Member ? context.name.text : null,
        'kind': kind,
      });
    }
  }

  @override
  void visitConstructorInvocation(ConstructorInvocation n) {
    if (n.target.enclosingClass.name == 'IconData' &&
        n.target.enclosingClass.enclosingLibrary.importUri.toString() ==
            'package:flutter/src/widgets/icon_data.dart') {
      dynamicFonts.add(
        site(
          n,
          'PATCH_DYNAMIC_ICON',
          'Non-constant IconData cannot be subset safely',
        ),
      );
    }
    reference(n.target.enclosingClass, n, 'new');
    super.visitConstructorInvocation(n);
  }

  @override
  void visitSuperInitializer(SuperInitializer n) {
    reference(n.target.enclosingClass, n, 'super');
    super.visitSuperInitializer(n);
  }

  @override
  void visitRedirectingInitializer(RedirectingInitializer n) {
    reference(n.target.enclosingClass, n, 'redirect');
    super.visitRedirectingInitializer(n);
  }

  @override
  void visitConstructorTearOff(ConstructorTearOff n) {
    if (n.target is Constructor)
      reference((n.target as Constructor).enclosingClass, n, 'tear-off');
    super.visitConstructorTearOff(n);
  }

  @override
  void visitConstantExpression(ConstantExpression n) {
    void walk(Constant c, Set<Constant> seen) {
      if (!seen.add(c)) return;
      if (c is InstanceConstant) reference(c.classNode, n, 'constant');
      if (c is InstanceConstant &&
          c.classNode.name == 'IconData' &&
          c.classNode.enclosingLibrary.importUri.toString() ==
              'package:flutter/src/widgets/icon_data.dart') {
        fonts.add({
          ...site(
            n,
            'PATCH_FONT_REQUIRED',
            'IconData requires complete font subsetting',
          ),
          for (final field in c.fieldValues.entries)
            if ([
              'codePoint',
              'fontFamily',
              'fontPackage',
              'fontFamilyFallback',
              'matchTextDirection',
            ].contains(field.key.asField.name.text))
              field.key.asField.name.text: switch (field.value) {
                IntConstant v => v.value,
                StringConstant v => v.value,
                BoolConstant v => v.value,
                NullConstant _ => null,
                ListConstant v => [
                  for (final entry in v.entries)
                    (entry as StringConstant).value,
                ],
                _ => throw StateError('Unexpected IconData field'),
              },
        });
      }
      if (c is ConstructorTearOffConstant && c.target is Constructor)
        reference(c.target.enclosingClass!, n, 'constant tear-off');
      final children = <Constant>[
        if (c is InstanceConstant) ...c.fieldValues.values,
        if (c is ListConstant) ...c.entries,
        if (c is SetConstant) ...c.entries,
        if (c is MapConstant) ...c.entries.expand((e) => [e.key, e.value]),
        if (c is RecordConstant) ...[...c.positional, ...c.named.values],
        if (c is InstantiationConstant) c.tearOffConstant,
      ];
      for (final child in children) {
        walk(child, seen);
      }
    }

    walk(n.constant, Set<Constant>.identity());
    super.visitConstantExpression(n);
  }
}

List<Map<String, Object?>> inheritedCheck(
  Component component,
  ClassHierarchy hierarchy,
  Set<Library> host,
  Iterable<Library> module,
  String interfaceYaml,
  String compilerInterface,
) {
  final spec = DynamicInterfaceSpecification(
    interfaceYaml,
    Uri.base,
    component,
  );
  final expanded = (jsonDecode(compilerInterface) as Map)['callable'] as List;
  bool recorded(Member m) => expanded.any(
    (r) =>
        r['library'] == '${m.enclosingLibrary.importUri}' &&
        r['class'] == m.enclosingClass?.name &&
        r['member'] == m.name.text,
  );
  bool exposed(Member m) =>
      spec.callable.contains(m) ||
      (!m.name.isPrivate &&
          (spec.callable.contains(m.enclosingClass) ||
              spec.callable.contains(m.enclosingLibrary)));
  final issues = <Map<String, Object?>>[];
  for (final library in module) {
    for (final cls in library.classes) {
      for (final setter in [false, true]) {
        for (final member in hierarchy.getDispatchTargets(
          cls,
          setters: setter,
        )) {
          // A member copied into a (private) eliminated mixin application is
          // listed by the host compiler under the mixin's own declaration.
          final origin = surfaceOrigin(member);
          if (!member.name.isPrivate &&
              host.contains(member.enclosingLibrary) &&
              (!(exposed(member) || exposed(origin)) ||
                  !(recorded(member) || recorded(origin)))) {
            issues.add(
              site(
                cls,
                'HOST_INHERITED_MEMBER_MISSING',
                '${member.enclosingLibrary.importUri}::${member.enclosingClass?.name}.${member.name.text}${setter ? "=" : ""}',
              ),
            );
          }
        }
      }
    }
  }
  return issues;
}

/// The names of the `@pragma`s on [node].
Set<String> pragmaNames(Annotatable node) {
  final pragmas = <String>{};
  for (final a in node.annotations) {
    if (a is ConstantExpression && a.constant is InstanceConstant) {
      final c = a.constant as InstanceConstant;
      if (c.classNode.name == 'pragma' &&
          c.classNode.enclosingLibrary.importUri.toString() == 'dart:core') {
        for (final field in c.fieldValues.entries) {
          if (field.key.asField.name.text == 'name' &&
              field.value is StringConstant)
            pragmas.add((field.value as StringConstant).value);
        }
      }
    }
  }
  return pragmas;
}

/// Checks the module's PatchEntry and returns its six slots.
List<Expression> checkEntry(
  Iterable<Library> module,
  int seq,
  String fingerprint,
  String tier,
) {
  final entries = module
      .expand((l) => l.procedures)
      .where((p) => p.name.text == 'dynamicModuleEntrypoint')
      .toList();
  if (entries.length != 1)
    throw StateError('Exactly one module entry is required');
  final entry = entries.single;
  if (!pragmaNames(
    entry,
  ).containsAll(['vm:entry-point', 'dyn-module:entry-point']))
    throw StateError('Both entry pragmas required');
  final originalBody = entry.function.body;
  final body = originalBody is Block && originalBody.statements.length == 1
      ? originalBody.statements.single
      : originalBody;
  final expression = body is ReturnStatement ? body.expression : null;
  final values = expression is ListLiteral
      ? expression.expressions
      : expression is StaticInvocation &&
            expression.target.enclosingLibrary.importUri.toString() ==
                'dart:core' &&
            expression.target.enclosingClass?.name == '_GrowableList' &&
            expression.target.name.text == '_literal6'
      ? expression.arguments.positional
      : <Expression>[];
  Object? literal(Expression e) => switch (e) {
    IntLiteral() => e.value,
    StringLiteral() => e.value,
    ConstantExpression() => switch (e.constant) {
      IntConstant c => c.value,
      StringConstant c => c.value,
      _ => null,
    },
    _ => null,
  };
  if (values.length != 6 ||
      literal(values[0]) != 1 ||
      literal(values[1]) != seq ||
      literal(values[2]) != fingerprint ||
      literal(values[3]) != tier)
    throw StateError('Entry identity differs');
  return values;
}

/// The key the engine's patcher hook asks for: the host's declaration,
/// `library#name` or `library#Class.name`. A module names its libraries
/// package:patch.<seq>.<package>/..., the host package:<package>/....
String entryKey(Procedure procedure) {
  final library = '${procedure.enclosingLibrary.importUri}'.replaceFirst(
    RegExp(r'^package:patch\.\d+\.'),
    'package:',
  );
  final owner = procedure.enclosingClass;
  return '$library#${owner == null ? '' : '${owner.name}.'}${procedure.name.text}';
}

/// The module's entry points by [entryKey]: its static methods marked
/// `@pragma('vm:entry-point')` (what an engine may start or call back by
/// name), and the module's main, the PatchEntry's [slots] 4.
Map<String, Procedure> entryPoints(
  Iterable<Library> module,
  List<Expression> slots,
) {
  final found = <String, Procedure>{};
  void add(Procedure p) {
    if (p.isStatic &&
        p.kind == ProcedureKind.Method &&
        !p.isAbstract &&
        !p.isExternal &&
        p.name.text != 'dynamicModuleEntrypoint' &&
        pragmaNames(p).contains('vm:entry-point'))
      found[entryKey(p)] = p;
  }

  for (final library in module) {
    library.procedures.forEach(add);
    for (final cls in library.classes) {
      cls.procedures.forEach(add);
    }
  }
  final main = switch (slots[4]) {
    StaticTearOff e => e.target,
    ConstantExpression(constant: StaticTearOffConstant c) => c.target,
    _ => throw StateError('PatchEntry main is not a tear-off'),
  };
  found[entryKey(main)] = main;
  return found;
}

/// Replaces the PatchEntry's empty table ([slots] 5) with [entries]: the
/// patch's version of each entry point, by key. A constant, as the CFE
/// emits tear-offs; the bytecode generator takes no other form.
void installEntryTable(
  List<Expression> slots,
  Map<String, Procedure> entries,
  CoreTypes core,
) {
  final table = slots[5];
  if (!(table is NullLiteral ||
      table is ConstantExpression && table.constant is NullConstant))
    throw StateError('PatchEntry table is not empty');
  final keys = entries.keys.toList()..sort();
  final keyType = core.stringNonNullableRawType;
  final valueType = core.functionNonNullableRawType;
  table.replaceWith(
    ConstantExpression(
      MapConstant(keyType, valueType, [
        for (final key in keys)
          ConstantMapEntry(
            StringConstant(key),
            StaticTearOffConstant(entries[key]!),
          ),
      ]),
      InterfaceType(core.mapClass, Nullability.nonNullable, [
        keyType,
        valueType,
      ]),
    ),
  );
}
