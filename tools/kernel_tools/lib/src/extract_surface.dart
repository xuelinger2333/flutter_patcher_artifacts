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

  /// Host redirecting factories by their target. The host kernel calls the
  /// target directly (`NetworkImage(url)` becomes the private implementation's
  /// constructor), while the patch compiler checks the factory the source names.
  final Map<Member, List<Procedure>> redirectors =
      Map<Member, List<Procedure>>.identity();

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
        for (final p in cls.procedures) {
          final target = p.function.redirectingFactoryTarget?.target;
          if (target != null) redirectors.putIfAbsent(target, () => []).add(p);
        }
        if (cls.name.startsWith('_')) continue;
        for (final f in cls.fields) {
          if (f.isStatic) index(f);
        }
      }
    }
  }

  /// The member the patch validator checks for [m]: it unwraps forwarding,
  /// mixin and signature stubs, and maps a member copied into an eliminated
  /// mixin application (`_State&Object&Diagnosticable.toString`) back to the
  /// mixin's own declaration (`Diagnosticable.toString`).
  static Member origin(Member m) {
    Member unwrap(Member m) {
      while (m is Procedure &&
          m.stubTarget != null &&
          (m.stubKind == ProcedureStubKind.ConcreteForwardingStub ||
              m.stubKind == ProcedureStubKind.ConcreteMixinStub ||
              m.stubKind == ProcedureStubKind.MemberSignature)) {
        m = m.stubTarget!;
      }
      return m;
    }

    final member = unwrap(m);
    final cls = member.enclosingClass;
    if (!member.isInstanceMember ||
        cls == null ||
        !cls.isEliminatedMixin ||
        cls.implementedTypes.isEmpty)
      return member;
    final setter = member is Procedure && member.isSetter;
    Member? lookup(Class c, Set<Class> seen) {
      if (!seen.add(c)) return null;
      for (final candidate in c.members) {
        if (!candidate.isInstanceMember || candidate.name != member.name)
          continue;
        final isSetter = candidate is Procedure && candidate.isSetter;
        if (setter
            ? isSetter || (candidate is Field && candidate.hasSetter)
            : !isSetter)
          return candidate;
      }
      for (final s in c.supers) {
        final found = lookup(s.classNode, seen);
        if (found != null) return found;
      }
      return null;
    }

    final found = lookup(cls.implementedTypes.last.classNode, {});
    return found == null ? member : unwrap(found);
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

  // Records the member as referenced and, when they differ, the declaration
  // the patch validator resolves it to. Public members of private classes
  // count: `requestOptions.headers` is declared by dio's `_RequestConfig`, and
  // mixin applications are private (`_RxImpl&RxNotifier&RxObjectMixin`).
  void _addMember(Map<String, Map<String, Set<String>>> into, Member? m) {
    if (m == null) return;
    _record(into, m, _memberKey(m));
    final o = origin(m);
    if (!identical(o, m)) _record(into, o, _memberKey(o));
    if (identical(into, callable)) {
      for (final factory in redirectors[m] ?? const <Procedure>[]) {
        _addMember(into, factory);
      }
    }
  }

  void _addSetter(Map<String, Map<String, Set<String>>> into, Member? m) {
    if (m == null) return;
    // A field is keyed bare; only a Procedure setter carries the 'set:' prefix.
    String key(Member m) => m is Field ? m.name.text : 'set:${m.name.text}';
    _record(into, m, key(m));
    final o = origin(m);
    if (!identical(o, m)) _record(into, o, key(o));
  }

  void _recordPrivate(Map<String, Map<String, Set<String>>> into, Member m) {
    final lib = m.enclosingLibrary;
    if (_isOwn(lib) || m.name.library != lib) return;
    into
        .putIfAbsent(lib.importUri.toString(), () => {})
        .putIfAbsent(m.enclosingClass?.name ?? LibraryIndex.topLevel, () => {})
        .add(_memberKey(m)!);
  }

  void _record(
    Map<String, Map<String, Set<String>>> into,
    Member m,
    String? key,
  ) {
    final lib = m.enclosingLibrary;
    if (_isOwn(lib)) return;
    // LibraryIndex refuses to index members with a private name, so an entry
    // naming one would fail to resolve.
    if (m.name.isPrivate || key == null) return;
    into
        .putIfAbsent(lib.importUri.toString(), () => {})
        .putIfAbsent(m.enclosingClass?.name ?? LibraryIndex.topLevel, () => {})
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

  // `super(...)` and `super.key`: written or implicit, these call the host
  // constructor from the application's own constructors.
  @override
  void visitSuperInitializer(SuperInitializer node) {
    _addMember(callable, node.target);
    super.visitSuperInitializer(node);
  }

  @override
  void visitRedirectingInitializer(RedirectingInitializer node) {
    _addMember(callable, node.target);
    super.visitRedirectingInitializer(node);
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
    // its declaration. The source may also write the constructor
    // (`const TextMagnifierConfiguration()` equals `.disabled`), which the
    // patch validator checks, so public constructors are named as well.
    final declarations = constDeclarations[c] ?? <Field>[];
    for (final field in declarations) {
      _addMember(callable, field);
      _addClass(canBeUsedAsType, field.enclosingClass);
    }
    // Type arguments of constants are type uses too: `links: {}` for a
    // `Map<String, LinkSchema>` parameter folds to a typed empty map.
    if (c is ListConstant) c.typeArgument.accept(this);
    if (c is SetConstant) c.typeArgument.accept(this);
    if (c is MapConstant) {
      c.keyType.accept(this);
      c.valueType.accept(this);
    }
    if (c is InstanceConstant) {
      for (final t in c.typeArguments) t.accept(this);
      _addClass(canBeUsedAsType, c.classNode);
      for (final ctor in c.classNode.constructors) {
        if (!ctor.name.isPrivate) _addMember(callable, ctor);
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

/// Selectors invoked on `dynamic` receivers, by access kind.
class _DynamicSelectors extends RecursiveVisitor {
  final methods = <String>{}, getters = <String>{}, setters = <String>{};

  @override
  void visitDynamicInvocation(DynamicInvocation node) {
    methods.add(node.name.text);
    super.visitDynamicInvocation(node);
  }

  @override
  void visitDynamicGet(DynamicGet node) {
    getters.add(node.name.text);
    super.visitDynamicGet(node);
  }

  @override
  void visitDynamicSet(DynamicSet node) {
    setters.add(node.name.text);
    super.visitDynamicSet(node);
  }
}

/// `dynamically-callable` rows for every host member a dynamic call in the
/// application (its own code or a dependency, which the whole tier carries)
/// can reach. Patch code like `response['code']` on a decoded JSON map then
/// validates, and the host keeps those members dynamically invocable. A class
/// that overrides noSuchMethod, or any supertype of one (Flutter's own
/// `_WidgetInputBorderMapper` is a ShapeBorder), cannot be listed: the
/// validator rejects the subtype once its supertype is dynamically-callable.
void _dynamicRows(
  Component component,
  _Collector collector,
  InterfaceDocument doc,
) {
  final used = _DynamicSelectors();
  for (final lib in component.libraries) {
    if (lib.importUri.scheme != 'dart') lib.accept(used);
  }
  final excluded = Set<Class>.identity(), declares = Set<Class>.identity();
  void exclude(Class c) {
    if (!excluded.add(c)) return;
    for (final s in c.supers) {
      exclude(s.classNode);
    }
  }

  for (final lib in component.libraries) {
    for (final cls in lib.classes) {
      if (cls.superclass != null &&
          cls.procedures.any(
            (p) => p.name.text == 'noSuchMethod' && !p.isAbstract,
          ))
        declares.add(cls);
    }
  }
  // Declares or inherits a noSuchMethod override.
  bool forwardsNoSuchMethod(Class cls) {
    for (Class? c = cls; c?.superclass != null; c = c!.superclass) {
      if (declares.contains(c)) return true;
    }
    return false;
  }

  for (final lib in component.libraries) {
    for (final cls in lib.classes) {
      if (forwardsNoSuchMethod(cls)) exclude(cls);
    }
  }

  for (final lib in component.libraries) {
    if (collector._isOwn(lib)) continue;
    for (final cls in lib.classes) {
      if (cls.superclass == null ||
          excluded.contains(cls) ||
          forwardsNoSuchMethod(cls))
        continue;
      for (final m in cls.members) {
        if (!m.isInstanceMember || m.name.isPrivate) continue;
        final name = m.name.text;
        final isSetter = m is Procedure && m.isSetter;
        final isGetter = m is Field || (m is Procedure && m.isGetter);
        final reached = isSetter
            ? used.setters.contains(name)
            : used.methods.contains(name) ||
                  used.getters.contains(name) ||
                  (m is Field && m.hasSetter && used.setters.contains(name));
        if (!reached) continue;
        final key = m is Field
            ? name
            : isSetter
            ? 'set:$name'
            : isGetter
            ? 'get:$name'
            : name;
        doc.add(
          'dynamically-callable',
          '${lib.importUri}',
          type: cls.name,
          member: key,
        );
      }
    }
  }
}

/// The declaration the patch validator checks for a referenced member.
Member surfaceOrigin(Member m) => _Collector.origin(m);

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

/// [own] packages are the patch's: their libraries are walked and never
/// recorded as targets. [scan] packages are walked too but stay host targets:
/// a whole-tier patch carries them (so their references must be covered),
/// while a lean patch keeps using the host's copies.
Surface extractSurface(
  Component component,
  Set<String> own, {
  Set<String> scan = const {},
}) {
  final collector = _Collector(own)..indexConstDeclarations(component);
  bool walk(Library lib) =>
      collector._isOwn(lib) ||
      (lib.importUri.scheme == 'package' &&
          scan.contains(lib.importUri.pathSegments.first));
  var walked = 0;
  final barrels = <String>{};
  for (final lib in component.libraries) {
    if (!walk(lib)) continue;
    walked++;
    lib.accept(collector);
    for (final cls in lib.classes) {
      for (final sup in cls.supers) {
        collector._addClass(collector.extendable, sup.classNode);
        collector._addClass(collector.canBeUsedAsType, sup.classNode);
      }
      // The host dispatches to inherited host members on the application's
      // instances (`widget.toStringShort()`, a GetxController's onStart), so
      // they must stay callable for the module's copies of these classes.
      final inherited = <Class>{};
      void inherit(Class c) {
        if (!inherited.add(c)) return;
        if (!collector._isOwn(c.enclosingLibrary)) {
          for (final m in c.members) {
            if (!m.isInstanceMember) continue;
            if (m is Procedure && m.isSetter) {
              collector._addSetter(collector.callable, m);
            } else {
              collector._addMember(collector.callable, m);
            }
          }
        }
        for (final sup in c.supers) {
          inherit(sup.classNode);
        }
      }

      for (final sup in cls.supers) {
        inherit(sup.classNode);
      }
      // The validator checks every override pair in the application class's
      // hierarchy, including host members overriding host members and host
      // implementations of host interfaces (Route.isCurrent for
      // PredictiveBackRoute.isCurrent through ModalRoute): every host member
      // whose name is declared more than once in the hierarchy is listed.
      // (_addMember and _recordPrivate skip the application's own members.)
      // Own declarations count too (a mixin's showToolbar meeting the
      // TextInputClient its user implements); only host members are listed.
      final declarations = <String, List<Member>>{};
      for (final c in {cls, ...inherited}) {
        for (final m in c.members) {
          if (!m.isInstanceMember || m is Constructor) continue;
          final setter = m is Procedure && m.isSetter;
          final key = '${m.name.isPrivate ? m.name.library!.importUri : ''}'
              '#${m.name.text}#${setter ? 'set' : 'get'}';
          declarations.putIfAbsent(key, () => []).add(m);
          if (m is Field && m.hasSetter) {
            declarations
                .putIfAbsent(key.replaceFirst(RegExp(r'#get$'), '#set'), () => [])
                .add(m);
          }
        }
      }
      // Implementing a host class overrides every member of it, private ones
      // included (`implements ImageStreamCompleterHandle` and its _completer).
      for (final type in cls.implementedTypes) {
        final host = type.classNode;
        if (collector._isOwn(host.enclosingLibrary)) continue;
        for (final m in host.members) {
          if (!m.isInstanceMember || m is Constructor) continue;
          if (m.name.isPrivate) {
            collector._recordPrivate(collector.canBeOverridden, m);
          } else {
            collector._addMember(collector.canBeOverridden, m);
          }
        }
      }
      for (final group in declarations.values) {
        if (group.length < 2) continue;
        for (final m in group) {
          if (m.name.isPrivate) {
            collector._recordPrivate(collector.canBeOverridden, m);
          } else {
            collector._addMember(collector.canBeOverridden, m);
          }
        }
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
  _dynamicRows(component, collector, doc);
  return Surface(doc, barrels);
}
