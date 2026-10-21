import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/utils/panel_width.dart';

/// RT-108：右侧消息面板宽度计算回归。
///
/// 历史缺陷（2026-10-17 Howe 反馈）：自适应算出的面板宽度 < 220 时旧实现直接
/// 放弃调整、面板保持上一次的值（窗口偏窄时画面留黑边且不再自适应）。现改为
/// 始终夹逼到 [180, 800]：不足下限则设为下限。下限也由 220 下调到 180。
void main() {
  group('panelWidthForVideo（RT-108）', () {
    // 统一用 16:9、播放区高 540 的常见桌面场景：播放区应有宽 = 540 * 16/9 = 960
    const vw = 1920.0;
    const vh = 1080.0;
    const ph = 540.0;

    test('窗口足够宽：按比例算出的期望宽度（1600 → 632）', () {
      expect(
        panelWidthForVideo(
          contentWidth: 1600,
          videoWidth: vw,
          videoHeight: vh,
          playerHeight: ph,
        ),
        closeTo(632, 1e-9),
      );
    });

    test('回归主用例：期望宽度低于下限（32）→ 取下限 180，而不是保持旧值不动', () {
      // 旧实现此处会 return、面板停在旧值；新实现必须给到下限 180
      expect(
        panelWidthForVideo(
          contentWidth: 1000,
          videoWidth: vw,
          videoHeight: vh,
          playerHeight: ph,
        ),
        180.0,
      );
    });

    test('期望宽度为负（窗口比播放区还窄）→ 仍取下限 180', () {
      expect(
        panelWidthForVideo(
          contentWidth: 600,
          videoWidth: vw,
          videoHeight: vh,
          playerHeight: ph,
        ),
        180.0,
      );
    });

    test('窗口很宽、期望宽度超上限 → 取上限 800', () {
      expect(
        panelWidthForVideo(
          contentWidth: 2100,
          videoWidth: vw,
          videoHeight: vh,
          playerHeight: ph,
        ),
        800.0,
      );
    });

    test('边界：恰好下限 180 与恰好上限 800 不越界', () {
      expect(
        panelWidthForVideo(
          contentWidth: 1148, // 1148 - 960 - 8 = 180
          videoWidth: vw,
          videoHeight: vh,
          playerHeight: ph,
        ),
        180.0,
      );
      expect(
        panelWidthForVideo(
          contentWidth: 1768, // 1768 - 960 - 8 = 800
          videoWidth: vw,
          videoHeight: vh,
          playerHeight: ph,
        ),
        800.0,
      );
    });

    test('竖屏直播（1080x1920）：按比例正常计算（488.25）', () {
      expect(
        panelWidthForVideo(
          contentWidth: 800,
          videoWidth: 1080,
          videoHeight: 1920,
          playerHeight: 540, // 应有宽 540 * 1080/1920 = 303.75
        ),
        closeTo(488.25, 1e-9),
      );
    });

    test('非法/未就绪输入一律回落到下限，不抛异常', () {
      expect(
        panelWidthForVideo(contentWidth: double.nan, videoWidth: vw, videoHeight: vh, playerHeight: ph),
        180.0,
      );
      expect(
        panelWidthForVideo(contentWidth: 1600, videoWidth: 0, videoHeight: vh, playerHeight: ph),
        180.0,
      );
      expect(
        panelWidthForVideo(contentWidth: 1600, videoWidth: vw, videoHeight: 0, playerHeight: ph),
        180.0,
      );
      expect(
        panelWidthForVideo(contentWidth: 1600, videoWidth: vw, videoHeight: vh, playerHeight: 0),
        180.0,
      );
      expect(
        panelWidthForVideo(contentWidth: double.infinity, videoWidth: vw, videoHeight: vh, playerHeight: ph),
        180.0,
      );
    });

    test('不变式：任意宽度下结果恒落在 [180, 800]', () {
      for (var w = 0.0; w <= 3000; w += 25) {
        final v = panelWidthForVideo(
          contentWidth: w,
          videoWidth: vw,
          videoHeight: vh,
          playerHeight: ph,
        );
        expect(v, greaterThanOrEqualTo(kMessagePanelMinWidth));
        expect(v, lessThanOrEqualTo(kMessagePanelMaxWidth));
      }
    });
  });

  // panelNeedsOverlay 已于 2026-10-21 移除（其「意图宽放不下即覆盖式」语义与现行规则矛盾：
  // 现行 = 面板宽 ≥180 且窗口放得下 180 即分栏，渲染宽夹到 avail；该函数此前已无生产引用）。

  group('computePanelLayout（单帧派生：判定与渲染同源，2026-10-21 rev.5）', () {
    PanelLayout lay({
      double cw = 1706,
      double ph = 850,
      double vw = 1920,
      double vh = 1080,
      double manual = 300,
      bool auto = true,
      bool active = false,
      int scale = 0,
      double aspectByUser = 0,
      double handle = 8,
    }) =>
        computePanelLayout(
          contentWidth: cw,
          playerHeight: ph,
          videoWidth: vw,
          videoHeight: vh,
          manualWidth: manual,
          autoMode: auto,
          overlayActive: active,
          scaleMode: scale,
          aspectByUser: aspectByUser,
          handleWidth: handle,
        );

    test('守卫：窗口/尺寸非法 → 一律覆盖式，不产生 NaN', () {
      for (final cw in [double.nan, double.infinity, 0.0, -100.0]) {
        final r = lay(cw: cw);
        expect(r.overlay, isTrue);
        expect(r.renderW.isFinite, isTrue);
      }
      final r2 = lay(manual: double.nan); // NaN → 按默认 300 处理；avail≈195 ≥ 180 → 分栏（渲染夹到 avail）
      expect(r2.overlay, isFalse);
      expect(r2.renderW.isFinite, isTrue);
      expect(r2.renderW, closeTo(lay().available, 0.05));
      final r3 = lay(aspectByUser: double.nan, scale: 5);
      expect(r3.renderW.isFinite, isTrue);
    });

    test('conservative 兜底：视频尺寸未就绪时尊重「0=收起」', () {
      final collapsed = lay(vw: 0, vh: 0, manual: 0);
      expect(collapsed.overlay, isTrue, reason: '手动 0 在未就绪时也必须收起');
      final normal = lay(vw: 0, vh: 0, manual: 300, cw: 1706);
      expect(normal.overlay, isFalse);
      expect(normal.renderW, lessThanOrEqualTo(1706 + 0.001));
    });

    test('数值：1706×850 + 16:9 + 手动 300 → 分栏（意图宽放不下时渲染夹到 avail≈195；Howe 2026-10-21）', () {
      final r = lay();
      expect(r.available, closeTo(194.89, 0.05));
      expect(r.overlay, isFalse);
      expect(r.renderW, closeTo(194.89, 0.05)); // auto → avail
      final m = lay(auto: false);
      expect(m.overlay, isFalse);
      expect(m.renderW, closeTo(194.89, 0.05)); // 手动 300 也夹到 avail，不溢出
    });

    test('数值：手动 180 时 available≥180 → 分栏，且 renderW ≤ available', () {
      final r = lay(manual: 180);
      expect(r.overlay, isFalse);
      expect(r.renderW, greaterThanOrEqualTo(180));
      expect(r.renderW, lessThanOrEqualTo(r.available + 0.001));
    });

    test('数值：2200×850 + 16:9 → available≈681，手动 300 分栏（auto 用 681、手动模式用 300）', () {
      final a = lay(cw: 2200);
      expect(a.available, closeTo(688.89, 0.05));
      expect(a.overlay, isFalse);
      expect(a.renderW, closeTo(688.89, 0.05));
      final m = lay(cw: 2200, auto: false);
      expect(m.renderW, closeTo(300, 0.001));
    });

    test('手动 0 = 收起；手动 1~179 也是覆盖式', () {
      expect(lay(manual: 0).overlay, isTrue);
      expect(lay(manual: 179).overlay, isTrue);
      expect(lay(manual: 180).overlay, isFalse);
    });

    test('滞回：已在覆盖式时，需 avail ≥ 180+24=204 才退出（no-room 边界防闪烁）', () {
      // avail = cw - 850*16/9；cw=1710 → 198.9 ∈ [180,204) → 保持覆盖；cw=1730 → 218.9 ≥ 204 → 退出
      final stay = lay(cw: 1710, active: true);
      final leave = lay(cw: 1730, active: true);
      expect(stay.available, closeTo(198.89, 0.05));
      expect(stay.overlay, isTrue);
      expect(leave.available, greaterThanOrEqualTo(180 + 24 - 0.001));
      expect(leave.overlay, isFalse);
    });

    test('fill/cover：不因比例折叠，available = 窗口宽−手柄−最小播放宽', () {
      final r = lay(scale: 1);
      expect(r.available, closeTo(1466.00, 0.001));
      expect(r.overlay, isFalse);
    });

    test('强制比例/自定义比例生效；自定义非法则退回视频比例', () {
      final r169 = lay(scale: 3, ph: 900, cw: 2000);
      expect(r169.available, closeTo(400.00, 0.05));
      final rBad = lay(scale: 5, aspectByUser: -1);
      expect(rBad.available, closeTo(lay(scale: 0).available, 1.0));
    });

    test('不变式：分栏时 180 ≤ renderW ≤ available；覆盖式时 renderW = 0', () {
      for (var cw = 200.0; cw <= 4000; cw += 37.0) {
        for (final manual in [0.0, 180.0, 300.0, 800.0]) {
          for (final auto in [true, false]) {
            final r = lay(cw: cw, manual: manual, auto: auto);
            expect(r.renderW.isFinite, isTrue);
            if (r.overlay) {
              expect(r.renderW, 0, reason: 'cw=$cw manual=$manual auto=$auto');
            } else {
              expect(r.renderW, greaterThanOrEqualTo(180 - 0.001), reason: 'cw=$cw manual=$manual');
              expect(r.renderW, lessThanOrEqualTo(r.available + 0.001), reason: 'cw=$cw manual=$manual');
              expect(r.renderW, lessThanOrEqualTo(cw - 8 + 0.001), reason: 'cw=$cw manual=$manual');
            }
          }
        }
      }
    });
  });
}
