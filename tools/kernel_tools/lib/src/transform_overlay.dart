// 资源覆盖层的 kernel 变换
//
// 把每个注入点的第 0 个实参包一层：
//   runApp(X)  ->  runApp(DefaultAssetBundle(bundle: patcherOverlayBundle(), child: X))
//
// 变换后写盘再重新读回：能反序列化，说明产出的 kernel 是良构的。
//
// 用法：
//   transform-overlay --dill <input> --own <pkg,...> --out <output>
//                     --helper-lib <library-uri> --helper-fn <function>

import 'package:kernel/kernel.dart';

const String _bindingLib = 'package:flutter/src/widgets/binding.dart';
const String _bundleLib = 'package:flutter/src/widgets/basic.dart';
const Set<String> _entryPoints = <String>{'runApp', 'runWidget'};

Library _lib(Component c, String uri) => c.libraries.firstWhere(
  (Library l) => l.importUri.toString() == uri,
  orElse: () => throw 'library not in component: $uri',
);

class _Wrap extends RecursiveVisitor {
  _Wrap(this.ownPackages, this.ctor, this.helper);
  final Set<String> ownPackages;
  final Constructor ctor;
  final Procedure helper;
  int wrapped = 0;

  @override
  void visitLibrary(Library node) {
    final Uri u = node.importUri;
    if (u.scheme != 'package' || !ownPackages.contains(u.pathSegments.first)) {
      return;
    }
    super.visitLibrary(node);
  }

  @override
  void visitStaticInvocation(StaticInvocation node) {
    super.visitStaticInvocation(node);
    final Member t = node.target;
    if (t.enclosingLibrary.importUri.toString() != _bindingLib) return;
    if (!_entryPoints.contains(t.name.text)) return;
    if (node.arguments.positional.isEmpty) return;

    final Expression original = node.arguments.positional[0];
    final ConstructorInvocation wrap = ConstructorInvocation(
      ctor,
      Arguments(
        <Expression>[],
        named: <NamedExpression>[
          NamedExpression(
            'bundle',
            StaticInvocation(helper, Arguments(<Expression>[])),
          ),
          NamedExpression('child', original),
        ],
      ),
    )..fileOffset = node.fileOffset;
    node.arguments.positional[0] = wrap;
    wrap.parent = node.arguments;
    wrapped++;
  }
}

Future<Map<String, Object?>> transformOverlay(
  String input,
  String output,
  Set<String> own,
  String helperLibrary,
  String helperFunction,
) async {
  final component = loadComponentFromBinary(input);
  final result = transformOverlayComponent(
    component,
    own,
    helperLibrary,
    helperFunction,
  );
  await writeComponentToBinary(component, output);
  loadComponentFromBinary(output);
  return result;
}

Map<String, Object?> transformOverlayComponent(
  Component component,
  Set<String> own,
  String helperLibrary,
  String helperFunction,
) {
  final defaultAssetBundle = _lib(
    component,
    _bundleLib,
  ).classes.firstWhere((c) => c.name == 'DefaultAssetBundle');
  final ctor = defaultAssetBundle.constructors.firstWhere(
    (c) => c.name.text == '',
  );
  final helper = _lib(
    component,
    helperLibrary,
  ).procedures.firstWhere((p) => p.name.text == helperFunction);
  final visitor = _Wrap(own, ctor, helper);
  component.accept(visitor);
  return {'wrapped': visitor.wrapped};
}

Map<String, Object?> transformWholeOverlay(
  Component component,
  String helperLibrary,
) {
  final services = _lib(
    component,
    'package:flutter/src/services/asset_bundle.dart',
  );
  final root = services.fields.firstWhere((f) => f.name.text == 'rootBundle');
  final original = root.initializer;
  if (original == null) throw StateError('rootBundle initializer missing');
  final helper = _lib(
    component,
    helperLibrary,
  ).procedures.firstWhere((p) => p.name.text == 'patcherWholeBundle');
  final replacement = StaticInvocation(helper, Arguments([original]))
    ..fileOffset = original.fileOffset;
  root.initializer = replacement;
  replacement.parent = root;
  return {'root_bundle_replaced': true};
}
