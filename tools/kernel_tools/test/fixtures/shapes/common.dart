// The app body every shape shares. Reads an asset through the bundle the
// framework hands it, so the overlay either covers it or does not.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// 让覆盖层辅助库进到 dill 里，供 kernel 变换引用。
import 'overlay_helper.dart';
// ignore: unused_element
final Object _keepOverlayLib = patcherOverlayBundle;

class App extends StatelessWidget {
  const App({super.key, this.flavor = '-', this.config = '-'});
  final String flavor;
  final String config;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(home: Probe(flavor: flavor, config: config));
  }
}

class Probe extends StatefulWidget {
  const Probe({super.key, required this.flavor, required this.config});
  final String flavor;
  final String config;
  @override
  State<Probe> createState() => _ProbeState();
}

class _ProbeState extends State<Probe> {
  String _viaDefault = '?';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    DefaultAssetBundle.of(context).loadString('assets/probe.txt').then((String v) {
      if (mounted) setState(() => _viaDefault = v.trim());
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Text('flavor=${widget.flavor} config=${widget.config} '
            'viaDefaultAssetBundle=$_viaDefault'),
      ),
    );
  }
}

