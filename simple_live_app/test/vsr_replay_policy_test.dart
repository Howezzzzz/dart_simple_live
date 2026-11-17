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
    });
    test('缺 y 仍可解析宽高（3600x2024+0）', () {
      expect(vsrCropRatio('3600x2024+0'), closeTo(1.77866, 1e-4));
    });
    test('非正数 → null', () {
      expect(vsrCropRatio('0x2024+0+0'), isNull);
      expect(vsrCropRatio('3600x0+0+0'), isNull);
      expect(vsrCropRatio('-100x200+0+0'), isNull); // 负宽
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
      expect(
        vsrOutAppliedCrop(dw: 1005, dh: 1000, targetRatio: 1.0, tolerance: 0.005),
        isTrue,
      );
    });
  });

  group('vsrExpectedFramePairs（新 scale 帧真实尺寸 w/h）', () {
    test('960x544@3.75 → 仅 (3600,2040)', () {
      final pairs = vsrExpectedFramePairs(rawW: 960, rawH: 544, scale: 3.75);
      expect(pairs, equals(<(int, int)>{(3600, 2040)}));
    });
    test('960x544@3.50 → (3360,1904)', () {
      expect(vsrExpectedFramePairs(rawW: 960, rawH: 544, scale: 3.50),
          equals(<(int, int)>{(3360, 1904)}));
    });
    test('scale 为空 → null（不布防）', () {
      expect(vsrExpectedFramePairs(rawW: 960, rawH: 544, scale: null), isNull);
    });
    test('尺寸非法 → null', () {
      expect(vsrExpectedFramePairs(rawW: 0, rawH: 544, scale: 2.0), isNull);
      expect(vsrExpectedFramePairs(rawW: 960, rawH: -1, scale: 2.0), isNull);
    });
  });

  group('vsrMatchesPair（像素 + 0.5% + 16 对齐容差，v3.5c/d/e B-1）', () {
    final pairs = vsrExpectedFramePairs(rawW: 960, rawH: 544, scale: 3.75);
    test('精确命中 → true', () {
      expect(vsrMatchesPair(pairs, (3600, 2040), tolPx: 3), isTrue);
    });
    test('小偏差（±1~3px）→ true', () {
      expect(vsrMatchesPair(pairs, (3599, 2039), tolPx: 3), isTrue);
      expect(vsrMatchesPair(pairs, (3603, 2043), tolPx: 3), isTrue);
    });
    test('16 对齐偏差放行（1350→1344；2176→2160，差 16）', () {
      final p = vsrExpectedFramePairs(rawW: 640, rawH: 360, scale: 3.75);
      expect(vsrMatchesPair(p, (2400, 1344), tolPx: 3), isTrue); // 差 6
      final p4k = vsrExpectedFramePairs(rawW: 960, rawH: 544, scale: 4.0);
      expect(vsrMatchesPair(p4k, (3840, 2160), tolPx: 3), isTrue); // 差 16
    });
    test('超容差 → false', () {
      expect(vsrMatchesPair(pairs, (3620, 2040), tolPx: 3), isFalse); // dx 20 > 18
      expect(vsrMatchesPair(pairs, (3600, 2007), tolPx: 3), isFalse); // dy 33 > 16
    });
    test('pairs 为 null → false', () {
      expect(vsrMatchesPair(null, (3600, 2040), tolPx: 3), isFalse);
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
    test('稳定恰等于门限 → true（边界：< 判否）', () {
      expect(call(stableFor: stable), isTrue);
    });
    test('冷却未过 → false', () {
      expect(call(sinceRepair: const Duration(milliseconds: 100)), isFalse);
    });
    test('冷却恰等于门限 → true（边界）', () {
      expect(call(sinceRepair: cooldown), isTrue);
    });
    test('冷却未知（首次重放）→ 放行', () => expect(call(sinceRepair: null), isTrue));
  });

  group('vsrFallbackDue（绝对兜底，v3.5c C-1：不以预算为前提）', () {
    const maxWait = Duration(seconds: 8);
    bool call({
      bool chain = true,
      String crop = '3600x2024+0+0',
      bool applied = false,
      bool pending = true,
      Duration? sinceProgress = const Duration(seconds: 9),
    }) =>
        vsrFallbackDue(
          chainApplied: chain,
          crop: crop,
          applied: applied,
          correctorPending: pending,
          sinceProgress: sinceProgress,
          maxWait: maxWait,
        );

    test('未应用 + 校正器在等 + 超 8s 无进展 → true', () => expect(call(), isTrue));
    test('关键修正：即使预算未耗尽（无预算参数）也应兜底', () {
      // 旧实现以 budgetLeft<=0 为前提，落定判据失配时预算恒 >0 → 永挂；新实现无此前提。
      expect(call(sinceProgress: const Duration(seconds: 9)), isTrue);
    });
    test('已应用 → false', () => expect(call(applied: true), isFalse));
    test('校正器未在等 → false', () => expect(call(pending: false), isFalse));
    test('未届 maxWait → false', () {
      expect(call(sinceProgress: const Duration(seconds: 3)), isFalse);
    });
    test('恰等于 maxWait → true（边界：< 判否）', () {
      expect(call(sinceProgress: maxWait), isTrue);
    });
    test('进度未知 → false', () => expect(call(sinceProgress: null), isFalse));
    test('链未挂 / 无目标 → false', () {
      expect(call(chain: false), isFalse);
      expect(call(crop: ''), isFalse);
    });
  });

  // v3.5i（1.08.83 / ISS-311）：兜底「进度锚点」——防「瞬间误兜底」导致二次写链。
  group('vsrSinceProgressAt（兜底进度锚点，ISS-311）', () {
    final now = DateTime(2026, 11, 17, 15, 20, 56);
    test('无任何锚点 → null（调用方不兜底）', () {
      expect(vsrSinceProgressAt(now: now), isNull);
    });
    test('只有链写 → now − 链写', () {
      expect(
        vsrSinceProgressAt(
            chainWriteAt: now.subtract(const Duration(seconds: 3)), now: now),
        const Duration(seconds: 3),
      );
    });
    test('★ pendingAt 晚于陈旧链写 → 取 pendingAt（跨代际锚点被兜住）', () {
      expect(
        vsrSinceProgressAt(
          chainWriteAt: now.subtract(const Duration(seconds: 47)), // 上一代际摘链
          pendingAt: now.subtract(const Duration(milliseconds: 40)), // 刚请求修因
          now: now,
        ),
        const Duration(milliseconds: 40),
      );
    });
    test('重放晚于另两者 → 取重放（任一路径有进展即前移锚点）', () {
      expect(
        vsrSinceProgressAt(
          chainWriteAt: now.subtract(const Duration(seconds: 47)),
          pendingAt: now.subtract(const Duration(seconds: 5)),
          lastRepairAt: now.subtract(const Duration(seconds: 2)),
          now: now,
        ),
        const Duration(seconds: 2),
      );
    });
    test('★ ISS-311 回归：旧逻辑（不含 pendingAt）判 ≥8s → 新逻辑否', () {
      final legacy = vsrSinceProgressAt(
          chainWriteAt: now.subtract(const Duration(seconds: 47)), now: now);
      expect(legacy! >= const Duration(seconds: 8), isTrue); // 旧：会瞬间兜底（错）
      final fixed = vsrSinceProgressAt(
        chainWriteAt: now.subtract(const Duration(seconds: 47)),
        pendingAt: now.subtract(const Duration(milliseconds: 40)),
        now: now,
      );
      expect(fixed! < const Duration(seconds: 8), isTrue); // 新：不兜底（对）
    });
  });
}
