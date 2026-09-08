// Migrated from flutter_patcher temp/extract_referenced_surface.dart (WP-3).
import 'package:kernel/kernel.dart';
import 'package:kernel/library_index.dart';
import 'interface_document.dart';

class _Collector extends RecursiveVisitor {
  final Set<String> ownPackages;

  // library uri -> container name ('::' for top level) -> member keys
  final Map<String, Map<String, Set<String>>> callable = {};
  final Map<String, Map<String, Set<String>>> canBeOverridden = {};
  final Map<String, Set<String>> canBeUsedAsType = {};
  final Map<String, Set<String>> extendable = {};
  // Classes that need a class-level `callable` entry so the host keeps them.
  final Map<String, Set<String>> callableClasses = {};

  /// Canonicalised constant -> the const field that declares it, for host
  /// libraries only. Filled by [indexConstDeclarations] before the walk.
  final Map<Constant, List<Field>> constDeclarations =
      Map<Constant, List<Field>>.identity();

  _Collector(this.ownPackages);

  void indexConstDeclarations(Component component) {
    void index(Field f) {
      if (!f.isConst) return;
      if (f.name.isPrivate) return;
      final init = f.initializer;
      if (init is ConstantExpression) {
        constDeclarations.putIfAbsent(init.constant, () => []).add(f);
      }
    }

    for (final lib in component.libraries) {
      if (_isOwn(lib)) continue;
      lib.fields.forEach(index);
      for (final cls in lib.classes) {
        if (cls.name.startsWith('_')) continue;
        for (final f in cls.fields) {
          if (f.isStatic) index(f);
        }
      }
    }
  }

  bool _isOwn(Library lib) {
    final uri = lib.importUri;
    if (uri.scheme != 'package') return uri.scheme == 'file';
    return ownPackages.contains(uri.pathSegments.first);
  }

  // LibraryIndex only prefixes Procedure getters/setters; fields, methods,
  // operators and constructors are keyed by their bare name.
  String? _memberKey(Member m) {
    if (m is Procedure) {
      if (m.isGetter) return 'get:${m.name.text}';
      if (m.isSetter) return 'set:${m.name.text}';
    }
    return m.name.text;
  }

  void _addMember(Map<String, Map<String, Set<String>>> into, Member? m) {
    if (m == null) return;
    final lib = m.enclosingLibrary;
    if (_isOwn(lib)) return;
    // LibraryIndex refuses to index members with a private name, so an entry
    // naming one would fail to resolve.
    if (m.name.isPrivate) return;
    final cls = m.enclosingClass;
    if (cls != null && cls.name.startsWith('_')) return;
    final key = _memberKey(m);
    if (key == null) return;
    into
        .putIfAbsent(lib.importUri.toString(), () => {})
        .putIfAbsent(cls?.name ?? LibraryIndex.topLevel, () => {})
        .add(key);
  }

  void _addSetter(Map<String, Map<String, Set<String>>> into, Member? m) {
    if (m == null) return;
    final lib = m.enclosingLibrary;
    if (_isOwn(lib)) return;
    if (m.name.isPrivate) return;
    final cls = m.enclosingClass;
    if (cls != null && cls.name.startsWith('_')) return;
    // A field is keyed bare; only a Procedure setter carries the 'set:' prefix.
    final key = m is Field ? m.name.text : 'set:${m.name.text}';
    into
        .putIfAbsent(lib.importUri.toString(), () => {})
        .putIfAbsent(cls?.name ?? LibraryIndex.topLevel, () => {})
        .add(key);
  }

  void _addClass(Map<String, Set<String>> into, Class? c) {
    if (c == null) return;
    if (c.name.startsWith('_')) return;
    final lib = c.enclosingLibrary;
    if (_isOwn(lib)) return;
    into.putIfAbsent(lib.importUri.toString(), () => {}).add(c.name);
    // `can-be-used-as-type` lets a module name a class but does not keep the
    // class itself in the host snapshot, and the bytecode loader resolves an
    // enum value through its class: `Unable to find class X in Library Y` at
    // load time, long after --validate passed. A class-level `callable` entry
    // forces AddInstantiatedClass, and for an enum that is a handful of members.
    if (identical(into, canBeUsedAsType) && c.isEnum) {
      callableClasses
          .putIfAbsent(lib.importUri.toString(), () => {})
          .add(c.name);
    }
  }

  // ---- expressions -------------------------------------------------------

  @override
  void visitInstanceInvocation(InstanceInvocation node) {
    _addMember(callable, node.interfaceTarget);
    super.visitInstanceInvocation(node);
  }

  @override
  void visitInstanceGet(InstanceGet node) {
    _addMember(callable, node.interfaceTarget);
    super.visitInstanceGet(node);
  }

  @override
  void visitInstanceSet(InstanceSet node) {
    _addSetter(callable, node.interfaceTarget);
    super.visitInstanceSet(node);
  }

  @override
  void visitInstanceTearOff(InstanceTearOff node) {
    _addMember(callable, node.interfaceTarget);
    super.visitInstanceTearOff(node);
  }

  @override
  void visitEqualsCall(EqualsCall node) {
    _addMember(callable, node.interfaceTarget);
    super.visitEqualsCall(node);
  }

  @override
  void visitStaticInvocation(StaticInvocation node) {
    _addMember(callable, node.target);
    super.visitStaticInvocation(node);
  }

  @override
  void visitStaticGet(StaticGet node) {
    _addMember(callable, node.target);
    super.visitStaticGet(node);
  }

  @override
  void visitStaticSet(StaticSet node) {
    _addSetter(callable, node.target);
    super.visitStaticSet(node);
  }

  @override
  void visitStaticTearOff(StaticTearOff node) {
    _addMember(callable, node.target);
    super.visitStaticTearOff(node);
  }

  @override
  void visitConstructorInvocation(ConstructorInvocation node) {
    _addMember(callable, node.target);
    _addClass(canBeUsedAsType, node.target.enclosingClass);
    super.visitConstructorInvocation(node);
  }

  @override
  void visitSuperMethodInvocation(SuperMethodInvocation node) {
    _addMember(callable, node.interfaceTarget);
    super.visitSuperMethodInvocation(node);
  }

  @override
  void visitSuperPropertyGet(SuperPropertyGet node) {
    _addMember(callable, node.interfaceTarget);
    super.visitSuperPropertyGet(node);
  }

  @override
  void visitSuperPropertySet(SuperPropertySet node) {
    _addSetter(callable, node.interfaceTarget);
    super.visitSuperPropertySet(node);
  }

  // ---- constants ---------------------------------------------------------

  @override
  void visitConstantExpression(ConstantExpression node) {
    _visitConstant(node.constant, <Constant>{});
    super.visitConstantExpression(node);
  }

  void _visitConstant(Constant c, Set<Constant> seen) {
    if (!seen.add(c)) return;
    // The CFE folds `TargetPlatform.android` into a bare InstanceConstant, so
    // the field that declares it leaves no reference behind -- but a dynamic
    // module still has to be allowed to read that field. Map the value back to
    // its declaration; only fall back to naming constructors when no const
    // field declares it (an inline `const RoundSliderThumbShape()`).
    final declarations = constDeclarations[c] ?? <Field>[];
    for (final field in declarations) {
      _addMember(callable, field);
      _addClass(canBeUsedAsType, field.enclosingClass);
    }
    if (c is InstanceConstant) {
      _addClass(canBeUsedAsType, c.classNode);
      if (declarations.isEmpty) {
        for (final ctor in c.classNode.constructors) {
          if (!ctor.name.isPrivate) _addMember(callable, ctor);
        }
      }
      c.fieldValues.forEach((ref, value) {
        _addMember(callable, ref.asField);
        _visitConstant(value, seen);
      });
    } else if (c is TypeLiteralConstant) {
      c.type.accept(this);
    } else if (c is StaticTearOffConstant) {
      _addMember(callable, c.target);
    } else if (c is ListConstant) {
      for (final e in c.entries) _visitConstant(e, seen);
    } else if (c is SetConstant) {
      for (final e in c.entries) _visitConstant(e, seen);
    } else if (c is MapConstant) {
      for (final e in c.entries) {
        _visitConstant(e.key, seen);
        _visitConstant(e.value, seen);
      }
    } else if (c is InstantiationConstant) {
      _visitConstant(c.tearOffConstant, seen);
    }
  }

  // ---- types -------------------------------------------------------------

  @override
  void visitInterfaceType(InterfaceType node) {
    _addClass(canBeUsedAsType, node.classNode);
    super.visitInterfaceType(node);
  }
}

class Surface {
  final InterfaceDocument interface;
  final Set<String> barrels;
  Surface(this.interface, this.barrels);
  InterfaceDocument get trim {
    final result = InterfaceDocument()..merge(interface);
    for (final uri in barrels) {
      result.add('callable', uri);
    }
    return result;
  }

  Map<String, int> get counts => {
    'members': interface
        .rows('callable')
        .where((r) => r.containsKey('member'))
        .length,
    'types': interface.count('can-be-used-as-type'),
    'extendable': interface.count('extendable'),
    'overridable': interface.count('can-be-overridden'),
    'barrels': barrels.length,
  };
}

Surface extractSurface(Component component, Set<String> own) {
  final collector = _Collector(own)..indexConstDeclarations(component);
  var walked = 0;
  final barrels = <String>{};
  for (final lib in component.libraries) {
    if (!collector._isOwn(lib)) continue;
    walked++;
    lib.accept(collector);
    for (final cls in lib.classes) {
      for (final sup in cls.supers) {
        collector._addClass(collector.extendable, sup.classNode);
        collector._addClass(collector.canBeUsedAsType, sup.classNode);
      }
      for (final member in cls.members) {
        if (!member.isInstanceMember || member.name.isPrivate) continue;
        final visited = <Class>{};
        void walk(Class parent) {
          if (!visited.add(parent)) return;
          for (final inherited in parent.members) {
            if (!inherited.isInstanceMember || inherited.name != member.name)
              continue;
            if (inherited is Procedure &&
                member is Procedure &&
                inherited.kind != member.kind)
              continue;
            collector._addMember(collector.canBeOverridden, inherited);
          }
          for (final sup in parent.supers) {
            walk(sup.classNode);
          }
        }

        for (final sup in cls.supers) {
          walk(sup.classNode);
        }
      }
    }
    for (final dep in lib.dependencies) {
      final target = dep.targetLibrary;
      if (!collector._isOwn(target) &&
          target.importUri.scheme == 'package' &&
          target.classes.isEmpty &&
          target.procedures.isEmpty &&
          target.fields.isEmpty) {
        barrels.add(target.importUri.toString());
      }
    }
  }
  if (walked == 0) throw StateError('No libraries match --own');
  final doc = InterfaceDocument();
  void classes(String section, Map<String, Set<String>> entries) {
    for (final lib in entries.entries) {
      for (final name in lib.value) {
        doc.add(section, lib.key, type: name);
      }
    }
  }

  void members(String section, Map<String, Map<String, Set<String>>> entries) {
    for (final lib in entries.entries) {
      for (final cls in lib.value.entries) {
        for (final member in cls.value) {
          doc.add(
            section,
            lib.key,
            type: cls.key == LibraryIndex.topLevel ? null : cls.key,
            member: member,
          );
        }
      }
    }
  }

  classes('extendable', collector.extendable);
  classes('can-be-used-as-type', collector.canBeUsedAsType);
  classes('callable', collector.callableClasses);
  members('callable', collector.callable);
  members('can-be-overridden', collector.canBeOverridden);
  return Surface(doc, barrels);
}
