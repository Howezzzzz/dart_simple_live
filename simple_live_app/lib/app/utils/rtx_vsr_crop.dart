import 'dart:math' as math;

// NVIDIA RTX VSR（Windows）底部补边裁切计算（纯逻辑，便于单测）。
//
// 背景（2026-11-09 实测，见 文件/Slive/证据/VSR绿条-20261109/）：
// 直播流的编码高度按 16 对齐补边（如 540p 内容实际帧高为 544），而 D3D11 视频处理器
// （NVIDIA RTX Super Resolution 扩展）只按“真实内容高度”写入输出：放大 2 倍后应写
// 1080 行，实际输出却是 1088 行 —— 最后 8 行未被写入，显示为未初始化的显存色（纯绿），
// 即画面底部那条绿条（实测：屏幕底部约 16 行、横贯视频区、RGB≈(0,77,0)，关掉 VSR 即消失）。
//
// 处理：用 mpv 的 `--video-crop`（官方文档：对硬解帧有效）把补边裁掉。
//
// ⚠️ 坐标空间（L3 独立复核发现的 P0，务必别改错）：
// mpv 的 `video-crop` 由 VO 在 `write_video()` 阶段应用到 `next_frames[]` —— 也就是
// **滤镜链之后**交给 VO 的帧（源码 `player/video.c: apply_video_crop()`：
// `m_rect_apply(&p.crop, p.w, p.h, gm)`，p 为该帧的 params）。
// 我们的 VSR 滤镜把画面放大了 [rtxVsrScale] 倍，所以裁切矩形必须按**放大后**的尺寸给。
// 若按“源尺寸”给（旧写法 960x540+0+0），会被当成在 1920x1088 帧里裁左上角一块 → 只剩 1/4 画面。
// 反过来，若实际帧不是放大后的尺寸，矩形会越界 → mpv 打印 "Ignoring invalid --video-crop"
// 并忽略该值（safe-fail），不会误裁。
//
// 已知限制（2026-11-09 两轮 L3 独立复核确认，均为“不误裁”方向的保守行为）：
// ① 判定基准取上报的“显示尺寸”（方像素、无旋转的流下等于编码尺寸）。旋转
//   （rotate=90/270，宽高互换）或 SAR≠1 的流上，裁切矩形可能越界 → mpv 逐帧拒绝
//   （safe-fail，不误裁），但该流上的绿条（补边此时在侧边）不会被修——直播竖屏流属此类。
// ② SAR≠1 且上报宽 < 存储宽（dw<w）的极端组合，理论上可能裁掉 ≤8 行真实边缘；
//   现实中直播流概率极低，记录备查。
//
// 判定规则（只把“编码 16 对齐补边”认作补边，避免误裁真实画面）：
//   ① 上报高度是 16 的整数倍（编码按 16 对齐的特征）
//   ② 比 16:9 基准高度多出 1~8 行
//   ③ 裁后高度为偶数（4:2:0 帧高必须为偶数；例如 848x480 裁后 477 是奇数 → 不是补边）
// 其他比例（4:3 等）一律不动。

/// VSR 滤镜的**默认**放大倍数（兜底用；自适应倍数见 [rtxVsrAdaptiveScale]）。
const double rtxVsrScale = 2.0;

/// 计算需要从画面底部裁掉的行数（**源尺寸**口径）；0 表示不需要裁切。
int rtxVsrBottomPadRows(int width, int height) {
  if (width <= 0 || height <= 0) return 0;
  // 编码按 16 对齐：上报高度必然 16 的整数倍，否则不是对齐补边
  if (height % 16 != 0) return 0;
  final ideal169Height = ((width * 9) / 16).round();
  final pad = height - ideal169Height;
  if (pad < 1 || pad > 8) return 0;
  // 4:2:0 要求帧高为偶数；裁后为奇数说明那不是对齐补边，而是真实画面
  if (ideal169Height % 2 != 0) return 0;
  return pad;
}

/// 生成 mpv `video-crop` 属性值，格式 `<W>x<H>+<x>+<y>`。
/// **注意坐标系**：mpv 由 VO 在滤镜之后应用，故这里返回的是**放大后**的尺寸
/// （`width*scale` / `(height-pad)*scale`），保留画面顶部、裁掉底部补边。
/// 无需裁切时返回空串（mpv 约定：空串=取消手动裁切、恢复容器裁切信息）。
String rtxVsrVideoCrop(int width, int height, {double scale = rtxVsrScale}) {
  final pad = rtxVsrBottomPadRows(width, height);
  if (pad <= 0) return '';
  // 非整数倍数下输出可能为奇数，4:2:0 色度要求偶数 → 向下取偶。
  return '${_evenFloor(width * scale)}x${_evenFloor((height - pad) * scale)}+0+0';
}

/// 向下取偶（4:2:0 帧尺寸要求）。
int _evenFloor(num v) => (v / 2).floor() * 2;

/// VSR 裁切生效时画面真实的显示比例（宽/高），如 960x544 → 960/540（16:9）。
///
/// 裁切后内容比例 ≠ 源补边比例，而 mpv 的渲染窗口（video-params 的 dw/dh）与界面布局都
/// 按「源比例」算 → 画面在窗口里上下留 2px（4K 下约 8px）黑边。把该真实比例通过
/// `video-aspect-override` 告诉 mpv 即可校正。无裁切时返回 null（调用方按源比例处理）。
double? rtxVsrDisplayAspect(int width, int height) {
  final pad = rtxVsrBottomPadRows(width, height);
  if (pad <= 0) return null;
  return width / (height - pad);
}

/// VSR 放大后的渲染尺寸（放大后、已裁掉底部补边），如 960x544@2 → 1920x1080。
///
/// 用于让 mpv 按此尺寸渲染（RISK-59）：否则 mpv 按“源尺寸”渲染，会把 VSR 放大成果
/// 缩回源尺寸再被 Flutter 拉大，放大丢失。尺寸非法或单边超 8192（sanity）时返回 null。
(int, int)? rtxVsrRenderSize(int width, int height,
    {double scale = rtxVsrScale}) {
  if (width <= 0 || height <= 0) return null;
  final pad = rtxVsrBottomPadRows(width, height);
  final outW = _evenFloor(width * scale);
  final outH = _evenFloor((height - pad) * scale);
  if (outW <= 0 || outH <= 0) return null;
  // sanity：单边超 8192 视为异常（显存/驱动上限），不设显式尺寸。
  if (outW > 8192 || outH > 8192) return null;
  return (outW, outH);
}

/// VSR 自适应倍数的上限（驱动/硬件经验上限）。
const double rtxVsrMaxScale = 4.0;

/// VSR 滤镜链字符串（倍数保留 2 位小数）。
String rtxVsrVfChain(double scale) =>
    'd3d11vpp=scale=${scale.toStringAsFixed(2)}:scaling-mode=nvidia';

/// 一次 VSR 同步的「决策结果」（纯逻辑，便于单测）。
class RtxVsrPlan {
  const RtxVsrPlan({
    required this.applied,
    this.scale,
    required this.crop,
    required this.aspect,
    this.renderSize,
  });

  /// 是否应挂 VSR 链（开了且倍数有效）。
  final bool applied;

  /// 实际使用的倍数（applied=false 时为 null）。
  final double? scale;

  /// mpv `video-crop` 值（空串 = 取消手动裁切）。
  final String crop;

  /// 显示比例（写 `video-aspect-override`）。
  final double aspect;

  /// 渲染画布尺寸（null = 恢复默认）。
  final (int, int)? renderSize;
}

/// 计算一次同步的决策（纯函数，无副作用）。
///
/// [enabled] 为链状态（用户开关）；[areaW]/[areaH] 为播放区物理尺寸（null = 不可得，走固定
/// 2x 兜底）；[srcW]/[srcH] 为源分辨率。
RtxVsrPlan rtxVsrPlan({
  required bool enabled,
  int? areaW,
  int? areaH,
  required int srcW,
  required int srcH,
}) {
  if (srcW <= 0 || srcH <= 0) {
    return const RtxVsrPlan(applied: false, crop: '', aspect: 1.0);
  }
  double? scale;
  if (enabled) {
    scale = (areaW == null || areaH == null)
        ? rtxVsrScale
        : rtxVsrAdaptiveScale(
            areaW: areaW, areaH: areaH, srcW: srcW, srcH: srcH);
  }
  final s = scale;
  final applied = enabled && s != null;
  final crop = applied ? rtxVsrVideoCrop(srcW, srcH, scale: s ?? rtxVsrScale) : '';
  final aspect =
      (applied ? rtxVsrDisplayAspect(srcW, srcH) : null) ?? (srcW / srcH);
  final renderSize = applied
      ? rtxVsrRenderSize(srcW, srcH, scale: s ?? rtxVsrScale)
      : null;
  return RtxVsrPlan(
    applied: applied,
    scale: s,
    crop: crop,
    aspect: aspect,
    renderSize: renderSize,
  );
}

/// 计算「自适应倍数」S：让 VSR 放大目标 ≈ 播放区物理分辨率（源低就多放大）。
///
/// 公式：`r = min(areaW/srcW, areaH/(srcH-pad))`——取 fit 比例，保证输出不超出播放区、
/// 避免二次上采样；**向上**取到 0.25 步长，夹取 [1, rtxVsrMaxScale]。
/// `r ≤ 1.05`（源已 ≥ 播放区，VSR 无意义）或参数非法或未裁切输出过大（>8192）
/// → 返回 null（调用方不挂 VSR）。
double? rtxVsrAdaptiveScale({
  required int areaW,
  required int areaH,
  required int srcW,
  required int srcH,
}) {
  if (areaW <= 0 || areaH <= 0 || srcW <= 0 || srcH <= 0) return null;
  final pad = rtxVsrBottomPadRows(srcW, srcH);
  final contentH = srcH - pad;
  if (contentH <= 0) return null;
  final r = math.min(areaW / srcW, areaH / contentH);
  if (r <= 1.05) return null;
  var s = (r / 0.25).ceilToDouble() * 0.25;
  if (s < 1.0) s = 1.0;
  if (s > rtxVsrMaxScale) s = rtxVsrMaxScale;
  // sanity：未裁切输出任一边过大（显存/驱动上限）→ 不挂。
  if (srcW * s > 8192 || srcH * s > 8192) return null;
  return s;
}
