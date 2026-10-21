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

  // 2026-10-21 Howe 定：卡片样式改用与紧凑同一算法（target 200 / min 180 + 上限 10）。
  group('卡片样式列数（与紧凑同口径 + 上限 10）', () {
    int card(double w) => gridColumnsForWidth(w, targetColumnWidth: 200, minColumnWidth: 180, maxColumns: 10);

    test('常用桌面宽：1280→7、1920→10', () {
      expect(card(1280), 7);
      expect(card(1920), 10);
    });

    test('超宽屏封顶 10 列：2560 / 3840 → 10', () {
      expect(card(2560), 10);
      expect(card(3840), 10);
    });

    test('窄屏/平板：390→2、768→4、800→4', () {
      expect(card(390), 2);
      expect(card(768), 4);
      expect(card(800), 4);
    });

    test('不变式：列数恒在 [1, 10]', () {
      for (var w = 200.0; w <= 5000; w += 13.7) {
        final n = card(w);
        expect(n, greaterThanOrEqualTo(1), reason: 'width=$w');
        expect(n, lessThanOrEqualTo(10), reason: 'width=$w');
      }
    });

    test('边界：异常输入统一返回 1（卡片参数）', () {
      expect(card(0), 1);
      expect(card(-100), 1);
      expect(card(double.nan), 1);
      expect(card(double.infinity), 1);
    });

    test('maxColumns 缺省（0）= 不封顶：4400 宽应超过 10 列', () {
      // 3840 时 ceil(3840/400)=10，本就到不了 >10，故取 4400（ceil=11）
      expect(gridColumnsForWidth(4400), greaterThan(10));
      // 同宽带 maxColumns:10 时应被封顶 —— 反证「封顶只在传参时生效」契约
      expect(card(4400), 10);
    });
  });
}
