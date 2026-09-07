// 2 · ensureInitialized + await 初始化 + runApp
import 'package:flutter/material.dart';
import 'common.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Future<void>.delayed(const Duration(milliseconds: 1));
  runApp(const App());
}
