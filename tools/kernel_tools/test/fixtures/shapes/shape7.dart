// 7 · runApp 之前就用 rootBundle 读配置
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'common.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final String cfg = await rootBundle.loadString('assets/probe.txt');
  runApp(App(config: cfg.trim()));
}
