// 6 · 自定义 binding
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'common.dart';

class MyBinding extends WidgetsFlutterBinding {
  static MyBinding? _instance;
  static MyBinding get instance => BindingBase.checkInstance(_instance);

  @override
  void initInstances() {
    super.initInstances();
    _instance = this;
  }

  static MyBinding ensureInitialized() {
    if (MyBinding._instance == null) {
      MyBinding();
    }
    return MyBinding.instance;
  }
}

void main() {
  MyBinding.ensureInitialized();
  runApp(const App());
}
