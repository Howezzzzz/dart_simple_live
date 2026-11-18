import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/utils/vsr_display_aspect_guard.dart';

/// C-5（批次 B ⑤ / §11.6）：校正器守卫合取式抽纯函数后的**双调用点语义等价**回归。
///
/// 两个调用点（player_controller.dart）：
/// - 调用点 A `_syncRtxVsrCrop`：显示比缓存路径——校正器已按实测比 fired ∧ 链已挂 ⇒
///   锁住 `_vsrDisplayAspect`（不用假说比冲回，ISS-294 P1-2）。
/// - 调用点 B `_applyRtxVsrSetting`：toggle Rx 预写路径——同一守卫（尊重校正器结果）；
///   特别地，toggle-**off**（链未挂）即使 fired=true 也必须放行（`_vsrDisplayAspect`
///   要能正常置 null）。
///
/// 语义等价判据：与抽出前的原合取式 `!(correctorFired && chainApplied)`
/// 在全部 4 种输入组合下一一相等。
void main() {
  // 原式（抽出前两个调用点共享的字面合取式），作为等价性基准。
  bool legacyGuard(bool fired, bool applied) => !(fired && applied);

  const combos = [
    [false, false],
    [false, true],
    [true, false],
    [true, true],
  ];

  test('C-5 调用点A（_syncRtxVsrCrop 显示比缓存）：全 4 组合与原合取式等价', () {
    for (final c in combos) {
      final fired = c[0];
      final applied = c[1];
      expect(
        vsrDisplayAspectWritable(
            correctorFired: fired, chainApplied: applied),
        legacyGuard(fired, applied),
        reason: 'fired=$fired applied=$applied 必须与原式 !(fired && applied) 等价',
      );
    }
  });

  test('C-5 调用点B（_applyRtxVsrSetting toggle 预写）：全 4 组合与原合取式等价', () {
    for (final c in combos) {
      final fired = c[0];
      final applied = c[1];
      expect(
        vsrDisplayAspectWritable(
            correctorFired: fired, chainApplied: applied),
        legacyGuard(fired, applied),
        reason: 'toggle 预写与缓存路径共用同一守卫语义（零行为变）',
      );
    }
  });

  test('C-5 关键语义：校正器已实测比 ∧ 链已挂 ⇒ 锁住（false）', () {
    expect(
      vsrDisplayAspectWritable(correctorFired: true, chainApplied: true),
      isFalse,
      reason: '实测比不得被假说比冲回（ISS-294 P1-2 / 房B 黑边复现路径）',
    );
  });

  test('C-5 关键语义：链未挂（toggle-off / VSR 关）⇒ 放行（true），即使已 fired', () {
    expect(
      vsrDisplayAspectWritable(correctorFired: true, chainApplied: false),
      isTrue,
      reason: '_vsrDisplayAspect 需能正常置 null / 假说比预写',
    );
  });
}
