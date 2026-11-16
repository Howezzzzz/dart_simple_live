/// v3.5 C1：VSR 写链**重放策略**（纯逻辑，无副作用，便于单测）。
///
/// 背景：mpv 的 `video-crop` 在「旧的 scale 帧」上越界会被**静默丢弃**
/// （日志 `Ignoring invalid --video-crop=… for … image`）且**永不自动重放**
/// → VO 滞留未裁满帧 → mpv/Flutter contain 出四边黑带。
/// C2「写链定序」从源头规避（等新 scale 帧落定再下发 crop）；C1 应用级 watchdog 兜底：
/// 判据不再是「属性回读」（只能证属性被接受、证不了 VO 逐帧应用——Gen-1/16:31 漏检盲区），
/// 而是 **dw/dh 比 == crop 目标比**。
///
/// 本文件只依赖 dart:core（Duration 等），可脱离 Flutter 环境 `dart run` 实跑。
library;

/// 解析 mpv `video-crop` 值（格式 `WxH+X+Y`，如 `3600x2024+0+0`）为宽高比。
/// 空串 / 格式异常 / 非正数 → null（无裁切源不参与目标比判据）。
double? vsrCropRatio(String crop) {
  if (crop.isEmpty) return null;
  final x = crop.indexOf('x');
  final plus = crop.indexOf('+');
  if (x <= 0 || plus <= x) return null;
  final w = double.tryParse(crop.substring(0, x));
  final h = double.tryParse(crop.substring(x + 1, plus));
  if (w == null || h == null || w <= 0 || h <= 0) return null;
  return w / h;
}

/// dw/dh 比是否已命中 crop 目标比（**应用级**判据，带容差）。
/// 任一输入非法 / 目标不可解析 → false（保守：不认为已应用）。
bool vsrOutAppliedCrop({
  required int dw,
  required int dh,
  required double? targetRatio,
  required double tolerance,
}) {
  if (dw <= 0 || dh <= 0 || targetRatio == null || targetRatio <= 0) {
    return false;
  }
  return ((dw / dh) - targetRatio).abs() <= tolerance;
}

/// 应用级 watchdog 是否应触发重放：
/// 链已挂 ∧ crop 目标非空 ∧ dw/dh 有效 ∧ dw/dh 比 ≠ 目标比（即 crop 未被 VO 应用）∧
/// 静默门（距最后一次链写 ≥ [quiet]）∧ 稳定门（dw/dh 连续 ≥ [stable] 不变）∧ 预算 > 0。
///
/// [sinceChainWrite] / [stableFor] 为「距链写的时长 / dw/dh 稳定时长」，null = 未知（视为未过门）。
bool vsrWatchdogShouldReplay({
  required bool chainApplied,
  required String crop,
  required int dw,
  required int dh,
  required Duration? sinceChainWrite,
  required Duration? stableFor,
  required Duration quiet,
  required Duration stable,
  required double tolerance,
  required int budgetLeft,
}) {
  if (!chainApplied || budgetLeft <= 0) return false;
  if (crop.isEmpty) return false;
  if (dw <= 0 || dh <= 0) return false;
  final target = vsrCropRatio(crop);
  if (target == null) return false;
  if (vsrOutAppliedCrop(
      dw: dw, dh: dh, targetRatio: target, tolerance: tolerance)) {
    return false; // 已应用 → 不重放
  }
  if (sinceChainWrite == null || sinceChainWrite < quiet) return false; // 静默门
  if (stableFor == null || stableFor < stable) return false; // 稳定门
  return true;
}
