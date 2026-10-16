import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/utils/grid_columns.dart';

/// RT-107：紧凑关注列表列数计算回归。
/// 目标列宽 400（2026-10-16 由 340 调宽：Howe 反馈 340 时列偏窄、长主播名被截断）。
void main() {
  group('gridColumnsForWidth（RT-107）', () {
    test('桌面 1920 宽：5 列 × 384（旧 340 目标为 6 列 × 320，偏窄）', () {
      expect(gridColumnsForWidth(1920), 5);
    });

    test('目标宽整倍数不跳变：1536 → 4 列（列宽恰 384）', () {
      expect(gridColumnsForWidth(1536), 4);
    });

    test('常用宽度：1440→4、1366→4、1280→4、1152→3、1024→3', () {
      expect(gridColumnsForWidth(1440), 4);
      expect(gridColumnsForWidth(1366), 4);
      expect(gridColumnsForWidth(1280), 4);
      expect(gridColumnsForWidth(1152), 3);
      expect(gridColumnsForWidth(1024), 3);
    });

    test('手机竖屏保持 1 列（移动端行为不变）：360/390/430 → 1', () {
      expect(gridColumnsForWidth(360), 1);
      expect(gridColumnsForWidth(390), 1);
      expect(gridColumnsForWidth(430), 1);
    });

    test('平板：768 → 2 列（列宽 384）', () {
      expect(gridColumnsForWidth(768), 2);
    });

    test('小窗口：679 → 2、520 → 2', () {
      expect(gridColumnsForWidth(679), 2);
      expect(gridColumnsForWidth(520), 2);
    });

    test('边界：340/341/400/401 → 1（不足两列时单列）', () {
      expect(gridColumnsForWidth(340), 1);
      expect(gridColumnsForWidth(341), 1);
      expect(gridColumnsForWidth(400), 1);
      expect(gridColumnsForWidth(401), 1);
    });

    test('异常输入兜底为 1：0 / 负数 / NaN / infinity', () {
      expect(gridColumnsForWidth(0), 1);
      expect(gridColumnsForWidth(-100), 1);
      expect(gridColumnsForWidth(double.nan), 1);
      expect(gridColumnsForWidth(double.infinity), 1);
    });

    test('不变式：宽 ≥ 560 时列宽恒在 [260, 400]（不拉伸、也不过窄）', () {
      for (var w = 560.0; w <= 4000; w += 7.3) {
        final n = gridColumnsForWidth(w);
        expect(n, greaterThanOrEqualTo(1), reason: 'width=$w');
        final col = w / n;
        expect(col, inInclusiveRange(260, 400), reason: 'width=$w n=$n col=$col');
      }
    });
  });
}
