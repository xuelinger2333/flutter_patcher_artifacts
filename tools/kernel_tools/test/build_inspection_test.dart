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
  print('build inspection: allocation semantics and 6 malformed traces passed');
}
