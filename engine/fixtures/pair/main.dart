import 'dart:ui' as ui;

// A minimal Flutter kernel: no plugin, generated bootstrap, or WP-2 CLI.
void main() {
  ui.PlatformDispatcher.instance.onBeginFrame = (_) {
    final view = ui.PlatformDispatcher.instance.implicitView;
    if (view == null) {
      throw StateError('PAIR_NO_VIEW');
    }
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawColor(const ui.Color(0xff24704b), ui.BlendMode.src);
    final builder = ui.SceneBuilder()
      ..addPicture(ui.Offset.zero, recorder.endRecording());
    final scene = builder.build();
    view.render(scene);
    scene.dispose();
    print('PAIR_OK');
  };
  ui.PlatformDispatcher.instance.scheduleFrame();
}
