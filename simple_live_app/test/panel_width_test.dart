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

  // RISK-17 方案 B（2026-10-21 Howe 定）：按面板设定宽能否完整放下 → 极窄则覆盖式。
  group('panelNeedsOverlay（RISK-17 方案 B）', () {
    // 播放区高 900、视频 16:9 → 播放区应有宽 = 900 * 16/9 = 1600
    test('窗口够宽 → 分栏（false）：1920 宽、面板 300', () {
      // available = 1920 - 1600 - 8 = 312 ≥ 300
      expect(
        panelNeedsOverlay(contentWidth: 1920, videoWidth: 1920, videoHeight: 1080, playerHeight: 900, panelWidth: 300),
        isFalse,
      );
    });

    test('窗口偏窄 → 覆盖式（true）：1700 宽、面板 300', () {
      // available = 1700 - 1600 - 8 = 92 < 300
      expect(
        panelNeedsOverlay(contentWidth: 1700, videoWidth: 1920, videoHeight: 1080, playerHeight: 900, panelWidth: 300),
        isTrue,
      );
    });

    test('面板拖窄后更容易分栏：同样 1700 宽、面板 80 → 分栏', () {
      // available = 92 ≥ 80
      expect(
        panelNeedsOverlay(contentWidth: 1700, videoWidth: 1920, videoHeight: 1080, playerHeight: 900, panelWidth: 80),
        isFalse,
      );
    });

    test('边界：available 恰等于面板宽 → 分栏', () {
      // contentWidth = 1600 + 8 + 300 = 1908
      expect(
        panelNeedsOverlay(contentWidth: 1908, videoWidth: 1920, videoHeight: 1080, playerHeight: 900, panelWidth: 300),
        isFalse,
      );
      expect(
        panelNeedsOverlay(
            contentWidth: 1907.9, videoWidth: 1920, videoHeight: 1080, playerHeight: 900, panelWidth: 300),
        isTrue,
      );
    });

    test('尺寸/参数未就绪 → 不折叠（false，保守）', () {
      expect(
        panelNeedsOverlay(contentWidth: 0, videoWidth: 1920, videoHeight: 1080, playerHeight: 900, panelWidth: 300),
        isFalse,
      );
      expect(
        panelNeedsOverlay(contentWidth: 1920, videoWidth: 0, videoHeight: 1080, playerHeight: 900, panelWidth: 300),
        isFalse,
      );
      expect(
        panelNeedsOverlay(contentWidth: 1920, videoWidth: 1920, videoHeight: 1080, playerHeight: 900, panelWidth: 0),
        isFalse,
      );
      expect(
        panelNeedsOverlay(
            contentWidth: double.nan, videoWidth: 1920, videoHeight: 1080, playerHeight: 900, panelWidth: 300),
        isFalse,
      );
    });
  });
}
