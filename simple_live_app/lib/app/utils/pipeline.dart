// C3 真·统一入口：期望态 / 已应用态 / 变更意图 的值对象与纯 diff。
//
// 定位（实施卡《方案-20261114-C3统一入口实施卡.md》§三 / 母文档附录 A.4）：
// - 本文件是 **纯逻辑层**：只描述、不驱动。PipelineChange 仅用于留痕与 PARITY 对照，
//   绝不短路、绝不跳过分派——中枢委派依旧无条件入队，内层幂等机制原样保留
//   （三条例证见实施卡 §三：①vsr 门控期是「吞写聚合」，外层 diff 无法预测最终动作；
//   ②vsr 三层签名去重与 norm 比较式短路不同构，外层判空会漏写；③中枢短路只作
//   R4 迁移完成后的评估项）。
// - 纯函数输入刻意与 player_controller.dart 的决策路径**同源同公式**：diff 内部的
//   rtxVsrPlan 重算使用与 _syncRtxVsrCrop 相同的 enabled（=已应用链状态）与相同的
//   源尺寸/播放区入参，保证「diff 镜像 ≈ controller 实际决策」，PARITY 才可对照。
//
// PARITY 锚点约定（实施卡 §五.2 映射表）：
// - 有直接日志锚点的字段：volumeNormApplied / rtxVsrChainApplied / lastRtxVsrScale /
//   vsrDesiredCrop / 门控态 → fail-loud 直接对照。
// - 无直接锚点的字段：vsrDisplayAspect / lastRtxVsrSignature → **组件展开形式**输出
//   （serializeApplied 给出原值 + 可重算组件，对照按组件级）。
// - pipelineDiff 是镜像层：侧偏保守，宁可多报「期望动作」也不隐含任何执行承诺。

import 'rtx_vsr_crop.dart';

/// 期望态：用户开关 + 平台 + 播放器事实（不含应用结果）。
///
/// 注意：本类**不是**独立期望源——字段与 pc.dart 决策路径同源（开关读
/// AppSettingsController、能力读 PlayerMixin.afLoudnormSupported、源尺寸读
/// _trueSourceSize、播放区读 _playerAreaPhysicalSize），仅作 diff/留痕镜像。
class PipelineDesired {
  const PipelineDesired({
    required this.volumeNormUserOn,
    required this.vsrUserOn,
    required this.isWindows,
    required this.srcW,
    required this.srcH,
    this.areaW,
    this.areaH,
    required this.afLoudnormSupported,
    required this.vsrGateApplicable,
  });

  /// 音量均衡用户开关。
  final bool volumeNormUserOn;

  /// VSR 用户开关（仅 Windows 有意义）。
  final bool vsrUserOn;

  /// 平台判据（vsr 链只在 Windows 存在）。
  final bool isWindows;

  /// 真源尺寸（解码器输出，不受 aspect 覆盖污染；0/负 = 未知）。
  final int srcW;
  final int srcH;

  /// 播放区物理尺寸（null = 不可得，rtxVsrPlan 走固定 2x 兜底）。
  final int? areaW;
  final int? areaH;

  /// loudnorm 能力（null = 未知、需探测）。
  final bool? afLoudnormSupported;

  /// 起播门控是否适用于本场景（=vsrShouldDeferPlay 的结果，上下文留痕用）。
  final bool vsrGateApplicable;
}

/// 已应用态 · 即时聚合视图。
///
/// 每次从 pc.dart 现字段**即时构造**、不复制存储（实施卡 §三/RV-2、FV3-4）：
/// 它是「读视图」，不是事实源副本；R4 的写权收拢后其读值来自唯一写点/豁免路径，
/// 但本类自身不持有任何存储。
class PipelineApplied {
  const PipelineApplied({
    required this.volumeNormApplied,
    required this.rtxVsrChainApplied,
    required this.lastRtxVsrScale,
    required this.vsrDesiredCrop,
    required this.vsrDisplayAspect,
    required this.lastRtxVsrSignature,
    required this.gateArmed,
  });

  /// norm：af 链已挂。
  final bool volumeNormApplied;

  /// vsr：链标志（本房是否启用 VSR：门控期即置 true——plan 按「开」算）。
  final bool rtxVsrChainApplied;

  /// vsr：mpv 实际已挂链记录（null = 未挂；跨 open 存活，摘链判断依赖其非空）。
  final double? lastRtxVsrScale;

  /// vsr：期望裁切（目标态；重试守卫用「目标未变」比较）。
  final String vsrDesiredCrop;

  /// vsr：面板显示比例缓存（VSR 生效时非空；C5 面板宽一次到位）。
  final double? vsrDisplayAspect;

  /// vsr：去重签名（scale|crop|源尺寸|链状态 拼接；10 处使用点，R4 枚举样本）。
  final String? lastRtxVsrSignature;

  /// 门控态：起播门控是否武装（_vsrDeferPlay）。
  final bool gateArmed;
}

/// norm 侧变更意图（仅描述）。
enum VolumeNormAction {
  /// 需挂链（enable=true）——对应用户开 ∧ 能力 true 且当前未挂。
  applyEnable,

  /// 需摘链（enable=false）——对应用户关且当前已挂。
  applyDisable,

  /// 能力未知 → 需探测。
  probe,

  /// 无需动作（能力为 false 或已收敛）。
  none,
}

/// vsr 侧变更意图（仅描述）。
class PipelineVsrIntent {
  const PipelineVsrIntent({
    required this.action,
    this.scale,
    this.crop = '',
    required this.chain,
    this.deferred = false,
  });

  /// 动作标签：
  /// - 'size-unknown'：源尺寸未知（0/负）——controller 的 _syncRtxVsrCrop 此时**早退不动作**，
  ///   diff 如实标记（避免把 rtxVsrPlan 对未知尺寸返回的 applied:false 误描述成 remove-vf，R1V-1）；
  /// - 'deferred'：门控期聚合（不写，等放行单次写——diff 只描述不驱动）；
  /// - 'set-vf'：期望写链；
  /// - 'remove-vf'：期望摘链；
  /// - 'crop-only'：链不变、裁切需更新；
  /// - 'none'：与已应用一致。
  final String action;
  final double? scale;
  final String crop;
  final bool chain;

  /// 门控期标记（gateArmed=true 时的期望载荷）。
  final bool deferred;
}

/// 变更意图汇总（仅描述、不驱动）。
class PipelineChange {
  const PipelineChange({required this.normAction, this.normEnable, this.vsrIntent});

  final VolumeNormAction normAction;

  /// norm 动作带 enable 语义时给出目标（applyEnable=true / applyDisable=false）。
  final bool? normEnable;
  final PipelineVsrIntent? vsrIntent;

  /// 快判「无实质变更意图」（仅供日志读感，**不用于跳过分派**）。
  ///
  /// vsr 侧 'none'（与已应用一致）与 'size-unknown'（尺寸未知不动作）均视为无事——
  /// 修复 A6V-2：原实现 Windows 下 vsrIntent 恒非空 → isEmpty 恒 false，读感失真。
  bool get isEmpty =>
      normAction == VolumeNormAction.none &&
      (vsrIntent == null ||
          vsrIntent!.action == 'none' ||
          vsrIntent!.action == 'size-unknown');
}

/// 计算 vsr 期望意图（纯函数）。
///
/// [enabled] 传**已应用链状态**（与 _syncRtxVsrCrop 内 rtxVsrPlan 调用同源）：
/// diff 并非独立期望源，而是 controller 决策路径的镜像。
PipelineVsrIntent? _vsrIntentFrom({
  required bool isWindows,
  required bool gateArmed,
  required RtxVsrPlan plan,
  required PipelineApplied applied,
}) {
  if (!isWindows) {
    return null;
  }
  // 门控期：期望载荷标记为 deferred（描述聚合语义，不预测放行后动作）。
  if (gateArmed) {
    return PipelineVsrIntent(
      action: 'deferred',
      scale: plan.scale,
      crop: plan.crop,
      chain: plan.applied,
      deferred: true,
    );
  }
  // 非门控期：镜像 _applyVsrTargetUnlocked 的 vfAction 判定（rtxVsrVfAction）。
  final (vfAction, _) = rtxVsrVfAction(
    enable: plan.applied,
    scale: plan.scale,
    currentScale: applied.lastRtxVsrScale,
  );
  if (vfAction == 'set') {
    return PipelineVsrIntent(
      action: 'set-vf',
      scale: plan.scale,
      crop: plan.crop,
      chain: plan.applied,
    );
  }
  if (vfAction == 'clear') {
    // rtxVsrVfAction 返回约定：'none'|'set'|'clear'（clear=摘链）——修正镜像臂名（FV4-4 用例捕获）。
    return PipelineVsrIntent(
      action: 'remove-vf',
      scale: null,
      crop: plan.crop,
      chain: false,
    );
  }
  // vf 'none'：链无需动；看裁切是否要更新。
  if (plan.crop != applied.vsrDesiredCrop) {
    return PipelineVsrIntent(
      action: 'crop-only',
      scale: plan.scale,
      crop: plan.crop,
      chain: plan.applied,
    );
  }
  return PipelineVsrIntent(
    action: 'none',
    scale: plan.scale,
    crop: plan.crop,
    chain: plan.applied,
  );
}

/// 主 diff：期望态 × 已应用态 → 变更意图（纯函数，无副作用）。
///
/// norm 侧逻辑对齐 `_syncVolumeNormLocked` + `_applyVolumeNormUnlocked`：
/// - 能力未知 → probe；
/// - 用户开 ∧ 能力 true ∧ 未挂 → applyEnable；
/// - 用户关 ∧ 已挂 → applyDisable；
/// - 能力 false（已知不支持）→ none（保险短路）。
/// vsr 侧逻辑对齐 `_syncRtxVsrCrop`（plan.enabled = 已应用链状态）+ 
/// `_applyVsrTargetUnlocked` 的 vfAction 判定。
PipelineChange pipelineDiff(PipelineDesired desired, PipelineApplied applied) {
  // --- norm 侧 ---
  var normAction = VolumeNormAction.none;
  bool? normEnable;
  final cap = desired.afLoudnormSupported;
  if (cap == null) {
    normAction = VolumeNormAction.probe;
  } else if (desired.volumeNormUserOn && cap == true) {
    if (!applied.volumeNormApplied) {
      normAction = VolumeNormAction.applyEnable;
      normEnable = true;
    }
  } else if (!desired.volumeNormUserOn && applied.volumeNormApplied) {
    normAction = VolumeNormAction.applyDisable;
    normEnable = false;
  }
  // cap == false ∧ 用户开：none（已知不支持，保险短路，与 _applyVolumeNormUnlocked 一致）。

  // --- vsr 侧 ---
  PipelineVsrIntent? vsrIntent;
  if (desired.isWindows) {
    // 与 _syncRtxVsrCrop 对齐：源尺寸未知（0/负）时 controller **早退不动作**——
    // diff 如实标记 size-unknown（R1V-1：若交由 rtxVsrPlan 计算会把未知尺寸的
    // applied:false 误描述成 remove-vf，而实际没有摘链动作）。
    if (desired.srcW <= 0 || desired.srcH <= 0) {
      vsrIntent = PipelineVsrIntent(
        action: 'size-unknown',
        scale: null,
        crop: applied.vsrDesiredCrop,
        chain: applied.rtxVsrChainApplied,
      );
    } else {
      // plan 重算：enabled 用已应用链状态（与 _syncRtxVsrCrop 同输入同公式，
      // 保证镜像一致）。
      final plan = rtxVsrPlan(
        enabled: applied.rtxVsrChainApplied,
        areaW: desired.areaW,
        areaH: desired.areaH,
        srcW: desired.srcW,
        srcH: desired.srcH,
      );
      vsrIntent = _vsrIntentFrom(
        isWindows: desired.isWindows,
        gateArmed: applied.gateArmed,
        plan: plan,
        applied: applied,
      );
    }
  }

  return PipelineChange(normAction: normAction, normEnable: normEnable, vsrIntent: vsrIntent);
}

/// PARITY 对照用：Applied 的字段级 dump（组件展开形式）。
///
/// aspect/signature 无直接日志锚点（FV3-3）：以「原值 + 可重算组件」双列输出，
/// 对照按组件级（aspect↔源尺寸×链状态经 rtxVsrDisplayAspect 重算；
/// signature↔源尺寸/scale/crop/链状态四元组）。
String serializeApplied(PipelineDesired desired, PipelineApplied a) {
  final buf = StringBuffer()
    ..write('norm.applied=${a.volumeNormApplied}')
    ..write(' vsr.chain=${a.rtxVsrChainApplied}')
    ..write(' vsr.scale=${a.lastRtxVsrScale?.toStringAsFixed(2) ?? "-"}')
    ..write(' vsr.cropEncoder=${a.vsrDesiredCrop}')
    ..write(' gate.armed=${a.gateArmed}');
  // aspect：原值 + 组件重算（rtxVsrDisplayAspect(源) @ VSR 生效时）。
  if (a.vsrDisplayAspect != null) {
    final recomputed = (a.rtxVsrChainApplied && desired.srcW > 0 && desired.srcH > 0)
        ? rtxVsrDisplayAspect(desired.srcW, desired.srcH)
        : null;
    buf
      ..write(' vsr.aspect=${a.vsrDisplayAspect!.toStringAsFixed(4)}')
      ..write(' (recompute=${recomputed?.toStringAsFixed(4) ?? "-"} src=${desired.srcW}x${desired.srcH})');
  } else {
    buf.write(' vsr.aspect=-');
  }
  // signature：展开四元组（原串本身无日志锚点，输出组件供对照）。
  buf
    ..write(' vsr.signature=')
    ..write(a.lastRtxVsrSignature ?? '-');
  if (a.lastRtxVsrSignature != null) {
    buf
      ..write(' (scale=${a.lastRtxVsrScale?.toStringAsFixed(2) ?? "-"}'
          ' crop="${a.vsrDesiredCrop}" src=${desired.srcW}x${desired.srcH}'
          ' chain=${a.rtxVsrChainApplied})');
  }
  return buf.toString();
}