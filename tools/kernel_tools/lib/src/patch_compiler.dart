import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
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
import 'package:yaml/yaml.dart';
import 'package:_fe_analyzer_shared/src/messages/diagnostic_message.dart'
    show getMessageCharOffset;
import 'patch_checks.dart';

const patchUsage =
    '  compile-patch --request <json>   (optional filesystem_scheme + filesystem_roots, environment_defines)\n';

Future<Map<String, Object?>> compilePatch(List<String> args) async {
  if (args.length != 2 || args.first != '--request')
    throw FormatException('Use $patchUsage');
  final req =
      jsonDecode(await File(args[1]).readAsString()) as Map<String, dynamic>;
  String value(String key) => req[key] as String;
  final tier = value('tier');
  if (!['lean', 'whole'].contains(tier)) throw FormatException('Invalid tier');
  // The tiers differ only in which packages the CLI renamed into the module
  // (`own`): lean the application, whole also every package not pinned to
  // the host. target_os is still validated for older CLIs that send it.
  final targetOS = req['target_os'] as String?;
  if (targetOS != null && !['android', 'ios'].contains(targetOS))
    throw FormatException('Invalid target_os');
  final emit = req['emit'] == true;
  // A multi-root file system makes module sources record virtual URIs, not
  // this run's work path: patches become reproducible and ship no local paths.
  // `packages` is then a URI under the scheme.
  final scheme = req['filesystem_scheme'] as String?;
  final roots = (req['filesystem_roots'] as List?)?.cast<String>();
  if ((scheme == null) != (roots == null))
    throw FormatException('filesystem_scheme and filesystem_roots go together');
  // The host release's compile-time environment (dart.vm.product, flavor):
  // without it kReleaseMode and fromEnvironment constants in the module
  // evaluate as in a debug build.
  final defines = (req['environment_defines'] as Map?)?.cast<String, String>();
  final diagnostics = <Map<String, Object?>>[];
  final options = CompilerOptions()
    ..sdkSummary = File(value('platform')).absolute.uri
    ..fileSystem = createFrontEndFileSystem(scheme, [
      for (final root in roots ?? const <String>[])
        Directory(root).absolute.uri.toString(),
    ])
    ..additionalDillModules = [
      // Both tiers link the host: whole carries more packages, never Flutter
      // or the packages pinned to the host (FFI, plugins, build hooks and
      // everything they depend on).
      File(value('baseline')).absolute.uri,
    ]
    ..packagesFileUri = scheme == null
        ? File(value('packages')).absolute.uri
        : Uri.parse(value('packages'))
    ..dynamicInterfaceSpecificationUri = File(value('interface')).absolute.uri
    // Real applications index decoded JSON (`response['code']`). The host
    // interface lists as dynamically-callable every host member such a call
    // could reach; selectors no host class declares are allowed below.
    ..allowDynamicCallsInDynamicModules = true
    ..dynamicCallsSelectorAllowList = [
      '-',
      '+',
      '*',
      'get:index',
      'relativeError',
      'absoluteError',
    ]
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
      // Here, not on the options: compileToKernel replaces the options'
      // defines with these.
      environmentDefines: {...?defines},
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
  final loadedLibraries = result.loadedLibraries.toSet();
  Map<String, dynamic>? frameworkReuse;
  final reuseRequest = req['framework_reuse'];
  if (reuseRequest is Map && reuseRequest['enabled'] == true) {
    final partitionPath = reuseRequest['partition'];
    final carried = reuseRequest['carried'];
    final packageName = reuseRequest['carry_package'];
    if (partitionPath is! String ||
        carried is! List ||
        packageName is! String ||
        packageName.isEmpty) {
      throw const FormatException('Invalid framework reuse request');
    }
    final partition = loadYaml(await File(partitionPath).readAsString());
    if (partition is! Map ||
        partition['schema'] != 1 ||
        partition['carry'] is! List ||
        !Set<String>.from(
          partition['carry'] as List,
        ).containsAll((carried as List).whereType<String>())) {
      throw const FormatException('Framework partition does not match request');
    }
    final requested = carried.cast<String>().toSet();
    // Every original package:flutter library is host supplied, including the
    // ones whose copies are carried: the carry copies live under the carry
    // package and the barrel shims hide the originals, so an original that
    // stayed in the module would only duplicate its carried copy. Originals
    // stay in the component for name resolution and resolve through the
    // validated dynamic interface.
    for (final library in component.libraries) {
      if ('${library.importUri}'.startsWith('package:flutter/')) {
        loadedLibraries.add(library);
      }
    }
    frameworkReuse = {
      'enabled': true,
      'partition_sha256': sha256
          .convert(await File(partitionPath).readAsBytes())
          .toString(),
      'carried': requested.toList()..sort(),
      'carry_package': packageName,
    };
  }
  final module = component.libraries
      .where((l) => !loadedLibraries.contains(l))
      .toList();
  // A dynamic call whose selector no host class declares can only reach the
  // module's own (interpreted) classes or a closure (`call`); on anything else
  // it throws NoSuchMethodError exactly as the unpatched code would. Only a
  // selector the host declares but has not made dynamically invocable is a
  // risk, and that stays rejected. The baseline's copy of the application is
  // not a host: the module replaces it.
  final replaced = (req['original_own'] as List? ?? []).cast<String>().toSet();
  final hostNames = <String>{
    for (final lib in loadedLibraries)
      if (lib.importUri.scheme != 'package' ||
          !replaced.contains(lib.importUri.pathSegments.first))
        for (final cls in lib.classes)
          for (final m in cls.members)
            if (m.isInstanceMember) m.name.text,
  }..remove('call');
  diagnostics.removeWhere((d) {
    if (d['code'] != 'DynamicCallsAreNotAllowedInDynamicModule') return false;
    final selector = RegExp(
      r"selector '([^']+)'",
    ).firstMatch(d['message'] as String)?.group(1);
    if (selector == null) return false;
    return !hostNames.contains(selector.replaceFirst(RegExp('^[gs]et:'), ''));
  });
  // CFE has no character offset for an implicit super() call. Recover its
  // enclosing declaration from the same Kernel only when the match is unique.
  for (final diagnostic in diagnostics) {
    if (diagnostic['line'] != null ||
        diagnostic['code'] !=
            'ConstructorShouldBeListedAsCallableInDynamicInterface')
      continue;
    final name = RegExp(
      r"Cannot invoke constructor '([^']+)'",
    ).firstMatch(diagnostic['message'] as String)?.group(1);
    final candidates = <Map<String, Object?>>[];
    for (final lib in module) {
      for (final cls in lib.classes) {
        for (final constructor in cls.constructors) {
          for (final initializer in constructor.initializers) {
            if (initializer is! SuperInitializer) continue;
            final target = initializer.target;
            final targetName =
                target.enclosingClass.name +
                (target.name.text.isEmpty ? '' : '.${target.name.text}');
            final location = site(initializer, '', '');
            if (targetName == name &&
                location['file'] == diagnostic['file'] &&
                location['line'] != null)
              candidates.add(location);
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
    loadedLibraries,
    (allocationData['classes'] as List).cast<String>().toSet(),
  );
  for (final lib in module) {
    lib.accept(checker);
  }
  // Icons the module shares the host's icon fonts with. The host ships
  // them tree-shaken to these code points; a patch font replaces the host's
  // family, so it must keep them (or need not ship at all).
  final hostIcons = <String, Map<String, Object?>>{};
  {
    final scan = AllocationCheck(<Library>{}, <String>{});
    for (final lib in loadedLibraries) {
      if (lib.importUri.scheme != 'dart') lib.accept(scan);
    }
    for (final icon in scan.fonts) {
      final row = {
        'fontFamily': icon['fontFamily'],
        'fontPackage': icon['fontPackage'],
        'codePoint': icon['codePoint'],
      };
      hostIcons[jsonEncode(row)] = row;
    }
  }
  final inherited = inheritedCheck(
    component,
    result.classHierarchy!,
    loadedLibraries,
    module,
    await File(value('interface')).readAsString(),
    await File(value('compiler_interface')).readAsString(),
  );
  final ffi = FfiCheck();
  for (final lib in module) {
    lib.accept(ffi);
  }
  final checks = <String, Object?>{
    'interface': diagnostics,
    'allocation': checker.issues,
    'inherited': inherited,
    'ffi': ffi.issues,
  };
  final report = <String, Object?>{
    'tier': tier,
    'checks': checks,
    'fonts': checker.fonts,
    'dynamic_fonts': checker.dynamicFonts,
    'host_icons': [
      for (final key in hostIcons.keys.toList()..sort()) hostIcons[key],
    ],
    'module_libraries': module.map((l) => l.importUri.toString()).toList(),
    if (frameworkReuse != null) 'framework_reuse': frameworkReuse,
  };
  if (req['kernel_out'] is String)
    await writeComponentToBinary(component, req['kernel_out'] as String);
  if (diagnostics.isNotEmpty ||
      checker.issues.isNotEmpty ||
      inherited.isNotEmpty ||
      ffi.issues.isNotEmpty) {
    return {'status': 'rejected', ...report};
  }
  final slots = checkEntry(
    module,
    req['seq'] as int,
    value('fingerprint'),
    tier,
  );
  // Background engines start and call back entry points by name; the
  // patcher hook runs the patch's version from this table.
  final entries = entryPoints(module, slots);
  report['entries'] = entries.keys.toList()..sort();
  if (!emit) return {'status': 'checked', ...report};
  installEntryTable(slots, entries, CoreTypes(component));
  // Prefix all newly compiled libraries.
  // User/new dependency package names were remapped before resolution.
  final uriPrefix = 'package:patch.${req['seq']}.';
  for (final lib in module) {
    if (lib.importUri.toString() == 'dart:mixin_deduplication') {
      final replacement = Uri.parse(
        '${uriPrefix}__vm/mixin_deduplication.dart',
      );
      if (component.libraries.any((other) => other.importUri == replacement)) {
        throw StateError('Generated mixin library URI collision');
      }
      lib.importUri = replacement;
    }
  }
  prefix.prefixLibraryUris(component, {
    ...loadedLibraries,
    ...module.where((l) => l.importUri.toString().startsWith(uriPrefix)),
  }, 'patch/${req['seq']}');
  final libraries = module.map((l) => l.importUri.toString()).toList();
  if (libraries.isEmpty || libraries.any((u) => !u.startsWith(uriPrefix))) {
    throw StateError(
      'Unprefixed module library: ${libraries.where((u) => !u.startsWith(uriPrefix)).join(', ')}',
    );
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
      extraLoadedLibraries: loadedLibraries,
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
