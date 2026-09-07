// 8 · runZonedGuarded 把 runApp 包在闭包里
import 'dart:async';

import 'package:flutter/material.dart';
import 'common.dart';

void main() {
  runZonedGuarded<void>(() {
    runApp(const App());
  }, (Object e, StackTrace s) {});
}
