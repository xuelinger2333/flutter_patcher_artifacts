// 4 · runApp 被条件包着，多处调用
import 'package:flutter/material.dart';
import 'common.dart';

void main() {
  if (const bool.fromEnvironment('PRO')) {
    runApp(const App(flavor: 'pro'));
  } else {
    runApp(const App(flavor: 'free'));
  }
}
