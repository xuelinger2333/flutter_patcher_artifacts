// F6: stands in for the plugin-provided overlay helper. In the real product
// this lives in package:flutter_patcher, i.e. outside the patch's own packages,
// so the shape detector never sees its rootBundle fallback.
import 'package:flutter/services.dart';

AssetBundle? _overlay;

void patcherInstallOverlay(AssetBundle b) => _overlay = b;

AssetBundle patcherOverlayBundle() => _overlay ?? rootBundle;
