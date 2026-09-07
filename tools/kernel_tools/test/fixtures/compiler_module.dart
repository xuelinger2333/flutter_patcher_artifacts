// No main: exercises the patched global-transformation path for a module.
class Probe {
  final int value = DateTime.now().millisecondsSinceEpoch;
}

@pragma('vm:entry-point')
@pragma('dyn-module:entry-point')
List<Object?> moduleEntry() => [Probe().value];
