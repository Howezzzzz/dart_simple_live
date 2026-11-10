import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/utils/rtx_vsr_crop.dart';

/// VSR 开关热切换 / 进房共用的纯逻辑决策（`rtxVsrPlan`）单测。
void main() {
  group('rtxVsrPlan（决策：开/关 × 播放区 × 源）', () {
    test('关 + 有播放区 → 摘链、清裁切、比例回源、画布恢复默认', () {
      final p = rtxVsrPlan(
          enabled: false, areaW: 1920, areaH: 1080, srcW: 960, srcH: 544);
      expect(p.applied, false);
      expect(p.scale, isNull);
      expect(p.crop, '');
      expect(p.aspect, closeTo(960 / 544, 1e-9));
      expect(p.renderSize, isNull);
    });

    test('开 + 960x544 + 1080p 播放区 → 2 倍，裁切/比例/画布齐，链字符串正确', () {
      final p = rtxVsrPlan(
          enabled: true, areaW: 1920, areaH: 1080, srcW: 960, srcH: 544);
      expect(p.applied, true);
      expect(p.scale, 2.0);
      expect(p.crop, '1920x1080+0+0');
      expect(p.aspect, closeTo(16 / 9, 1e-9));
      expect(p.renderSize, (1920, 1080));
      expect(rtxVsrVfChain(p.scale!), 'd3d11vpp=scale=2.00:scaling-mode=nvidia');
    });

    test('开 + 4K 播放区 + 540p 源 → 4 倍（自适应）', () {
      final p = rtxVsrPlan(
          enabled: true, areaW: 3840, areaH: 2160, srcW: 960, srcH: 544);
      expect(p.scale, 4.0);
    });

    test('开 + 播放区不可得 → 固定 2x 兜底', () {
      final p = rtxVsrPlan(enabled: true, srcW: 960, srcH: 544);
      expect(p.applied, true);
      expect(p.scale, 2.0);
    });

    test('开 + 源≥播放区（倍数为 null）→ 视为不挂（自动跳过）', () {
      final p = rtxVsrPlan(
          enabled: true, areaW: 1920, areaH: 1080, srcW: 1920, srcH: 1080);
      expect(p.applied, false);
      expect(p.scale, isNull);
      expect(p.crop, '');
      expect(p.renderSize, isNull);
    });

    test('竖屏 / 非 16:9 / 超大源 / 非法：不炸、比例有限、非法不挂', () {
      final cases = <List<int>>[
        [540, 960],
        [848, 480],
        [4096, 2160],
        [0, 0]
      ];
      for (final s in cases) {
        final p = rtxVsrPlan(
            enabled: true, areaW: 1920, areaH: 1080, srcW: s[0], srcH: s[1]);
        expect(p.aspect.isFinite, true);
        if (s[0] <= 0 || s[1] <= 0) {
          expect(p.applied, false);
          expect(p.crop, '');
        }
      }
    });

    test('链字符串保留 2 位小数', () {
      expect(rtxVsrVfChain(1.5), 'd3d11vpp=scale=1.50:scaling-mode=nvidia');
      expect(rtxVsrVfChain(3), 'd3d11vpp=scale=3.00:scaling-mode=nvidia');
    });
  });

  group('rtx_vsr_crop 补充：非整数倍数向下取偶', () {
    test('3.5 倍 → 尺寸向下取偶', () {
      expect(rtxVsrRenderSize(960, 544, scale: 3.5), (3360, 1890));
      expect(rtxVsrVideoCrop(960, 544, scale: 3.5), '3360x1890+0+0');
      // 2.75 倍 → 内容高 540*2.75=1485（奇）→ 取偶 1484
      expect(rtxVsrRenderSize(960, 544, scale: 2.75), (2640, 1484));
    });
  });
}
