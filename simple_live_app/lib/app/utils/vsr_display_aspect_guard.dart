/// C3 R3 ⑤（批次 B / 1.08.84）：VSR「终态显示比 / 由其派生的面板几何」写入的
/// **校正器守卫**（纯逻辑，无副作用，便于单测）。
///
/// 背景（v3.3 ISS-294 P1-2）：应用级校正器一旦按**实测** dw/dh 比写过 `_vsrDisplayAspect`
/// （`_vsrCorrectorFired`），随后的尺寸/布局事件（W3/W4/W5）不得再用**假说比**
/// （按源尺寸推导）把它冲回——否则刚校正的面板宽被打回假说值 → 房 B 黑边复现；
/// 保持实测比直到代际重置（`_resetLastVoutDwh`）。锁只在「链已挂」时有意义：
/// VSR 关（链未挂/已摘）时 `_vsrDisplayAspect` 必须能正常置 null / 由假说比预写
/// （toggle 路径），故合取式为「fired ∧ 链已挂」才锁。
///
/// 抽出动机（§11.3 N6 / §11.4 ⑤ / §11.6 C-5）：该守卫**合取式**在全仓仅两个调用点
/// （`player_controller.dart` 的 `_syncRtxVsrCrop` 显示比缓存路径、
/// `_applyRtxVsrSetting` toggle Rx 预写路径），且都在 `PlayerController` 内——
/// `test/` 下无法对 PlayerController 建单测（需 Flutter binding + media_kit
/// native assets）⇒ 按仓内惯例（`vsr_replay_policy.dart` 纯函数下沉 utils）
/// 才可测。**语义等价、零行为变**（原式 `!(fired && applied)` 直译）；
/// 禁快照字段、禁回退分支（M4/N6）。
///
/// 本文件只依赖 dart:core，可脱离 Flutter 环境 `dart run` 实跑。
library;

/// 是否允许写入「VSR 终态显示比 / 由其派生的面板几何」。
///
/// - [correctorFired]：应用级校正器是否已按实测比写过显示比（`_vsrCorrectorFired`）。
/// - [chainApplied]：VSR 滤镜链当前是否已挂（`_rtxVsrChainApplied`）。
///
/// 返回 `false` = **锁住**（校正器已 fired ∧ 链已挂）⇒ 保持实测比直到代际重置；
/// 返回 `true` = 放行写入（未 fired，或链未挂/已摘）。
bool vsrDisplayAspectWritable({
  required bool correctorFired,
  required bool chainApplied,
}) =>
    !(correctorFired && chainApplied);

/// 1.08.86（ISS-315）：面板几何「比例载体」的选择——**纯逻辑**，便于单测。
///
/// 背景：面板几何（`videoWidthRx/videoHeightRx`）在全仓只被当作**比值**消费
/// （`panel_width.dart` 的 `desiredPlayerWidth = playerHeight × (w/h)`）。此前的载体是
/// 「源高网格」`(round(h×aspect), h)`（h = 源高，如 544）→ 960x544 房 B 得 (968, 544)，
/// 比值 1.779412 比渲染面真实比 3600/2024 = 1.778656 大 4.25‱ → 面板物理宽
/// 1891×968/544 = 3364.42、视频显示宽 1891×3600/2024 = 3362.99 → **余量 1.43px**
/// → 真机左右各 1px 细黑边（ISS-315）。VSR 生效时改用**渲染面网格**
/// `(renderSize.$1, renderSize.$2)`：面板框与视频显示落在**同一实数** ⇒ 取整确定性同向
/// ⇒ 余量归零（dart 复算；系统性 1.43px → 仅剩 x.5 边界的浮点残差 ~7e-5）。
///
/// - [windows]：仅 Windows 走 VSR 几何（与调用点原门控一致）；
/// - [renderSize]：VSR 生效时的渲染面尺寸（`plan.renderSize`），非空即优先；
/// - [aspect]/[w]/[h]：回落旧盘（源高网格）用；aspect 与 h 不可得时原样返回 `(w, h)`。
(int, int) vsrPanelGrid({
  required bool windows,
  required (int, int)? renderSize,
  required int? w,
  required int? h,
  required double? aspect,
}) {
  if (windows && renderSize != null) return renderSize;
  if (windows && aspect != null && h != null && h > 0) {
    return ((h * aspect).round(), h);
  }
  return (w ?? 0, h ?? 0);
}

/// 1.08.87（ISS-316）：**链签名**——用于判定「面板网格真值是否过期」。
///
/// 字段＝倍数 + 裁切值 + 源高 + 理想比；任一分量变化（换源 / 换分辨率 / toggle /
/// 热切清晰度）⇒ 新目标 ⇒ 真值作废、回落预测。
String vsrChainKey({
  required double? scale,
  required String crop,
  required int srcH,
  required double aspect,
}) =>
    '${scale?.toStringAsFixed(2) ?? '-'}|$crop|$srcH|${aspect.toStringAsFixed(6)}';

/// 1.08.87（ISS-316）：**真值优先**策略（纯逻辑，便于单测）——写链/镜像重写网格时，
/// 若当前链签名与采纳真值时的签名一致，则用**真值网格**（mpv 真实 `dw/dh`，如 3600x2025）；
/// 否则回落 `renderSize`（`_evenFloor` 预测，如 3600x2024，仅作首笔/新目标过渡）。
///
/// 读安全：真值为空或签名不匹配 ⇒ 一律回落预测（与 1.08.86 行为等值）。
(int, int)? vsrTruthPriority({
  required (int, int)? truthGrid,
  required String? truthKey,
  required String newKey,
  required (int, int)? renderSize,
}) {
  if (truthGrid != null && truthKey != null && truthKey == newKey) {
    return truthGrid;
  }
  return renderSize;
}
