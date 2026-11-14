// C3 R1：pipeline.dart 纯逻辑单测。
//
// 覆盖（实施卡 §三）：字段级 diff 规则 + 代表性状态组合烟测。
// - norm 侧决策表：能力（null/true/false）× 用户开关 × applied 4 态全测；
// - vsr 侧：门控态/链状态/scale/crop 组合 + vfAction 镜像；
// - serializeApplied：组件展开形式（aspect/signature 无直接日志锚点，FV3-3）。
//
// 原则：diff 是**镜像层**（不驱动、不短路）——本文件只验证「diff 描述与
// pc.dart 决策路径同源同公式」，不断言任何执行行为。

import 'package:flutter_test/flutter_test.dart';

import 'package:simple_live_app/app/utils/pipeline.dart';
import 'package:simple_live_app/app/utils/rtx_vsr_crop.dart';

/// 默认期望态（Windows + VSR 开 + 支持能力 + 有效源）——各用例按需覆盖。
PipelineDesired desired({
  bool normOn = true,
  bool vsrOn = true,
  bool isWindows = true,
  int srcW = 960,
  int srcH = 544,
  int? areaW = 1920,
  int? areaH = 1080,
  bool? cap = true,
  bool gateApplicable = true,
}) =>
    PipelineDesired(
      volumeNormUserOn: normOn,
      vsrUserOn: vsrOn,
      isWindows: isWindows,
      srcW: srcW,
      srcH: srcH,
      areaW: areaW,
      areaH: areaH,
      afLoudnormSupported: cap,
      vsrGateApplicable: gateApplicable,
    );

/// 默认已应用态——各用例按需覆盖。
PipelineApplied applied({
  bool normApplied = false,
  bool chain = false,
  double? scale,
  String crop = '',
  double? aspect,
  String? signature,
  bool gateArmed = false,
}) =>
    PipelineApplied(
      volumeNormApplied: normApplied,
      rtxVsrChainApplied: chain,
      lastRtxVsrScale: scale,
      vsrDesiredCrop: crop,
      vsrDisplayAspect: aspect,
      lastRtxVsrSignature: signature,
      gateArmed: gateArmed,
    );

void main() {
  group('norm 侧决策表（对齐 _syncVolumeNormLocked + _applyVolumeNormUnlocked）', () {
    test('能力未知 → probe（无论开关/applied）', () {
      for (final normOn in [true, false]) {
        for (final normApplied in [true, false]) {
          final c = pipelineDiff(
            desired(normOn: normOn, cap: null),
            applied(normApplied: normApplied),
          );
          expect(c.normAction, VolumeNormAction.probe,
              reason: 'normOn=$normOn applied=$normApplied');
          expect(c.normEnable == null, true);
        }
      }
    });

    test('能力 true + 用户开 ∧ 未挂 → applyEnable(true)', () {
      final c = pipelineDiff(desired(normOn: true), applied(normApplied: false));
      expect(c.normAction, VolumeNormAction.applyEnable);
      expect(c.normEnable, true);
    });

    test('能力 true + 用户开 ∧ 已挂 → none（收敛）', () {
      final c = pipelineDiff(desired(normOn: true), applied(normApplied: true));
      expect(c.normAction, VolumeNormAction.none);
      expect(c.normEnable == null, true);
    });

    test('能力 true + 用户关 ∧ 已挂 → applyDisable(false)', () {
      final c = pipelineDiff(desired(normOn: false), applied(normApplied: true));
      expect(c.normAction, VolumeNormAction.applyDisable);
      expect(c.normEnable, false);
    });

    test('能力 true + 用户关 ∧ 未挂 → none', () {
      final c = pipelineDiff(desired(normOn: false), applied(normApplied: false));
      expect(c.normAction, VolumeNormAction.none);
    });

    test('能力 false（已知不支持）→ none（保险短路，即使用户开）', () {
      final c = pipelineDiff(desired(normOn: true, cap: false), applied());
      expect(c.normAction, VolumeNormAction.none);
    });

    test('probe 优先级高于 apply（能力未知 ∧ 已挂也先探测）', () {
      final c =
          pipelineDiff(desired(normOn: true, cap: null), applied(normApplied: true));
      expect(c.normAction, VolumeNormAction.probe);
    });
  });

  group('vsr 侧（对齐 _syncRtxVsrCrop + _applyVsrTargetUnlocked 镜像）', () {
    PipelineChange withVsr({
      required PipelineApplied a,
      bool normOn = false,
      bool vsrOn = true,
      int? areaW = 1920,
      int? areaH = 1080,
    }) =>
        pipelineDiff(
            desired(normOn: normOn, vsrOn: vsrOn, areaW: areaW, areaH: areaH), a);

    test('非 Windows → vsrIntent 为 null', () {
      final c = pipelineDiff(desired(isWindows: false), applied());
      expect(c.vsrIntent == null, true);
    });

    test('门控期 → deferred 意图（描述聚合，不预测动作）', () {
      final c = withVsr(a: applied(gateArmed: true));
      expect(c.vsrIntent != null, true);
      expect(c.vsrIntent!.deferred, true);
      expect(c.vsrIntent!.action, 'deferred');
    });

    test('非门控 + 链关 + 无 scale → plan.applied=false → 期望动作与 plan 一致', () {
      final c = withVsr(a: applied(chain: false, scale: null));
      // 源 960x544、播放区 1920x1080、chain=false → plan.applied=false（不挂）
      expect(c.vsrIntent!.action, 'none');
      expect(c.vsrIntent!.chain, false);
    });

    test('非门控 + 链开 + 已有同 scale → vf none + crop 同值 → none', () {
      final c = withVsr(a: applied(chain: true, scale: 2.0, crop: '1920x1080+0+0'));
      expect(c.vsrIntent!.action, 'none');
    });

    test('非门控 + 链开 + scale 不符 → set-vf（vfAction set 镜像）', () {
      // applied scale=null 而期望 scale 非空 → vfAction 'set'
      final c = withVsr(a: applied(chain: true, scale: null));
      expect(c.vsrIntent!.action, 'set-vf');
      expect(c.vsrIntent!.scale != null, true);
    });

    test('非门控 + 链关但 plan 认为应挂（由于 enabled 传递链状态）→ none（镜像同源）', () {
      // enabled 用 applied.chain（false）→ plan.applied=false → 期望不挂 → none。
      // 这验证「diff 用链状态而非用户开关当 enabled」（与 _syncRtxVsrCrop 同源）。
      final c = withVsr(a: applied(chain: false, scale: null));
      expect(c.vsrIntent!.chain, false);
      expect(c.vsrIntent!.action, 'none');
    });

    test('crop-only：vf none 但期望 crop ≠ applied crop', () {
      final c = withVsr(
        a: applied(chain: true, scale: 2.0, crop: 'OLD'),
      );
      // 期望 plan.crop 与 applied crop 不同 → crop-only
      expect(c.vsrIntent!.action, 'crop-only');
      expect(c.vsrIntent!.crop != 'OLD', true);
    });

    test('播放区不可得 → 固定 2x 兜底（area=null）', () {
      final c = withVsr(a: applied(chain: true, scale: null), areaW: null, areaH: null);
      expect(c.vsrIntent!.action, 'set-vf');
      expect(c.vsrIntent!.scale, rtxVsrScale);
    });
  });

  group('serializeApplied（组件展开，FV3-3）', () {
    test('核心字段直接输出', () {
      final s = serializeApplied(
        desired(),
        applied(normApplied: true, chain: true, scale: 2.0, crop: 'A', aspect: 1.5),
      );
      expect(s.contains('norm.applied=true'), true);
      expect(s.contains('vsr.chain=true'), true);
      expect(s.contains('vsr.scale=2.00'), true);
      expect(s.contains('vsr.cropEncoder=A'), true);
    });

    test('aspect：原值 + 组件重算（recompute=）', () {
      final s = serializeApplied(
        desired(srcW: 960, srcH: 544),
        applied(chain: true, scale: 2.0, crop: '', aspect: 1.75),
      );
      expect(s.contains('vsr.aspect=1.7500'), true);
      expect(s.contains('recompute='), true); // 组件重算值存在
    });

    test('signature：展开四元组', () {
      final s = serializeApplied(
        desired(srcW: 960, srcH: 544),
        applied(
            chain: true,
            scale: 2.0,
            crop: 'X',
            signature: '2.0|X|960x544|true'),
      );
      expect(s.contains('vsr.signature=2.0|X|960x544|true'), true);
      expect(s.contains('src=960x544'), true);
      expect(s.contains('chain=true'), true);
    });

    test('aspect 无值时输出 -', () {
      final s = serializeApplied(desired(), applied());
      expect(s.contains('vsr.aspect=-'), true);
    });

    test('signature 为 null 输出 -', () {
      final s = serializeApplied(desired(), applied());
      expect(s.contains('vsr.signature=-'), true);
    });
  });

  group('isEmpty（仅日志读感，不用于短路）', () {
    test('norm none + vsrIntent null → isEmpty', () {
      final c = pipelineDiff(desired(isWindows: false, normOn: false), applied());
      // 用户关 ∧ 未挂 → none；非 Windows → vsr null
      expect(c.isEmpty, true);
    });

    test('非空场景回 false', () {
      final c = pipelineDiff(desired(normOn: true), applied());
      expect(c.isEmpty, false);
    });
  });
}