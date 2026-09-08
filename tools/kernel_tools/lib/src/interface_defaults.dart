import 'package:kernel/kernel.dart';
import 'interface_document.dart';

const commonWidgets = <String, List<String>>{
  'widgets/container.dart': ['Container'],
  'widgets/basic.dart': [
    'SizedBox',
    'Center',
    'Column',
    'Row',
    'Padding',
    'Expanded',
  ],
  'widgets/icon.dart': ['Icon'],
  'widgets/text.dart': ['Text'],
  'painting/text_style.dart': ['TextStyle'],
  'painting/edge_insets.dart': ['EdgeInsets'],
  'painting/alignment.dart': ['Alignment'],
  'rendering/flex.dart': ['MainAxisAlignment', 'CrossAxisAlignment'],
};
const dynamicSelectors = [
  '-',
  '+',
  '*',
  'get:index',
  'relativeError',
  'absoluteError',
];

InterfaceDocument interfaceDefaults(
  Component component, {
  required bool whole,
}) {
  final libraries = {
    for (final l in component.libraries) l.importUri.toString(): l,
  };
  if (!libraries.containsKey('dart:core'))
    throw StateError('Linked dart:core is missing');
  final doc = InterfaceDocument();
  for (final s in InterfaceDocument.sections.where(
    (s) => s != 'dynamically-callable',
  )) {
    doc.add(s, 'dart:core');
  }
  for (final entry in commonWidgets.entries) {
    final uri = 'package:flutter/src/${entry.key}';
    final classes =
        libraries[uri]?.classes.map((c) => c.name).toSet() ?? <String>{};
    for (final type in entry.value) {
      if (!classes.contains(type))
        throw StateError('Common widget missing: $uri::$type');
      doc.add('callable', uri, type: type);
      doc.add('can-be-used-as-type', uri, type: type);
    }
  }
  if (whole) {
    // Whole-program modules carry Flutter themselves and bind all platform
    // libraries to the host. Private platform entries are merged separately.
    for (final uri in libraries.keys.where((uri) => uri.startsWith('dart:'))) {
      for (final section in InterfaceDocument.sections.where(
        (s) => s != 'dynamically-callable',
      )) {
        doc.add(section, uri);
      }
    }
    for (final type in ['num', 'int', 'double', 'Enum']) {
      if (!libraries['dart:core']!.classes.any((c) => c.name == type)) {
        throw StateError('Dynamic-call class missing: $type');
      }
      doc.add('dynamically-callable', 'dart:core', type: type);
    }
  }
  return doc;
}
