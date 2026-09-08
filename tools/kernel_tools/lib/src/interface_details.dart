import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:kernel/ast.dart';
import 'interface_document.dart';

Map<String, Object?> describeInterface(
  Component component,
  InterfaceDocument result,
  Map<String, InterfaceDocument> inputs, {
  Map<String, dynamic>? previous,
  String? previousHash,
}) {
  String key(String section, Map<String, String> row) =>
      jsonEncode({'section': section, ...row});
  final provenance = <String, Set<String>>{};
  if (previous != null) {
    if (previous['schema'] != 1 ||
        previous['interface_sha256'] != previousHash ||
        previous['entries'] is! List) {
      throw const FormatException(
        'Previous interface details do not match input',
      );
    }
    for (final value in previous['entries'] as List) {
      final row = Map<String, dynamic>.from(value as Map);
      final sources = (row.remove('sources') as List).cast<String>();
      row.remove('location');
      final section = row.remove('section') as String;
      provenance[key(section, row.cast<String, String>())] = sources.toSet();
    }
  }
  for (final entry in inputs.entries) {
    for (final section in InterfaceDocument.sections) {
      for (final row in entry.value.rows(section)) {
        final k = key(section, row);
        if (entry.key == 'referenced' && provenance.containsKey(k)) continue;
        (provenance[k] ??= {}).add(entry.key);
      }
    }
  }
  Map<String, Object?>? location(Map<String, String> row) {
    final libs = component.libraries.where(
      (l) => l.importUri.toString() == row['library'],
    );
    if (libs.isEmpty) return null;
    final library = libs.first;
    TreeNode? node;
    final type = row['class'], member = row['member'];
    if (type != null) {
      final classes = library.classes.where((c) => c.name == type);
      if (classes.isEmpty) return null;
      final cls = classes.first;
      node = cls;
      if (member != null) {
        node = null;
        for (final m in [
          ...cls.fields,
          ...cls.procedures,
          ...cls.constructors,
        ]) {
          final name = m is Procedure && m.isGetter
              ? 'get:${m.name.text}'
              : m is Procedure && m.isSetter
              ? 'set:${m.name.text}'
              : m.name.text;
          if (name == member) {
            node = m;
            break;
          }
        }
      }
    } else if (member != null) {
      for (final m in [...library.fields, ...library.procedures]) {
        final name = m is Procedure && m.isGetter
            ? 'get:${m.name.text}'
            : m is Procedure && m.isSetter
            ? 'set:${m.name.text}'
            : m.name.text;
        if (name == member) {
          node = m;
          break;
        }
      }
    }
    if (node == null || node.fileOffset < 0) return null;
    final loc = node.location;
    if (loc == null) return null;
    // Logical library identity, never a build-machine absolute source path.
    return {'uri': row['library'], 'line': loc.line, 'column': loc.column};
  }

  return {
    'schema': 1,
    'interface_sha256': sha256.convert(utf8.encode(result.encode())).toString(),
    'entries': [
      for (final section in InterfaceDocument.sections)
        for (final row in result.rows(section))
          {
            'section': section,
            ...row,
            'sources':
                (provenance[key(section, row)] ??
                        (throw StateError('Missing interface provenance')))
                    .toList()
                  ..sort(),
            'location': location(row),
          },
    ],
  };
}
