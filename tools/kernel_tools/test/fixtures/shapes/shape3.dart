// 3 · runApp 在另一个函数里，main 只是转发
import 'package:flutter/material.dart';
import 'common.dart';

void main() => bootstrap();

void bootstrap() {
  runApp(const App());
}
