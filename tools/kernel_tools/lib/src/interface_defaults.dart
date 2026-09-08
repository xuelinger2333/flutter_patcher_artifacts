import 'package:kernel/kernel.dart';

import 'interface_document.dart';
import 'extract_surface.dart';

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
  if (libraries.containsKey(
    'package:flutter_patcher/src/patch_bootstrap.dart',
  )) {
    // Retain the actual bootstrap/overlay dependencies while building the host.
    // Patch compilation still validates against this immutable host contract.
    doc.merge(
      extractSurface(component, {
        'flutter_patcher',
        'dynamic_modules',
      }).interface,
    );
    const assets = 'package:flutter/src/services/asset_bundle.dart';
    for (final name in ['AssetBundle', 'CachingAssetBundle']) {
      if (!(libraries[assets]?.classes.any((c) => c.name == name) ?? false)) {
        throw StateError('Runtime asset superclass missing: $name');
      }
      // The module inherits loadString/structured-data helpers and invokes a
      // super constructor. Those are not ordinary call sites in its body.
      for (final section in [
        'callable',
        'extendable',
        'can-be-overridden',
        'can-be-used-as-type',
      ]) {
        doc.add(section, assets, type: name);
      }
    }
  }
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
        for (final type in libraries[uri]!.classes) {
          doc.add(section, uri, type: type.name);
        }
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
