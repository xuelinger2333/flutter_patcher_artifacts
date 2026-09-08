import 'package:kernel/kernel.dart';
import 'interface_document.dart';

/// Uses the module's imports/exported declarations, never a global name search.
InterfaceDocument resolveInterfaceHints(
  Component component,
  Set<String> own,
  String log,
) {
  final visible = <Library>{};
  final visibleClasses = <Class>{};
  final visibleMembers = <Member>{};
  void expose(TreeNode? node, LibraryDependency? dependency) {
    final name = node is Class
        ? node.name
        : node is Member
        ? node.name.text
        : null;
    if (name == null) return;
    for (final combinator in dependency?.combinators ?? <Combinator>[]) {
      if (combinator.isShow
          ? !combinator.names.contains(name)
          : combinator.names.contains(name))
        return;
    }
    if (node is Class) {
      visibleClasses.add(node);
      visible.add(node.enclosingLibrary);
    } else if (node is Member) {
      visibleMembers.add(node);
      visible.add(node.enclosingLibrary);
    }
  }

  bool isOwn(Library lib) => lib.importUri.scheme == 'package'
      ? own.contains(lib.importUri.pathSegments.first)
      : lib.importUri.scheme == 'file';
  var foundOwn = false;
  for (final lib in component.libraries) {
    // Only dart:core is implicit. Including all platform libraries confuses
    // exported dart:ui Size with the unrelated dart:ffi Size, for example.
    if (lib.importUri.toString() == 'dart:core') {
      for (final node in <TreeNode>[...lib.classes, ...lib.members]) {
        expose(node, null);
      }
    }
    if (!isOwn(lib)) continue;
    foundOwn = true;
    for (final dep in lib.dependencies) {
      if (dep.isExport) continue;
      final target = dep.targetLibrary;
      for (final node in <TreeNode>[...target.classes, ...target.members]) {
        expose(node, dep);
      }
      for (final ref in target.additionalExports) {
        expose(ref.node, dep);
      }
    }
  }
  if (!foundOwn) throw StateError('No module libraries match --own');
  final result = InterfaceDocument();
  final pattern = RegExp(
    r"list (member|class|constructor) '([^']+)' as ([a-z-]+)",
  );
  final hints = pattern.allMatches(log).toList();
  if (hints.isEmpty)
    throw StateError('Validation failed without resolvable interface hints');
  for (final hint in hints) {
    final kind = hint[1]!, name = hint[2]!, section = hint[3]!;
    if (!InterfaceDocument.sections.contains(section)) {
      throw StateError('Unsupported compiler hint section: $section');
    }
    final candidates = <String, Map<String, String>>{};
    void candidate(Library lib, {String? type, String? member}) {
      if (isOwn(lib) ||
          (type?.startsWith('_') ?? false) ||
          (member?.replaceFirst(RegExp(r'^(get|set):'), '').startsWith('_') ??
              false))
        return;
      final row = <String, String>{
        'library': lib.importUri.toString(),
        if (type != null) 'class': type,
        if (member != null) 'member': member,
      };
      candidates['${row['library']}|$type|$member'] = row;
    }

    String key(Member m) => m is Procedure && m.isGetter
        ? 'get:${m.name.text}'
        : m is Procedure && m.isSetter
        ? 'set:${m.name.text}'
        : m.name.text;
    for (final lib in visible) {
      if (kind == 'member' && !name.contains('.')) {
        for (final m in lib.members) {
          if (!visibleMembers.contains(m)) continue;
          if (!m.name.isPrivate && (name == m.name.text || name == key(m))) {
            candidate(lib, member: key(m));
          }
        }
      }
      for (final cls in lib.classes) {
        if (!visibleClasses.contains(cls)) continue;
        if (kind == 'class' && cls.name == name) candidate(lib, type: cls.name);
        if (kind == 'class') continue;
        if (kind == 'constructor') {
          final dot = name.indexOf('.');
          final type = dot < 0 ? name : name.substring(0, dot);
          final ctor = dot < 0 ? '' : name.substring(dot + 1);
          if (cls.name != type) continue;
          for (final m in cls.members) {
            if ((m is Constructor || (m is Procedure && m.isFactory)) &&
                m.name.text == ctor) {
              candidate(lib, type: cls.name, member: key(m));
            }
          }
        } else if (name.startsWith('${cls.name}.')) {
          final wanted = name.substring(cls.name.length + 1);
          for (final m in cls.members) {
            if (!m.name.isPrivate &&
                (wanted == key(m) || wanted == m.name.text)) {
              candidate(lib, type: cls.name, member: key(m));
            }
          }
        }
      }
    }
    if (candidates.length != 1) {
      throw StateError(
        '${candidates.isEmpty ? 'Unresolved' : 'Ambiguous'} hint: '
        '${hint[0]}; candidates=${candidates.keys.toList()..sort()}',
      );
    }
    final row = candidates.values.single;
    result.add(
      section,
      row['library']!,
      type: row['class'],
      member: row['member'],
    );
    if (row['class'] != null) {
      result.add('can-be-used-as-type', row['library']!, type: row['class']);
      final cls = visible
          .where((l) => l.importUri.toString() == row['library'])
          .expand((l) => l.classes)
          .where((c) => c.name == row['class'])
          .single;
      if (cls.isEnum) result.add('callable', row['library']!, type: cls.name);
    }
  }
  return result;
}
