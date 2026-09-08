import 'dart:convert';
import 'package:kernel/kernel.dart';
import 'package:kernel/class_hierarchy.dart';
import 'package:front_end/src/kernel/dynamic_module_validator.dart';

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
            'IconData requires complete WP-7 font subsetting',
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
          if (!member.name.isPrivate &&
              host.contains(member.enclosingLibrary) &&
              (!exposed(member) || !recorded(member))) {
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

void checkEntry(
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
  final pragmas = <String>{};
  for (final a in entry.annotations) {
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
  if (!pragmas.containsAll(['vm:entry-point', 'dyn-module:entry-point']))
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
}
