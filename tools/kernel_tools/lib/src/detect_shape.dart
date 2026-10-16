// 精简档资源覆盖层的形状检测器
//
// 输入一份 app-only 的 kernel，回答三件事：
//   1. 覆盖层能插在哪（runApp / runWidget 的调用点）
//   2. 哪些资源读绕过了覆盖层（业务代码里直接用 rootBundle）
//   3. 其中哪些确定发生在注入点之前（同一个函数体内、偏移更小）
//
// 判定：没有注入点 → 升整程序档；有注入点但有绕过 → 报告，由策略决定。
//
// 用法：
//   detect-shape --dill <app.dill> --own <pkg,...> [--exclude <substring,...>]

import 'package:kernel/kernel.dart';

const String _bindingLib = 'package:flutter/src/widgets/binding.dart';
const String _assetBundleLib = 'package:flutter/src/services/asset_bundle.dart';
const Set<String> _entryPoints = <String>{'runApp', 'runWidget'};

class Hit {
  Hit(this.kind, this.name, this.library, this.member, this.offset, this.loc);
  final String kind; // 'inject' | 'rootBundle'
  final String name;
  final String library;
  final String member;
  final int offset;
  final String loc;
}

class _Scan extends RecursiveVisitor {
  _Scan(this.ownPackages, this.component, this.excluded);
  final Set<String> ownPackages;
  final Component component;

  /// 插件提供的生成代码（覆盖层辅助库一类）。真实产品里它不属于自有包，
  /// 天然不会被扫到；测试夹具里它和业务代码同包，必须显式排掉，否则它自己那句
  /// `_overlay ?? rootBundle` 会被误报成业务代码绕过覆盖层。
  final List<String> excluded;

  final List<Hit> hits = <Hit>[];

  String _member = '<toplevel>';
  String _library = '';

  bool _owns(Library l) {
    final Uri u = l.importUri;
    if (u.scheme != 'package') return false;
    if (!ownPackages.contains(u.pathSegments.first)) return false;
    final String s = u.toString();
    return !excluded.any(s.contains);
  }

  String _where(TreeNode node) {
    final Location? l = node.location;
    return l == null
        ? '?'
        : '${l.file.pathSegments.last}:${l.line}:${l.column}';
  }

  @override
  void visitLibrary(Library node) {
    if (!_owns(node)) return;
    _library = node.importUri.toString();
    super.visitLibrary(node);
  }

  @override
  void visitProcedure(Procedure node) {
    _member = node.name.text;
    super.visitProcedure(node);
  }

  @override
  void visitConstructor(Constructor node) {
    _member = '${node.enclosingClass.name}.${node.name.text}';
    super.visitConstructor(node);
  }

  @override
  void visitField(Field node) {
    _member = node.name.text;
    super.visitField(node);
  }

  void _record(String kind, String name, TreeNode node) {
    hits.add(Hit(kind, name, _library, _member, node.fileOffset, _where(node)));
  }

  @override
  void visitStaticInvocation(StaticInvocation node) {
    final Member t = node.target;
    final String lib = t.enclosingLibrary.importUri.toString();
    if (lib == _bindingLib && _entryPoints.contains(t.name.text)) {
      _record('inject', t.name.text, node);
    } else if (lib == _assetBundleLib && t.name.text == 'rootBundle') {
      _record('rootBundle', 'rootBundle', node);
    }
    super.visitStaticInvocation(node);
  }

  @override
  void visitStaticGet(StaticGet node) {
    final Member t = node.target;
    if (t.enclosingLibrary.importUri.toString() == _assetBundleLib &&
        t.name.text == 'rootBundle') {
      _record('rootBundle', 'rootBundle', node);
    }
    super.visitStaticGet(node);
  }

  bool _isEntryPoint(Member t) =>
      t.enclosingLibrary.importUri.toString() == _bindingLib &&
      _entryPoints.contains(t.name.text);

  @override
  void visitStaticTearOff(StaticTearOff node) {
    // 撕下来当闭包传走了，静态上定位不到真正的调用点。
    if (_isEntryPoint(node.target))
      _record('teared', node.target.name.text, node);
    super.visitStaticTearOff(node);
  }

  /// CFE 会把顶层函数的撕取折叠成常量，`StaticTearOff` 节点根本不出现。
  /// 不跟常量图就会看不见 `launch(runApp)` 这种形状。
  @override
  void visitConstantExpression(ConstantExpression node) {
    _scanConstant(node.constant, node, <Constant>{});
    super.visitConstantExpression(node);
  }

  void _scanConstant(Constant c, TreeNode at, Set<Constant> seen) {
    if (!seen.add(c)) return;
    if (c is StaticTearOffConstant) {
      if (_isEntryPoint(c.target)) _record('teared', c.target.name.text, at);
      return;
    }
    if (c is InstantiationConstant)
      return _scanConstant(c.tearOffConstant, at, seen);
    if (c is ListConstant) {
      for (final Constant e in c.entries) {
        _scanConstant(e, at, seen);
      }
    } else if (c is SetConstant) {
      for (final Constant e in c.entries) {
        _scanConstant(e, at, seen);
      }
    } else if (c is MapConstant) {
      for (final ConstantMapEntry e in c.entries) {
        _scanConstant(e.key, at, seen);
        _scanConstant(e.value, at, seen);
      }
    } else if (c is InstanceConstant) {
      for (final Constant e in c.fieldValues.values) {
        _scanConstant(e, at, seen);
      }
    }
  }
}

Map<String, Object?> detectShape(Component component, Set<String> own,
    {List<String> excluded = const []}) {
  final scan = _Scan(own, component, excluded);
  component.accept(scan);
  final inject = scan.hits.where((h) => h.kind == 'inject').toList();
  final teared = scan.hits.where((h) => h.kind == 'teared').toList();
  final raw = scan.hits.where((h) => h.kind == 'rootBundle').toList();
  final before = <Hit>[];
  final unordered = <Hit>[];
  for (final r in raw) {
    final same =
        inject.where((i) => i.member == r.member && i.library == r.library);
    if (same.isNotEmpty && same.every((i) => r.offset < i.offset)) {
      before.add(r);
    } else {
      unordered.add(r);
    }
  }
  final verdict = inject.isEmpty || teared.isNotEmpty
      ? 'UPGRADE'
      : raw.isNotEmpty
          ? 'INJECTABLE_HOLE'
          : 'INJECTABLE';
  Map<String, Object?> encode(Hit h, [String? timing]) {
    final match = RegExp(r'^(.*):(\d+):(\d+)$').firstMatch(h.loc);
    return {
      'kind': h.kind,
      'name': h.name,
      'library': h.library,
      'member': h.member,
      'offset': h.offset,
      'file': match?.group(1),
      'line': match == null ? null : int.parse(match.group(2)!),
      'col': match == null ? null : int.parse(match.group(3)!),
      if (timing != null) 'timing': timing,
    };
  }

  return {
    'verdict': verdict,
    'injectionPoints': inject.map(encode).toList(),
    'bypasses': [
      for (final h in before) encode(h, 'before'),
      for (final h in unordered) encode(h, 'unordered')
    ],
    'tearOffs': teared.map(encode).toList(),
  };
}
