// 9 · runApp 被撕成闭包传走，静态定位不到真正的调用点
import 'package:flutter/material.dart';
import 'common.dart';

void main() => launch(runApp);

void launch(void Function(Widget) start) {
  start(const App());
}
