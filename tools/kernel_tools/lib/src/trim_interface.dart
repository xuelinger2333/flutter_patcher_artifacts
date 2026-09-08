import 'dart:io';
import 'dart:async';
import 'package:front_end/src/util/trim.dart';
import 'package:kernel/target/targets.dart';
import 'package:vm/modular/target/flutter.dart';

/// SDK trimming stays in the CI-built version-bound tool, not in the CLI.
Future<void> trimInterface(
  String input,
  String platform,
  String iface,
  String output,
  String outputPlatform,
) async {
  await runZoned(
    () => createTrimmedCopy(
      TrimOptions(
        inputAppPath: input,
        inputPlatformPath: platform,
        outputAppPath: output,
        outputPlatformPath: outputPlatform,
        dynamicInterfaceUri: File(iface).uri,
        dynamicInterfaceContents: File(iface).readAsStringSync(),
        requiredUserLibraries: {},
        requiredDartLibraries: FlutterTarget(
          TargetFlags(),
        ).extraRequiredLibraries.toSet(),
        librariesToClear: {'dart:mirrors'},
      ),
    ),
    zoneSpecification: ZoneSpecification(
      print: (self, parent, zone, line) => stderr.writeln(line),
    ),
  );
}
