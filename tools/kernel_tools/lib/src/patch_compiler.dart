import 'dart:convert';
import 'dart:io';
import 'package:front_end/src/api_unstable/vm.dart';
import 'package:vm/kernel_front_end.dart';
import 'package:vm/transformations/prefix_library_uris.dart' as prefix;
import 'package:dart2bytecode/bytecode_generator.dart';
import 'package:dart2bytecode/options.dart';
import 'package:dart2bytecode/bytecode_serialization.dart';
import 'package:dart2bytecode/declarations.dart' as bc;
import 'package:kernel/kernel.dart';
import 'package:kernel/class_hierarchy.dart';
import 'package:kernel/core_types.dart';
import 'package:_fe_analyzer_shared/src/messages/diagnostic_message.dart'
    show getMessageCharOffset;
import 'patch_checks.dart';
import 'detect_shape.dart';

const patchUsage = '  compile-patch --request <json>\n';

Future<Map<String, Object?>> compilePatch(List<String> args) async {
  if (args.length != 2 || args.first != '--request')
    throw FormatException('Use $patchUsage');
  final req =
      jsonDecode(await File(args[1]).readAsString()) as Map<String, dynamic>;
  String value(String key) => req[key] as String;
  final tier = value('tier');
  if (!['lean', 'whole'].contains(tier)) throw FormatException('Invalid tier');
  final emit = req['emit'] == true;
  final diagnostics = <Map<String, Object?>>[];
  final options = CompilerOptions()
    ..sdkSummary = File(value('platform')).absolute.uri
    ..fileSystem = createFrontEndFileSystem(null, null)
    ..additionalDillModules = [
      if (tier == 'lean') File(value('baseline')).absolute.uri,
    ]
    ..packagesFileUri = File(value('packages')).absolute.uri
    ..dynamicInterfaceSpecificationUri = File(value('interface')).absolute.uri
    ..allowDynamicCallsInDynamicModules = tier == 'whole'
    ..dynamicCallsSelectorAllowList = tier == 'whole'
        ? ['-', '+', '*', 'get:index', 'relativeError', 'absoluteError']
        : []
    ..embedSourceText = true
    ..onDiagnostic = (m) {
      if (!m.severity.toString().endsWith('.error')) return;
      final uri = getMessageUri(m), offset = getMessageCharOffset(m);
      int? line, column;
      if (uri?.scheme == 'file' &&
          offset != null &&
          offset >= 0 &&
          File.fromUri(uri!).existsSync()) {
        final text = File.fromUri(uri).readAsStringSync();
        final before = text.substring(0, offset.clamp(0, text.length));
        line = '\n'.allMatches(before).length + 1;
        column = before.length - before.lastIndexOf('\n');
      }
      diagnostics.add({
        'code': m.codeName,
        'message': m.plainTextFormatted.join('\n'),
        'file': uri?.toString(),
        'line': line,
        'column': column,
      });
    }
    ..target = createFrontEndTarget(
      'flutter',
      trackCreationLocations: false,
      supportMirrors: false,
      isClosureContextLoweringEnabled: false,
    );
  final result = await compileToKernel(
    KernelCompilationArguments(
      source: Uri.parse(value('entry')),
      options: options,
      requireMain: false,
      includePlatform: false,
      aot: false,
      useGlobalTypeFlowAnalysis: false,
    ),
  );
  final component = result.component;
  if (component == null ||
      diagnostics.any(
        (d) => !RegExp(
          r'DynamicInterface|DynamicModule|DynamicCalls|DynamicallyCallable',
          caseSensitive: false,
        ).hasMatch('${d['code']}'),
      ))
    return {'status': 'compile_failed', 'diagnostics': diagnostics};
  final module = component.libraries
      .where((l) => !result.loadedLibraries.contains(l))
      .toList();
  // CFE has no character offset for an implicit super() call. Recover its
  // enclosing declaration from the same Kernel only when the match is unique.
  for (final diagnostic in diagnostics) {
    if (diagnostic['line'] != null ||
        diagnostic['code'] != 'ConstructorShouldBeListedAsCallableInDynamicInterface') continue;
    final name = RegExp(r"Cannot invoke constructor '([^']+)'")
        .firstMatch(diagnostic['message'] as String)?.group(1);
    final candidates = <Map<String, Object?>>[];
    for (final lib in module) {
      for (final cls in lib.classes) {
        for (final constructor in cls.constructors) {
          for (final initializer in constructor.initializers) {
            if (initializer is! SuperInitializer) continue;
            final target = initializer.target;
            final targetName = target.enclosingClass.name +
                (target.name.text.isEmpty ? '' : '.${target.name.text}');
            final location = site(initializer, '', '');
            if (targetName == name && location['file'] == diagnostic['file'] &&
                location['line'] != null) candidates.add(location);
          }
        }
      }
    }
    if (candidates.length == 1) {
      diagnostic['line'] = candidates.single['line'];
      diagnostic['column'] = candidates.single['column'];
      diagnostic['location_kind'] = 'implicit-super-declaration';
    }
  }
  final originalOwn = (req['original_own'] as List? ?? [])
      .cast<String>()
      .toSet();
  for (final lib in module) {
    for (final dependency in lib.dependencies) {
      final uri = dependency.targetLibrary.importUri;
      if (uri.scheme == 'package' &&
          originalOwn.contains(uri.pathSegments.first)) {
        throw StateError(
          'Module still imports the original application package: $uri',
        );
      }
    }
  }
  final allocationData =
      jsonDecode(await File(value('allocated')).readAsString()) as Map;
  final checker = AllocationCheck(
    result.loadedLibraries,
    (allocationData['classes'] as List).cast<String>().toSet(),
  );
  for (final lib in module) {
    lib.accept(checker);
  }
  final inherited = tier == 'whole'
      ? <Map<String, Object?>>[]
      : inheritedCheck(
          component,
          result.classHierarchy!,
          result.loadedLibraries,
          module,
          await File(value('interface')).readAsString(),
          await File(value('compiler_interface')).readAsString(),
        );
  final checks = <String, Object?>{
    'interface': diagnostics,
    'allocation': checker.issues,
    'inherited': inherited,
    'resources': <Object>[],
  };
  // Resource installation is supplied by WP-7; always report shape before gating.
  if (req['resources'] == true) {
    final shape = detectShape(
      component,
      (req['own'] as List).cast<String>().toSet(),
      excluded: ['__patch_entry.dart'],
    );
    checks['resources'] = shape;
  }
  final report = <String, Object?>{
    'tier': tier,
    'checks': checks,
    'fonts': checker.fonts,
    'module_libraries': module.map((l) => l.importUri.toString()).toList(),
  };
  if (req['kernel_out'] is String)
    await writeComponentToBinary(component, req['kernel_out'] as String);
  if (diagnostics.isNotEmpty ||
      (tier == 'lean' && (checker.issues.isNotEmpty || inherited.isNotEmpty))) {
    return {'status': 'rejected', ...report};
  }
  checkEntry(module, req['seq'] as int, value('fingerprint'), tier);
  if (tier == 'whole') {
    // TFA must not trim the externally supplied platform. The generator looks
    // up platform intrinsics (e.g. dart:developer.debugger) even when unused.
    // These are analysis-only keep-alive roots, not additions to the validated
    // host interface, and loaded libraries are never emitted in the module.
    final core = result.coreTypes!;
    void keep(Annotatable node) => node.addAnnotation(
      ConstantExpression(
        InstanceConstant(core.pragmaClass.reference, [], {
          core.pragmaName.fieldReference: StringConstant('vm:entry-point'),
          core.pragmaOptions.fieldReference: BoolConstant(true),
        }),
      ),
    );
    for (final lib in result.loadedLibraries) {
      for (final member in lib.members) keep(member);
      for (final cls in lib.classes) {
        keep(cls);
        for (final member in cls.members) keep(member);
      }
    }
    await runGlobalTransformations(
      options.target!,
      component,
      ErrorDetector(),
      KernelCompilationArguments(
        source: Uri.parse(value('entry')),
        options: options,
        requireMain: false,
        includePlatform: false,
        aot: true,
        useGlobalTypeFlowAnalysis: true,
        treeShakeWriteOnlyFields: false,
        dynamicInterface: File(value('interface')).absolute.uri,
      ),
    );
    module
      ..clear()
      ..addAll(
        component.libraries.where((l) => !result.loadedLibraries.contains(l)),
      );
    checkEntry(module, req['seq'] as int, value('fingerprint'), tier);
    final after = AllocationCheck(
      result.loadedLibraries,
      (allocationData['classes'] as List).cast<String>().toSet(),
    );
    for (final lib in module) lib.accept(after);
    checks['allocation'] = after.issues;
    report['fonts'] = after.fonts;
    report['module_libraries'] = module
        .map((l) => l.importUri.toString())
        .toList();
    if (after.issues.isNotEmpty)
      return {
        'status': 'rejected',
        ...report,
        'post_tfa_allocation': after.issues,
      };
  }
  if (!emit) return {'status': 'checked', ...report};
  // Prefix all newly compiled libraries (including the whole-tier framework).
  // User/new dependency package names were remapped before resolution.
  final uriPrefix = 'package:patch.${req['seq']}.';
  prefix.prefixLibraryUris(component, {
    ...result.loadedLibraries,
    ...module.where((l) => l.importUri.toString().startsWith(uriPrefix)),
  }, 'patch/${req['seq']}');
  final libraries = module.map((l) => l.importUri.toString()).toList();
  if (libraries.isEmpty || libraries.any((u) => !u.startsWith(uriPrefix))) {
    throw StateError('Unprefixed module library');
  }
  final output = File(value('out'));
  final sink = output.openWrite();
  try {
    final core = CoreTypes(component);
    generateBytecode(
      component,
      sink,
      libraries: module,
      hierarchy: ClassHierarchy(component, core),
      coreTypes: core,
      options: BytecodeOptions(emitSourcePositions: false),
      target: options.target!,
      extraLoadedLibraries: result.loadedLibraries,
    );
  } finally {
    await sink.close();
  }
  final decoded = bc.Component.read(
    BufferedReader(LinkReader(), await output.readAsBytes()),
  );
  // The pinned reader exposes URI constants through a private handle class;
  // inspect its string value, not its quoted debug representation.
  final actual = decoded.libraries
      .map((l) => (l.importUri as dynamic).value as String)
      .toList();
  if (decoded.dynModuleEntryPoint == null ||
      actual.length != libraries.length ||
      !actual.toSet().containsAll(libraries) ||
      actual.any((uri) => !uri.startsWith(uriPrefix)) ||
      decoded.sourcePositions.isNotEmpty) {
    throw StateError('Emitted bytecode structure differs');
  }
  return {
    'status': 'compiled',
    ...report,
    'emitted_libraries': libraries,
    'bytes': await output.length(),
  };
}
