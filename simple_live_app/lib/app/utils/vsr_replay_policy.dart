/// v3.5 C1：VSR 写链**应用级修因策略**（纯逻辑，无副作用，便于单测）。
///
/// 背景：mpv 的 `video-crop` 在「旧的 scale 帧」上越界会被**静默丢弃**
/// （日志 `Ignoring invalid --video-crop=… for … image`）且**永不自动重放**
/// → VO 滞留未裁满帧 → mpv/Flutter contain 出四边黑带。
/// C2「写链定序」从源头规避（等新 scale 帧落定再下发 crop）；C1 应用级修因兜底：
/// 判据不再是「属性回读」（只能证属性被接受、证不了 VO 逐帧应用——Gen-1/16:31 漏检盲区），
/// 而是 **dw/dh 比 == crop 目标比**；触发时机改为**条件式**——只有观测到「新 scale 帧真
/// 落定」才重放（不按固定延迟猜），避免重放又落在落定之前被丢弃。
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

/// 期望的**新 scale** out `(dw, dh)` 候选**对**集合（成对，避免「宽取一态、高取另一态」的
/// 交叉积误判——A-1 复核项）。
///
/// - `(rawW*s, rawH*s)`：crop **未**生效的新 scale 满帧；
/// - `(renderW, renderH)`：crop **已**生效态（若提供 renderSize）。
///
/// 两者都算「新 scale 已落定」——本判据只用于回答「VO 是否已切到新 scale」，crop 是否应用
/// 另由 [vsrOutAppliedCrop] 判。`scale` 为空 / 尺寸非法 → null（不布防）。
Set<(int, int)>? vsrExpectedOutPairs({
  required int rawW,
  required int rawH,
  required double? scale,
  int? renderW,
  int? renderH,
}) {
  if (scale == null || rawW <= 0 || rawH <= 0) return null;
  final pairs = <(int, int)>{((rawW * scale).round(), (rawH * scale).round())};
  if (renderW != null && renderH != null && renderW > 0 && renderH > 0) {
    pairs.add((renderW, renderH));
  }
  return pairs;
}

/// v3.5 C1 应用级修因是否应触发**重放**（**条件式**，取代原「静默门 + 固定延迟」）。
///
/// 条件：链已挂 ∧ crop 目标非空 ∧ 预算 > 0 ∧ **尚未应用** ∧ **新 scale 已落定**（[landed]，
/// 由调用方按 `expectedPairs.contains(cur)` 判定）∧ 尺寸稳定 ≥ [stable] ∧ 距上次重放 ≥
/// [cooldown]（防同帧重复写）。
///
/// 关键：`landed` 为真才重放——写在与新 scale 匹配的帧上，crop 才不会被 mpv 丢弃。
/// （原实现按固定 250/600/1200ms 猜时机，与「落定 ≈2s」尺度不符，可能全被打空。）
bool vsrShouldRepair({
  required bool chainApplied,
  required String crop,
  required bool applied,
  required bool landed,
  required Duration? stableFor,
  required Duration? sinceRepair,
  required Duration stable,
  required Duration cooldown,
  required int budgetLeft,
}) {
  if (!chainApplied || crop.isEmpty || budgetLeft <= 0) return false;
  if (applied) return false;
  if (!landed) return false;
  if (stableFor == null || stableFor < stable) return false;
  if (sinceRepair != null && sinceRepair < cooldown) return false;
  return true;
}

/// 应用级修因的**绝对兜底**判定：链已挂 ∧ 有 crop 目标 ∧ 仍未被应用 ∧ 校正器在等兜底
/// （[correctorPending]）∧ 距最近一次「修因进度」已超 [maxWait]。
///
/// 注意（v3.5c 复核 C-1 修复）：**不以「预算耗尽」为前提**——预算只在「已落定」时递减，
/// 若因落定判据失配而永不重放，预算恒 >0，旧实现会短路掉兜底 → pending 永挂。
/// 故改锚「进度时长」（调用方传 `now - max(最后链写, 最后重放)`），任一路径 8s 无进展即兜底。
bool vsrFallbackDue({
  required bool chainApplied,
  required String crop,
  required bool applied,
  required bool correctorPending,
  required Duration? sinceProgress,
  required Duration maxWait,
}) {
  if (!chainApplied || crop.isEmpty) return false;
  if (applied || !correctorPending) return false;
  if (sinceProgress == null || sinceProgress < maxWait) return false;
  return true;
}

/// 观测 `(dw,dh)` 是否落在期望候选对之一的 **[tolPx] 像素容差**内（v3.5c 复核 B-1 修复）。
/// 原判据用整数精确相等，mpv 侧 scale/对齐的一像素偏差即让「已落定」永不为真 → 修因哑火；
/// 改为像素容差匹配（与全链路 0.005 比值容差同精神）。
bool vsrMatchesPair(Set<(int, int)>? pairs, (int, int) v, int tolPx) {
  if (pairs == null) return false;
  for (final p in pairs) {
    if ((v.$1 - p.$1).abs() <= tolPx && (v.$2 - p.$2).abs() <= tolPx) {
      return true;
    }
  }
  return false;
}
