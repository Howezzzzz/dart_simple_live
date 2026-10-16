import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/utils/grid_columns.dart';

/// RT-107：紧凑关注列表列数计算回归（2026-10-16「该在最左的主播跑到最右」排查修复）。
///
/// 背景：旧算法 `width ~/ 340`（floor）+ 瀑布流拉伸铺满 → 窗口宽略小于 (k+1)*340 时
/// 列宽被拉到接近 2*340（卡片超宽），且列数随窗口宽跳变触发整体重排（条目位置漂移）。
/// 新算法 ceil 封顶 + 最小列宽(260)夹逼，见 lib/app/utils/grid_columns.dart。
void main() {
  group('gridColumnsForWidth（RT-107）', () {
    test('桌面 1920 宽：ceil 得 6 列（列宽 320 ≤ 340）；旧 floor 为 5 列*384 拉伸超设计宽', () {
      expect(gridColumnsForWidth(1920), 6);
    });

    test('目标宽整倍数不跳变：1700 → 5 列（列宽恰 340）', () {
      expect(gridColumnsForWidth(1700), 5);
    });

    test('略超整倍数：1701 → 6 列（列宽 ~283.5，不再拉伸）', () {
      expect(gridColumnsForWidth(1701), 6);
    });

    test('小窗口 679：不再退化为 1 列*679 超宽卡，改 2 列*~339.5', () {
      expect(gridColumnsForWidth(679), 2);
    });

    test('手机竖屏保持 1 列（移动端行为不变）：360/390/430 → 1', () {
      expect(gridColumnsForWidth(360), 1);
      expect(gridColumnsForWidth(390), 1);
      expect(gridColumnsForWidth(430), 1);
    });

    test('平板与旧算法列数一致：768 → 2、1024 → 3', () {
      expect(gridColumnsForWidth(768), 2);
      expect(gridColumnsForWidth(1024), 3);
    });

    test('边界：340→1、341→1（受最小列宽夹逼）、520→2（列宽恰 260）、560→2', () {
      expect(gridColumnsForWidth(340), 1);
      expect(gridColumnsForWidth(341), 1);
      expect(gridColumnsForWidth(520), 2);
      expect(gridColumnsForWidth(560), 2);
    });

    test('异常输入兜底为 1：0 / 负数 / NaN / infinity', () {
      expect(gridColumnsForWidth(0), 1);
      expect(gridColumnsForWidth(-100), 1);
      expect(gridColumnsForWidth(double.nan), 1);
      expect(gridColumnsForWidth(double.infinity), 1);
    });

    test('不变式①：任意输入列数 ≥ 1，且 ≥ 旧 floor 算法（卡片只会更窄不会更宽）', () {
      for (var w = 1.0; w <= 4000; w += 3.7) {
        final n = gridColumnsForWidth(w);
        expect(n, greaterThanOrEqualTo(1), reason: 'width=$w');
        final old = (w ~/ 340) < 1 ? 1 : (w ~/ 340);
        expect(n, greaterThanOrEqualTo(old), reason: 'width=$w n=$n old=$old');
      }
    });

    test('不变式②：width ≥ 560 时列宽落在 [260, 390]（正常 ≤340，夹逼回退带最多 ~390）', () {
      for (var w = 560.0; w <= 4000; w += 7.3) {
        final n = gridColumnsForWidth(w);
        final col = w / n;
        expect(col, inInclusiveRange(260, 390), reason: 'width=$w n=$n col=$col');
      }
    });
  });
}
