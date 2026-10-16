import 'dart:io';

import 'package:flutter_patcher_kernel_tools/src/build_inspection.dart';

void main() {
  final data = <String, dynamic>{
    'strings': ['package:app/main.dart', 'Widget', 'method'],
    'entities': ['C', 0, 1, 0, 'F', 0, 2, 0],
    'trace': ['R', 0, 'C', 1, 1, 0, 'E'],
  };
  if (allocatedClasses(data).join() != 'package:app/main.dart::Widget')
    throw StateError('Allocation semantics');
  for (final trace in [
    ['R', 0],
    ['R', 999, 'E'],
    ['C'],
    ['X', 0, 'E'],
    [0, 'E', 0],
    ['C', 0, 'E'],
  ]) {
    var rejected = false;
    try {
      allocatedClasses({...data, 'trace': trace});
    } on FormatException {
      rejected = true;
    }
    if (!rejected) throw StateError('Accepted malformed/empty trace: $trace');
  }
  final temp = Directory.systemTemp.createTempSync('inspect-roots-');
  try {
    final cache = Directory('${temp.path}/cache');
    final work = Directory('${cache.path}/builds/run')
      ..createSync(recursive: true);
    File('${work.path}/main.dart').writeAsStringSync('');
    File('${cache.path}/shared.dart').writeAsStringSync('');
    final roots = [work.absolute.uri, cache.absolute.uri];
    Uri? resolve(String uri) =>
        physicalSource(Uri.parse(uri), 'org-dartlang-root', roots);
    if (resolve('org-dartlang-root:///main.dart') !=
            work.absolute.uri.resolve('main.dart') ||
        resolve('org-dartlang-root:///shared.dart') !=
            cache.absolute.uri.resolve('shared.dart') ||
        resolve('file:///x.dart') != Uri.parse('file:///x.dart') ||
        resolve('other:///x.dart') != null)
      throw StateError('Multi-root resolution order');
    var rejected = false;
    try {
      resolve('org-dartlang-root:///missing.dart');
    } on FormatException {
      rejected = true;
    }
    if (!rejected) throw StateError('Accepted a missing virtual source');
  } finally {
    temp.deleteSync(recursive: true);
  }
  print(
    'build inspection: allocation semantics, 6 malformed traces '
    'and multi-root resolution passed',
  );
}
