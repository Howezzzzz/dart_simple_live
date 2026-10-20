import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/utils.dart';

void main() {
  group('Utils.formatVersion（minor/patch 恒两位，2026-10-20 Howe 定）', () {
    test('单位数段补零：1.8.24 → 1.08.24', () {
      expect(Utils.formatVersion('1.8.24'), '1.08.24');
    });

    test('进位后归零补零：1.9.99 进位 → 1.10.00（不跨点、两位演进）', () {
      // 模拟 CI bump 后 pubspec/Flutter 归一化形态：patch 归零时也要两位
      expect(Utils.formatVersion('1.10.0'), '1.10.00');
      expect(Utils.formatVersion('1.10.00'), '1.10.00');
    });

    test('minor 单位数补零、major 不补零', () {
      expect(Utils.formatVersion('1.9.0'), '1.09.00');
      expect(Utils.formatVersion('1.8.24').startsWith('1.'), isTrue);
      expect(Utils.formatVersion('1.8.24').startsWith('01.'), isFalse);
    });

    test('兼容带构建号输入', () {
      expect(Utils.formatVersion('1.8.24+10824'), '1.08.24+10824');
    });

    test('非法输入原样返回', () {
      expect(Utils.formatVersion('abc'), 'abc');
      expect(Utils.formatVersion('1.8'), '1.8');
      expect(Utils.formatVersion(''), '');
    });

    test('进位临界显示：1.9.99 → 1.09.99', () {
      expect(Utils.formatVersion('1.9.99'), '1.09.99');
    });

    test('与 CI version_num 公式的绝对契约（防两侧同时漂移）', () {
      // CI bump：NUM = major*10000 + minor*100 + patch；app 端 parseVersion 必须恒等
      expect(Utils.parseVersion('1.08.25'), 10825);
      expect(Utils.parseVersion('1.10.0'), 11000);
      expect(Utils.parseVersion('1.10.00'), 11000);
      expect(Utils.parseVersion('1.09.99'), 10999);
    });

    test('与 parseVersion 数值一致性：补零不改变比较结果', () {
      // 1.8.24 归一化前后 parseVersion 结果必须一致（app 端 checkUpdate 依赖）
      expect(Utils.parseVersion('1.8.24'), Utils.parseVersion('1.08.24'));
      expect(Utils.parseVersion('1.9.99'), Utils.parseVersion('1.09.99'));
      expect(Utils.parseVersion('1.10.00'), Utils.parseVersion('1.10.0'));
      // 演进链数值严格递增
      expect(Utils.parseVersion('1.08.25'), greaterThan(Utils.parseVersion('1.08.24')));
      expect(Utils.parseVersion('1.10.00'), greaterThan(Utils.parseVersion('1.09.99')));
    });
  });
}
