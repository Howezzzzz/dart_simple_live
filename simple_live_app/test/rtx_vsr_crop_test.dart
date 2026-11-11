import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/utils/rtx_vsr_crop.dart';

/// RTX VSR 底部补边裁切（ISS-245：VSR 底部绿条）。
///
/// 真实案例：斗鱼 960x544 直播流（真实内容 960x540，编码按 16 对齐补到 544）。
/// 注意坐标系：mpv 的 `video-crop` 由 VO 在**滤镜之后**应用（player/video.c:
/// apply_video_crop），而 VSR 把画面放大了 2 倍 → 裁切值须按放大后的尺寸给（1920x1080）。
void main() {
  group('rtxVsrBottomPadRows（源尺寸口径的补边行数）', () {
    test('540p 被编码补边到 544 → 判定补边 4 行', () {
      expect(rtxVsrBottomPadRows(960, 544), 4);
    });

    test('1080p 硬件帧报 1088 → 判定补边 8 行', () {
      expect(rtxVsrBottomPadRows(1920, 1088), 8);
    });

    test('标准 16:9（720p/1080p/540p）不裁', () {
      expect(rtxVsrBottomPadRows(1280, 720), 0);
      expect(rtxVsrBottomPadRows(1920, 1080), 0);
      expect(rtxVsrBottomPadRows(960, 540), 0);
    });

    test('4:3 等非 16:9 比例不动（避免误裁真实画面）', () {
      expect(rtxVsrBottomPadRows(640, 480), 0);
      expect(rtxVsrBottomPadRows(1024, 768), 0);
    });

    test('高度非 16 整数倍 → 不是对齐补边，不裁', () {
      expect(rtxVsrBottomPadRows(1280, 728), 0);
      expect(rtxVsrBottomPadRows(1920, 1096), 0);
      expect(rtxVsrBottomPadRows(960, 600), 0);
    });

    test('多出超过 8 行 → 不裁（阈值上界）', () {
      expect(rtxVsrBottomPadRows(1280, 736), 0); // 补边 16 行
      expect(rtxVsrBottomPadRows(1884, 1072), 0); // 补边 12 行
      expect(rtxVsrBottomPadRows(960, 560), 0); // 补边 20 行
    });

    test('裁后高度为奇数 → 是真实画面而非补边，不裁', () {
      expect(rtxVsrBottomPadRows(848, 480), 0); // 理想 16:9 高 477（奇）
      expect(rtxVsrBottomPadRows(1360, 768), 0); // 理想 16:9 高 765（奇）
    });

    test('高度小于 16:9 基准（负差）时也不裁', () {
      expect(rtxVsrBottomPadRows(960, 500), 0);
    });

    test('负差且 16 对齐 → 0（钉住 pad<1 下界，防删门回归）', () {
      expect(rtxVsrBottomPadRows(960, 528), 0); // 理想 540，pad=-12
      expect(rtxVsrBottomPadRows(1920, 1072), 0); // 理想 1080，pad=-8
    });

    test('正向下界：补边 2 行也裁（992x560 → 2）', () {
      expect(rtxVsrBottomPadRows(992, 560), 2); // 理想 558（偶），补 2
    });

    test('round 语义钉住（换 floor/ceil 会挂）', () {
      expect(rtxVsrBottomPadRows(497, 288), 8); // 理想 279.5625 → round 280（偶）
      expect(rtxVsrBottomPadRows(498, 288), 8); // 理想 280.125 → round 280；ceil 得 281（奇）→ 偶数门拒绝
    });

    test('非法尺寸安全返回 0', () {
      expect(rtxVsrBottomPadRows(0, 0), 0);
      expect(rtxVsrBottomPadRows(-100, 544), 0);
      expect(rtxVsrBottomPadRows(960, 0), 0);
    });
  });

  group('rtxVsrVideoCrop（mpv video-crop 值，放大后坐标系）', () {
    test('960x544 → 1920x1080（按 2 倍放大后的尺寸，保留顶部）', () {
      expect(rtxVsrVideoCrop(960, 544), '1920x1080+0+0');
    });

    test('1920x1088 → 3840x2160', () {
      expect(rtxVsrVideoCrop(1920, 1088), '3840x2160+0+0');
    });

    test('scale 参数生效', () {
      expect(rtxVsrVideoCrop(960, 544, scale: 3), '2880x1620+0+0');
    });

    test('无需裁切时返回空串（mpv 约定：空串=取消手动裁切）', () {
      expect(rtxVsrVideoCrop(1280, 720), '');
      expect(rtxVsrVideoCrop(640, 480), '');
      expect(rtxVsrVideoCrop(848, 480), '');
      expect(rtxVsrVideoCrop(960, 500), '');
      expect(rtxVsrVideoCrop(960, 528), ''); // 负差（-12）且 16 对齐
      expect(rtxVsrVideoCrop(0, 0), '');
    });
  });

  group('rtxVsrDisplayAspect（裁切生效时的真实显示比例）', () {
    test('补边流给内容比例（960x544 → 16:9）', () {
      expect(rtxVsrDisplayAspect(960, 544), closeTo(16 / 9, 1e-9));
      expect(rtxVsrDisplayAspect(1920, 1088), closeTo(16 / 9, 1e-9));
    });

    test('无补边时返回 null（调用方按源比例）', () {
      expect(rtxVsrDisplayAspect(1280, 720), isNull);
      expect(rtxVsrDisplayAspect(640, 480), isNull);
      expect(rtxVsrDisplayAspect(960, 500), isNull);
    });
  });

  group('rtxVsrRenderSize（VSR 渲染尺寸）', () {
    test('补边流按放大后并去补边（960x544 → 1920x1080）', () {
      expect(rtxVsrRenderSize(960, 544), (1920, 1080));
      expect(rtxVsrRenderSize(1920, 1088), (3840, 2160));
    });

    test('无补边时按放大后原尺寸（1280x720 → 2560x1440）', () {
      expect(rtxVsrRenderSize(1280, 720), (2560, 1440));
    });

    test('可按倍数参数化（960x544 @3 → 2880x1620）', () {
      expect(rtxVsrRenderSize(960, 544, scale: 3), (2880, 1620));
      expect(rtxVsrRenderSize(960, 544, scale: 1.5), (1440, 810));
    });

    test('非法尺寸返回 null', () {
      expect(rtxVsrRenderSize(0, 0), isNull);
      expect(rtxVsrRenderSize(960, 0), isNull);
    });

    test('单边超 8192（sanity）返回 null', () {
      expect(rtxVsrRenderSize(3840, 2160), (7680, 4320)); // 未超限
      expect(rtxVsrRenderSize(4096, 2160, scale: 4), isNull); // 16384 > 8192
    });
  });

  group('rtxVsrAdaptiveScale（自适应倍数：目标≈播放区物理分辨率）', () {
    test('源低就多放大：540p 到 4K 播放区 → 4', () {
      expect(
          rtxVsrAdaptiveScale(
              areaW: 3840, areaH: 2160, srcW: 960, srcH: 544),
          4.0);
    });

    test('720p → 4K 得 3；→ 1080p 得 1.5', () {
      expect(
          rtxVsrAdaptiveScale(
              areaW: 3840, areaH: 2160, srcW: 1280, srcH: 720),
          3.0);
      expect(
          rtxVsrAdaptiveScale(
              areaW: 1920, areaH: 1080, srcW: 1280, srcH: 720),
          1.5);
    });

    test('0.25 步长向上取；夹取上限 4', () {
      expect(
          rtxVsrAdaptiveScale(
              areaW: 1920, areaH: 1080, srcW: 960, srcH: 544),
          2.0);
      expect(
          rtxVsrAdaptiveScale(
              areaW: 2560, areaH: 1440, srcW: 960, srcH: 544),
          2.75);
      expect(
          rtxVsrAdaptiveScale(
              areaW: 7680, areaH: 4320, srcW: 960, srcH: 544),
          4.0);
    });

    test('源≥播放区 → null（不挂 VSR）', () {
      expect(
          rtxVsrAdaptiveScale(
              areaW: 1920, areaH: 1080, srcW: 1920, srcH: 1080),
          isNull);
      expect(
          rtxVsrAdaptiveScale(
              areaW: 1280, areaH: 720, srcW: 1920, srcH: 1080),
          isNull);
    });

    test('非法尺寸 → null', () {
      expect(
          rtxVsrAdaptiveScale(areaW: 0, areaH: 0, srcW: 960, srcH: 544),
          isNull);
      expect(
          rtxVsrAdaptiveScale(
              areaW: 1920, areaH: 1080, srcW: 0, srcH: 0),
          isNull);
    });
  });

  // 方案 20261111（进房「出画面又重载」）的回归防线：只有 Windows + VSR 开启才允许
  // 延迟起播；其余必须保持自动起播，否则全平台都会推迟起播。
  group('vsrShouldDeferPlay（起播门控边界）', () {
    test('仅 Windows 且 VSR 开启才延迟起播', () {
      expect(vsrShouldDeferPlay(isWindows: true, vsrEnabled: true), isTrue);
      expect(vsrShouldDeferPlay(isWindows: true, vsrEnabled: false), isFalse);
      expect(vsrShouldDeferPlay(isWindows: false, vsrEnabled: true), isFalse);
      expect(vsrShouldDeferPlay(isWindows: false, vsrEnabled: false), isFalse);
    });
  });
}
