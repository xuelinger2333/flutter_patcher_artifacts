import 'dart:convert';
import 'package:yaml/yaml.dart';

/// A canonical set of interface declarations. JSON is a strict YAML subset.
class InterfaceDocument {
  static const sections = [
    'extendable',
    'can-be-overridden',
    'can-be-used-as-type',
    'callable',
    'dynamically-callable',
  ];
  final _entries = <String, Map<String, Map<String, String>>>{
    for (final s in sections) s: {},
  };

  void add(String section, String library, {String? type, String? member}) {
    if (!sections.contains(section) || library.isEmpty) {
      throw FormatException(
        'Invalid interface section/library: $section $library',
      );
    }
    if (section == 'dynamically-callable' &&
        library == 'dart:core' &&
        (type == null || type == 'Object')) {
      throw const FormatException(
        'Object/broad dart:core dynamically-callable is forbidden',
      );
    }
    final row = <String, String>{
      'library': library,
      if (type != null) 'class': type,
      if (member != null) 'member': member,
    };
    _entries[section]![jsonEncode(row)] = row;
  }

  factory InterfaceDocument.parse(String text) {
    final value = loadYaml(text);
    if (value is! Map)
      throw const FormatException('Interface must be a mapping');
    final result = InterfaceDocument();
    for (final section in value.keys) {
      if (!sections.contains(section))
        throw FormatException('Unknown section $section');
      final rows = value[section];
      if (rows == null)
        continue; // Existing SDK generators emit empty sections.
      if (rows is! List) throw FormatException('Invalid section $section');
      for (final row in rows) {
        if (row is! Map ||
            row['library'] is! String ||
            row.keys.any((k) => !['library', 'class', 'member'].contains(k))) {
          throw const FormatException('Invalid interface declaration');
        }
        List<String?> names(dynamic v) {
          if (v == null) return [null];
          if (v is String) return [v];
          if (v is List && v.isNotEmpty && v.every((x) => x is String)) {
            return v.cast<String>();
          }
          throw const FormatException(
            'Expected declaration name or nonempty list',
          );
        }

        for (final type in names(row['class'])) {
          for (final member in names(row['member'])) {
            result.add(
              section as String,
              row['library'] as String,
              type: type,
              member: member,
            );
          }
        }
      }
    }
    return result;
  }
  InterfaceDocument();
  void merge(InterfaceDocument other) {
    for (final s in sections) {
      _entries[s]!.addAll(other._entries[s]!);
    }
  }

  int count(String section) => _entries[section]!.length;
  List<Map<String, String>> rows(String section) => [
    for (final key in _entries[section]!.keys.toList()..sort())
      _entries[section]![key]!,
  ];
  String encode() =>
      '${const JsonEncoder.withIndent('  ').convert({for (final s in sections) s: rows(s)})}\n';
}
