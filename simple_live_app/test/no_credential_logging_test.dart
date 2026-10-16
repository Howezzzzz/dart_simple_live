import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 回归守卫（RT-104 / ISS-存量-1）：源码不得把 Cookie/凭据内容写入日志（D3）。
///
/// 场景：B站扫码登录后曾 `CoreLog.i(cookieStr)` 直接把 SESSDATA 打进日志，
/// 日志可导出/上传 → 凭据泄露面。本测试静态扫描源码，命中即失败。
void main() {
  test('core/app 源码中不存在把 cookie 变量直接打印的日志语句', () {
    final roots = ['lib', '../simple_live_core/lib'];
    // 形如 CoreLog.i(cookieStr) / Log.d(cookie) / print(cookieStr) 的直打
    final pattern = RegExp(
        r'(CoreLog|Log|print)\s*[.(]\s*\w*(cookie|Cookie|credential|token|Token)\w*\s*[,)]');
    final hits = <String>[];
    for (final root in roots) {
      final dir = Directory(root);
      if (!dir.existsSync()) continue;
      for (final f in dir.listSync(recursive: true)) {
        if (f is! File || !f.path.endsWith('.dart')) continue;
        final lines = f.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          final line = lines[i];
          if (line.trimLeft().startsWith('//')) continue;
          if (pattern.hasMatch(line)) {
            hits.add('${f.path}:${i + 1}: ${line.trim()}');
          }
        }
      }
    }
    expect(hits, isEmpty, reason: '日志中疑似打印凭据内容：\n${hits.join('\n')}');
  });
}
