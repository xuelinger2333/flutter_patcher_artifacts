// 5 · runWidget 而不是 runApp
import 'package:flutter/material.dart';
import 'common.dart';

void main() {
  final WidgetsBinding binding = WidgetsFlutterBinding.ensureInitialized();
  runWidget(
    View(
      view: binding.platformDispatcher.views.first,
      child: const App(),
    ),
  );
}
