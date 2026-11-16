import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/utils/vsr_replay_policy.dart';

/// v3.5 C1：应用级重放策略（判据 = dw/dh 比 == crop 目标比）纯逻辑测试。
///
/// 真实案例：斗鱼 960x544 补边流，VSR 放大 3.75 → 链输出 3600x2040（未裁）/
/// crop 目标 3600x2024（裁掉底部 4 行补边 → 16:9）。
void main() {
  group('vsrCropRatio（crop 值 → 宽高比）', () {
    test('3600x2024+0+0 → ≈1.7787', () {
      expect(vsrCropRatio('3600x2024+0+0'), closeTo(1.77866, 1e-4));
    });
    test('3360x1890+0+0 → ≈1.7778', () {
      expect(vsrCropRatio('3360x1890+0+0'), closeTo(1.7778, 1e-3));
    });
    test('空串 → null', () => expect(vsrCropRatio(''), isNull));
    test('格式异常 → null', () {
      expect(vsrCropRatio('3600'), isNull);
      expect(vsrCropRatio('x2024+0+0'), isNull);
      expect(vsrCropRatio('3600x2024'), isNull);
    });
    test('非正数 → null', () {
      expect(vsrCropRatio('0x2024+0+0'), isNull);
      expect(vsrCropRatio('3600x0+0+0'), isNull);
    });
  });

  group('vsrOutAppliedCrop（应用级判据）', () {
    const tol = 0.005;
    final target = vsrCropRatio('3600x2024+0+0');
    test('crop 生效：3600x2024 == 目标 → true', () {
      expect(vsrOutAppliedCrop(dw: 3600, dh: 2024, targetRatio: target, tolerance: tol), isTrue);
    });
    test('crop 未生效：3600x2040（1.7647）≠ 目标（1.7787）→ false', () {
      expect(vsrOutAppliedCrop(dw: 3600, dh: 2040, targetRatio: target, tolerance: tol), isFalse);
    });
    test('容差内（3600x2025 差 ≈0.05%）→ true', () {
      expect(vsrOutAppliedCrop(dw: 3600, dh: 2025, targetRatio: target, tolerance: tol), isTrue);
    });
    test('目标不可解析 → false', () {
      expect(vsrOutAppliedCrop(dw: 3600, dh: 2024, targetRatio: null, tolerance: tol), isFalse);
    });
    test('dw/dh 非法 → false', () {
      expect(vsrOutAppliedCrop(dw: 0, dh: 2024, targetRatio: target, tolerance: tol), isFalse);
    });
  });

  group('vsrWatchdogShouldReplay（双门 + 判据 + 预算）', () {
    const quiet = Duration(seconds: 2);
    const stable = Duration(seconds: 2);
    const tol = 0.005;
    bool call({
      bool chain = true,
      String crop = '3600x2024+0+0',
      int dw = 3600,
      int dh = 2040,
      Duration? since = const Duration(seconds: 3),
      Duration? stableFor = const Duration(seconds: 3),
      int budget = 3,
    }) =>
        vsrWatchdogShouldReplay(
          chainApplied: chain,
          crop: crop,
          dw: dw,
          dh: dh,
          sinceChainWrite: since,
          stableFor: stableFor,
          quiet: quiet,
          stable: stable,
          tolerance: tol,
          budgetLeft: budget,
        );

    test('crop 未应用 + 双门过 + 有预算 → true', () => expect(call(), isTrue));
    test('crop 已应用（dh=2024 命中目标）→ false', () => expect(call(dh: 2024), isFalse));
    test('链未挂 → false', () => expect(call(chain: false), isFalse));
    test('无 crop 目标 → false', () => expect(call(crop: ''), isFalse));
    test('静默门未过（距链写 1s）→ false', () {
      expect(call(since: const Duration(seconds: 1)), isFalse);
    });
    test('稳定门未过（稳定 1s）→ false', () {
      expect(call(stableFor: const Duration(seconds: 1)), isFalse);
    });
    test('静默门未知 → false', () => expect(call(since: null), isFalse));
    test('稳定门未知 → false', () => expect(call(stableFor: null), isFalse));
    test('预算耗尽 → false', () => expect(call(budget: 0), isFalse));
    test('dw/dh 非法 → false', () => expect(call(dw: 0), isFalse));
  });
}
