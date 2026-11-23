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

  // ===== 1.08.86（ISS-315）：面板几何「比例载体」选择（vsrPanelGrid）=====
  group('vsrPanelGrid（面板几何载体，ISS-315）', () {
    test('VSR 生效（renderSize 非空）⇒ 用渲染面网格（与视频显示面同源）', () {
      expect(
        vsrPanelGrid(
          windows: true,
          renderSize: (3600, 2024),
          w: 960,
          h: 544,
          aspect: 3600 / 2024,
        ),
        (3600, 2024),
        reason: '960x544@3.75：渲染面比 ≡ 视频显示比 ⇒ 面板框与显示同实数、取整同向（消左右 1px）',
      );
    });

    test('renderSize 优先于 aspect 与 (w,h)（三者都给 → 取 renderSize）', () {
      expect(
        vsrPanelGrid(
          windows: true,
          renderSize: (2880, 1620),
          w: 1920,
          h: 1088,
          aspect: 1.777778,
        ),
        (2880, 1620),
      );
    });

    test('无 renderSize + aspect 可得 ⇒ 回落旧「源高网格」(round(h×aspect), h)（旧行为保留）', () {
      expect(
        vsrPanelGrid(
            windows: true, renderSize: null, w: 960, h: 544, aspect: 968 / 544),
        (968, 544),
      );
    });

    test('关向（VSR off）：renderSize null、aspect=源比 ⇒ 源网格（960/544）', () {
      expect(
        vsrPanelGrid(
            windows: true, renderSize: null, w: 960, h: 544, aspect: 960 / 544),
        (960, 544),
      );
    });

    test('非 Windows ⇒ 原样返回 (w,h)（安卓不涉 VSR 几何）', () {
      expect(
        vsrPanelGrid(
            windows: false, renderSize: (3600, 2024), w: 0, h: 544, aspect: null),
        (0, 544),
      );
    });

    test('VSR 未生效且 aspect/h 不可得 ⇒ 原样返回（含 null 退化）', () {
      expect(
        vsrPanelGrid(
            windows: true, renderSize: null, w: null, h: null, aspect: null),
        (0, 0),
      );
      expect(
        vsrPanelGrid(
            windows: true, renderSize: null, w: 1280, h: 720, aspect: null),
        (1280, 720),
      );
      expect(
        vsrPanelGrid(
            windows: true, renderSize: null, w: 1280, h: 0, aspect: 1.5),
        (1280, 0),
        reason: 'h<=0 不参与取整（防除零/非法几何）',
      );
    });
  });

  // ===== 1.08.87（ISS-316）：真值网格优先（vsrChainKey / vsrTruthPriority）=====
  group('vsrTruthPriority / vsrChainKey（ISS-316）', () {
    const keyA = '3.75|3600:2024:0:0|540|1.777778';
    const keyB = '3.75|3600:2024:0:0|544|1.764706';

    test('签名一致 + 真值存在 ⇒ 用真值网格（非预测）', () {
      expect(
        vsrTruthPriority(
            truthGrid: (3600, 2025),
            truthKey: keyA,
            newKey: keyA,
            renderSize: (3600, 2024)),
        (3600, 2025),
      );
    });

    test('签名不一致（换源/换分辨率）⇒ 回落预测 renderSize', () {
      expect(
        vsrTruthPriority(
            truthGrid: (3600, 2025),
            truthKey: keyA,
            newKey: keyB,
            renderSize: (3600, 2040)),
        (3600, 2040),
      );
    });

    test('真值为空 ⇒ 回落预测（与 1.08.86 行为等值）', () {
      expect(
        vsrTruthPriority(
            truthGrid: null,
            truthKey: null,
            newKey: keyA,
            renderSize: (3600, 2024)),
        (3600, 2024),
      );
    });

    test('真值非空但键为空 ⇒ 一律回落预测（防无签名误用）', () {
      expect(
        vsrTruthPriority(
            truthGrid: (3600, 2025),
            truthKey: null,
            newKey: keyA,
            renderSize: (3600, 2024)),
        (3600, 2024),
      );
    });

    test('真值网格有但键为空 ⇒ 回落预测（链状态翻转致键失效的保守侧）', () {
      expect(
        vsrTruthPriority(
            truthGrid: (3600, 2025),
            truthKey: null,
            newKey: 'x',
            renderSize: (3600, 2024)),
        (3600, 2024),
      );
    });

    test('真值键非空但网格为空 ⇒ 回落预测（两者必须同时在场）', () {
      expect(
        vsrTruthPriority(
            truthGrid: null,
            truthKey: keyA,
            newKey: keyA,
            renderSize: (3600, 2024)),
        (3600, 2024),
      );
    });

    test('预测与真值均为 null ⇒ null（链关/不可得）', () {
      expect(
        vsrTruthPriority(
            truthGrid: null, truthKey: null, newKey: keyA, renderSize: null),
        isNull,
      );
    });

    test('vsrChainKey：任一分量变化即换键（倍数/裁切/源高/比）', () {
      final base = vsrChainKey(
          scale: 3.75, crop: '3600:2024:0:0', srcH: 540, aspect: 16 / 9);
      expect(
          base,
          vsrChainKey(
              scale: 3.75, crop: '3600:2024:0:0', srcH: 540, aspect: 16 / 9));
      expect(
          base ==
              vsrChainKey(
                  scale: 4.0, crop: '3600:2024:0:0', srcH: 540, aspect: 16 / 9),
          isFalse);
      expect(
          base == vsrChainKey(scale: 3.75, crop: '', srcH: 540, aspect: 16 / 9),
          isFalse);
      expect(
          base ==
              vsrChainKey(
                  scale: 3.75, crop: '3600:2024:0:0', srcH: 544, aspect: 16 / 9),
          isFalse);
      expect(
          base ==
              vsrChainKey(
                  scale: 3.75, crop: '3600:2024:0:0', srcH: 540, aspect: 4 / 3),
          isFalse);
      expect(vsrChainKey(scale: null, crop: '', srcH: 540, aspect: 16 / 9),
          '-||540|1.777778');
    });
  });
}
