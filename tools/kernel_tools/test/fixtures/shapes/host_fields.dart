// Static fields of host code that a patch reads and assigns. The host's AOT
// build folds the first two initializers to literals, and the VM gives a
// static field a getter only when its initializer is not one (issue #19).
import 'dart:io';

const _limit = 9;

class HostFields {
  static Object? hostFoldedNull =
      const bool.fromEnvironment('SMOKE_ABSENT') ? Object() : null;
  static int hostFoldedPlatform = Platform.isAndroid ? 1 : 2;
  // Constant, yet not a literal: initialized lazily through its getter.
  static final int hostConstRef = _limit;
  // Assigned through a setter the host does not keep.
  static late final int hostLateFinal;
}
