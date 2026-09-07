import 'dart:convert';
import 'dart:io';

import 'definitions.dart';

import 'package:kernel/kernel.dart';
import 'package:yaml/yaml.dart';

void main(List<String> args) {
  if (args.length != 4 ||
      args[0] != '--dill' ||
      args[2] != '--out') {
    throw ArgumentError('usage: generate.dart --dill <linked-flutter.dill> '
        '--out <protocol.yaml>');
  }
  final component = loadComponentFromBinary(args[1]);
  final definitions = loadYaml(protocolDefinitions) as YamlMap;
  final libraries = {
    for (final l in component.libraries) l.importUri.toString(): l
  };
  final output =
      StringBuffer('# Generated against the selected Flutter kernel.\n');
  const sections = [
    'extendable',
    'can-be-overridden',
    'can-be-used-as-type',
    'callable'
  ];
  if (definitions.keys.toSet().difference(sections.toSet()).isNotEmpty ||
      sections.any((s) => !definitions.containsKey(s))) {
    throw StateError('Protocol definition sections do not match the contract');
  }
  var count = 0;
  for (final section in sections) {
    final entries = <String, Set<String>>{};
    for (final entry in definitions[section] as YamlList) {
      final uri = entry['library'] as String;
      if (!uri.startsWith('package:flutter/') || !libraries.containsKey(uri)) {
        throw StateError(
            'Protocol library missing from selected Flutter: $uri');
      }
      final defined = libraries[uri]!.classes.map((c) => c.name).toSet();
      final classes = entry['class'] as YamlList;
      for (final name in classes.cast<String>()) {
        if (name.startsWith('_') || !defined.contains(name)) {
          throw StateError(
              'Protocol class missing from selected Flutter: $uri::$name');
        }
        entries.putIfAbsent(uri, () => <String>{}).add(name);
      }
    }
    output.writeln('$section:');
    for (final uri in entries.keys.toList()..sort()) {
      final classes = entries[uri]!.toList()..sort();
      output.writeln('  - library: ${jsonEncode(uri)}');
      output.writeln('    class: ${jsonEncode(classes)}');
      count += classes.length;
    }
    output.writeln();
  }
  File(args[3]).writeAsStringSync(output.toString());
  stdout.writeln(jsonEncode({'protocol_class_entries': count}));
}
