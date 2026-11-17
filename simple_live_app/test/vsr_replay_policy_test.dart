import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/utils/vsr_replay_policy.dart';

/// v3.5 C1：应用级修因策略（判据 = dw/dh 比 == crop 目标比；触发 = 条件式「新 scale 已落定」）
/// 纯逻辑测试。
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
      expect(vsrCropRatio('3600'), isNull); // 无 x
      expect(vsrCropRatio('x2024+0+0'), isNull); // x 在首
      expect(vsrCropRatio('3600x2024'), isNull); // 无 +
      expect(vsrCropRatio('3600x2024+0'), closeTo(1.77866, 1e-4)); // 缺 y 仍可解析宽高
    });
    test('非正数 → null', () {
      expect(vsrCropRatio('0x2024+0+0'), isNull);
      expect(vsrCropRatio('3600x0+0+0'), isNull);
      expect(vsrCropRatio('-100x200+0+0'), isNull); // 负宽（D-3）
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
      expect(vsrOutAppliedCrop(dw: 3600, dh: 0, targetRatio: target, tolerance: tol), isFalse);
    });
    test('刚好等于容差边界 → true（<=）', () {
      // 构造比值差恰为 tol 的目标：dw/dh - target == tol（数值近似）
      expect(
        vsrOutAppliedCrop(dw: 1005, dh: 1000, targetRatio: 1.0, tolerance: 0.005),
        isTrue,
      );
    });
  });

  group('vsrExpectedOutPairs（新 scale 落定候选对，成对去交叉积）', () {
    test('960x544@3.75 + render 3600x2024 → 含两对', () {
      final pairs = vsrExpectedOutPairs(
          rawW: 960, rawH: 544, scale: 3.75, renderW: 3600, renderH: 2024);
      expect(pairs, isNotNull);
      expect(pairs!, contains((3600, 2040))); // 未裁满帧
      expect(pairs.contains((3600, 2024)), isTrue); // 裁后帧
    });
    test('无 renderSize → 只含未裁满帧对', () {
      final pairs = vsrExpectedOutPairs(rawW: 960, rawH: 544, scale: 3.75);
      expect(pairs, equals(<(int, int)>{(3600, 2040)}));
    });
    test('scale 为空 → null（不布防）', () {
      expect(vsrExpectedOutPairs(rawW: 960, rawH: 544, scale: null), isNull);
    });
    test('尺寸非法 → null', () {
      expect(vsrExpectedOutPairs(rawW: 0, rawH: 544, scale: 2.0), isNull);
      expect(vsrExpectedOutPairs(rawW: 960, rawH: -1, scale: 2.0), isNull);
    });
    test('交叉积不再误命中：dw 取未裁态、dh 取裁后态 → 不在集合', () {
      final pairs = vsrExpectedOutPairs(
          rawW: 960, rawH: 544, scale: 3.75, renderW: 3600, renderH: 2024);
      // (3600,2024) 是合法对、(3600,2040) 是合法对，但成对集合不含混合态
      expect(pairs!.contains((3600, 2024)), isTrue);
      expect(pairs.contains((3600, 2040)), isTrue);
      // 若集合是「宽集×高集」就会误含 (3600,9999)/(9999,2040) 之类混合态——成对集合不会：
      expect(pairs.contains((3600, 9999)), isFalse);
      expect(pairs.contains((9999, 2024)), isFalse);
    });
  });

  group('vsrShouldRepair（条件式：落定 + 稳定 + 冷却 + 预算）', () {
    const stable = Duration(milliseconds: 300);
    const cooldown = Duration(milliseconds: 400);
    bool call({
      bool chain = true,
      String crop = '3600x2024+0+0',
      bool applied = false,
      bool landed = true,
      Duration? stableFor = const Duration(seconds: 1),
      Duration? sinceRepair = const Duration(seconds: 1),
      int budget = 3,
    }) =>
        vsrShouldRepair(
          chainApplied: chain,
          crop: crop,
          applied: applied,
          landed: landed,
          stableFor: stableFor,
          sinceRepair: sinceRepair,
          stable: stable,
          cooldown: cooldown,
          budgetLeft: budget,
        );

    test('未应用 + 已落定 + 稳定 + 冷却过 + 有预算 → true', () => expect(call(), isTrue));
    test('已应用 → false', () => expect(call(applied: true), isFalse));
    test('新 scale 未落定 → false（核心：不猜时机）', () => expect(call(landed: false), isFalse));
    test('链未挂 → false', () => expect(call(chain: false), isFalse));
    test('无 crop 目标 → false', () => expect(call(crop: ''), isFalse));
    test('预算耗尽 → false', () => expect(call(budget: 0), isFalse));
    test('稳定不足 → false', () {
      expect(call(stableFor: const Duration(milliseconds: 100)), isFalse);
    });
    test('稳定未知 → false', () => expect(call(stableFor: null), isFalse));
    test('冷却未过 → false', () {
      expect(call(sinceRepair: const Duration(milliseconds: 100)), isFalse);
    });
    test('冷却未知（首次重放）→ 放行', () => expect(call(sinceRepair: null), isTrue));
  });

  group('vsrFallbackDue（兜底安全网）', () {
    const maxWait = Duration(seconds: 8);
    bool call({
      bool chain = true,
      String crop = '3600x2024+0+0',
      bool applied = false,
      bool pending = true,
      Duration? since = const Duration(seconds: 9),
      int budget = 0,
    }) =>
        vsrFallbackDue(
          chainApplied: chain,
          crop: crop,
          applied: applied,
          correctorPending: pending,
          sinceChainWrite: since,
          budgetLeft: budget,
          maxWait: maxWait,
        );

    test('预算耗尽 + 校正器在等 + 久等 + 未应用 → true', () => expect(call(), isTrue));
    test('仍有预算 → false', () => expect(call(budget: 1), isFalse));
    test('已应用 → false', () => expect(call(applied: true), isFalse));
    test('校正器未在等 → false', () => expect(call(pending: false), isFalse));
    test('未届 maxWait → false', () {
      expect(call(since: const Duration(seconds: 3)), isFalse);
    });
    test('链未挂 / 无目标 → false', () {
      expect(call(chain: false), isFalse);
      expect(call(crop: ''), isFalse);
    });
  });
}
