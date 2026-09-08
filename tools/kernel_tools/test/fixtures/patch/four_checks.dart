import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:typed_data';
import 'dart:io';

class Bundle extends CachingAssetBundle {
  Future<ByteData> load(String key) async => ByteData(1);
}

void main() {
  rootBundle.load('assets/new.bin');
  print(ProcessException('missing', []));
  runApp(MaterialApp(home: Checkbox(value: true, onChanged: (_) {})));
}
