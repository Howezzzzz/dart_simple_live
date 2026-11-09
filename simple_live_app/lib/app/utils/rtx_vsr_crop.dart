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

/// VSR 滤镜的放大倍数（与 player_controller 里 `vf=d3d11vpp=scale=…` 保持一致）。
const int rtxVsrScale = 2;

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
String rtxVsrVideoCrop(int width, int height, {int scale = rtxVsrScale}) {
  final pad = rtxVsrBottomPadRows(width, height);
  if (pad <= 0) return '';
  return '${width * scale}x${(height - pad) * scale}+0+0';
}

/// 供 UI 布局使用的「显示高度」：VSR 补边裁切生效时去掉底部补边（如 544 → 540）。
///
/// 播放区按上报的视频尺寸比例自适应（目标：无黑边）。裁切后画面真实比例是
/// 「去掉补边」的比例（16:9），若仍按补边高度上报，播放区会偏「高」→ 裁切后上下留黑边。
/// 裁切不生效时原样返回。
int rtxVsrDisplayHeight(int width, int height) {
  final pad = rtxVsrBottomPadRows(width, height);
  return pad > 0 ? height - pad : height;
}
