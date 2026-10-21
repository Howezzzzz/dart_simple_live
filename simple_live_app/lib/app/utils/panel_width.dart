/// 右侧消息面板（直播间弹幕栏）宽度常量与计算（纯 Dart，无 Flutter 依赖，便于单元测试）。
///
/// 背景：桌面端直播间布局 = 左播放区 + 拖拽分隔条 + 右消息面板。面板宽度由
/// `AppSettingsController.messagePanelWidth` 控制，可由用户拖拽分隔条调节、
/// 也可由「按分辨率自适应」在进直播间后自动设置。
///
/// 历史问题（2026-10-17 Howe 反馈）：自适应算出的面板宽度若小于原下限 220，
/// 旧实现直接放弃、面板保持上一次的值 —— 于是窗口偏窄时画面留黑边、且不再
/// 自适应；同时 220 的下限偏大。现改为**始终夹逼到 [min, max]**：不足下限就
/// 设成下限（把播放区放到能放到的最大），不再「什么都不动」；下限由 220 调到
/// 180（Howe 2026-10-17 定）。
library;

import 'dart:math' as math;

/// 面板默认宽度（双击分隔条恢复该值）。
const double kMessagePanelDefaultWidth = 300.0;

/// 面板最小宽度（Howe 2026-10-17 定：由 220 下调到 180）。
const double kMessagePanelMinWidth = 180.0;

/// 面板最大宽度。
const double kMessagePanelMaxWidth = 800.0;

/// 播放区与面板之间的拖拽分隔条宽度（与 live_room_page 的 8px 保持一致）。
const double kPanelResizeHandleWidth = 8.0;

/// 按直播流分辨率计算右侧面板的目标宽度。
///
/// 计算方式（与自适应特性一致）：**播放区高度不变**，按直播流宽高比算出播放区
/// 应有的宽度，余下空间留给右侧面板：
///
/// ```
/// desiredPlayerWidth = playerHeight * (videoWidth / videoHeight)
/// desiredPanel       = contentWidth - desiredPlayerWidth - handleWidth
/// ```
///
/// 结果恒夹在 [kMessagePanelMinWidth, kMessagePanelMaxWidth]：
/// - 窗口偏窄、算出结果低于下限时，返回下限（而不是放弃调整），使播放区尽可能大；
/// - 窗口很宽、算出结果超过上限时，返回上限。
///
/// 输入非有限值或非正（尺寸未就绪等）时返回 [kMessagePanelMinWidth]，调用方
/// 通常在此之前已做重试。
///
/// 不变式（见 test/panel_width_test.dart RT-108）：
/// - 任意有限输入，返回值恒落在 [min, max]；
/// - 未触界时结果等于按比例算出的期望宽度；
/// - 与返回值无关的越界输入不会抛异常。
double panelWidthForVideo({
  required double contentWidth,
  required double videoWidth,
  required double videoHeight,
  required double playerHeight,
  double handleWidth = kPanelResizeHandleWidth,
}) {
  if (!contentWidth.isFinite ||
      !videoWidth.isFinite ||
      !videoHeight.isFinite ||
      !playerHeight.isFinite ||
      videoWidth <= 0 ||
      videoHeight <= 0 ||
      playerHeight <= 0) {
    return kMessagePanelMinWidth;
  }
  final desiredPlayerWidth = playerHeight * (videoWidth / videoHeight);
  final desiredPanel = contentWidth - desiredPlayerWidth - handleWidth;
  return desiredPanel.clamp(kMessagePanelMinWidth, kMessagePanelMaxWidth);
}

/// 覆盖式判定的**滞回带宽**（px）：退出覆盖式要比进入多这么多余量，避免窗口边界反复穿越时闪跳。
const double kPanelOverlayHysteresis = 24.0;

/// `fill`/`cover` 缩放模式下为播放区保留的最小宽度（px）：视频铺满无黑边，但仍不允许面板把播放区压没。
const double kMinPlayerWidth = 240.0;

/// 覆盖层展开宽度的**下限**（px）：用户把面板宽度设成 0 或很小时，展开仍保证可用。
const double kOverlayPanelMinWidth = 300.0;

/// 单帧派生结果（见 [computePanelLayout]）。
class PanelLayout {
  const PanelLayout({
    required this.overlay,
    required this.renderW,
    required this.overlayW,
    required this.available,
    required this.reason,
  });

  /// 是否使用覆盖式面板（收起分栏）。
  final bool overlay;

  /// 分栏时面板**实际使用**的宽度；[overlay] 为 true 时无意义（为 0）。
  final double renderW;

  /// 覆盖层展开时的宽度。
  final double overlayW;

  /// 本次可留给面板的空间（日志/排障用）。
  final double available;

  /// 判定依据（日志用）：`normal` / `hysteresis` / `user-collapsed` / `no-room` / `no-video-size` / `no-size`；
  /// fill/cover 时会带前缀 `fill-cover|`。
  final String reason;

  @override
  String toString() => 'PanelLayout(overlay: $overlay, renderW: ${renderW.toStringAsFixed(1)}, '
      'overlayW: ${overlayW.toStringAsFixed(1)}, available: ${available.toStringAsFixed(1)}, reason: $reason)';
}

/// **单帧派生**直播间右侧面板布局：判定与渲染同源，结构上保证 `renderW ≤ 可放下的宽度`。
///
/// 约定（2026-10-21 rev.5）：
/// - [manualWidth] = **用户意图宽**（0~800；`0` 表示收起面板；`<180` 视为"要更窄"→ 覆盖式）；
/// - [autoMode] = 是否"自动撑满余量"（即设置项 autoFitWindowWidth）；用户拖过分隔条后为 false；
/// - **判定与渲染都只用本函数返回值**，不再读任何异步回写/持久化旧宽度；
/// - 所有输入都有有限性守卫：NaN / 非有限 / 非法值一律退化到保守分支，**不抛异常、不产生 NaN 几何值**；
/// - [overlayActive] 为调用方持有的滞回记忆（普通字段，勿用 Rx 在 build 期写）。
PanelLayout computePanelLayout({
  required double contentWidth,
  required double playerHeight,
  required double videoWidth,
  required double videoHeight,
  required double manualWidth,
  required bool autoMode,
  required bool overlayActive,
  int scaleMode = 0,
  double aspectByUser = 0,
  double handleWidth = kPanelResizeHandleWidth,
}) {
  bool finitePositive(double v) => v.isFinite && v > 0;

  // 用户意图宽：非有限/负数 → 默认值；再夹 [0, 800]
  final double userW = (!manualWidth.isFinite || manualWidth < 0)
      ? kMessagePanelDefaultWidth
      : manualWidth.clamp(0.0, kMessagePanelMaxWidth);
  final double hw = finitePositive(handleWidth) ? handleWidth : kPanelResizeHandleWidth;

  double overlayWidthOf(double cw) => math.min(
        math.max(userW, kOverlayPanelMinWidth),
        (cw.isFinite && cw > 0) ? cw * 0.85 : kMessagePanelDefaultWidth,
      );

  // ① 窗口尺寸未就绪：一律覆盖式（不渲染分栏，杜绝 NaN 几何值）
  if (!finitePositive(contentWidth)) {
    return PanelLayout(overlay: true, renderW: 0, overlayW: kOverlayPanelMinWidth, available: 0, reason: 'no-size');
  }
  // 面板可占的上限就是窗口内容宽：手柄是**叠在播放区上的悬浮条**，不再从布局里扣宽度
  // （否则 auto 模式下播放区会比视频比例宽 8px，contain 时左右各留一条黑边）。
  final double maxPanelByWindow = contentWidth;

  // ② 有效宽高比（按 scaleMode）
  //    fill/cover(1/2) → 无黑边；3/4 → 强制比例；5 → 自定义比例（非法回退视频比例）；
  //    0/其它 → 视频比例；拿不到有效比例 → 走"尺寸未就绪"保守分支。
  final bool noLetterbox = (scaleMode == 1 || scaleMode == 2);
  double? aspect;
  if (!noLetterbox) {
    if (scaleMode == 3) {
      aspect = 16 / 9;
    } else if (scaleMode == 4) {
      aspect = 4 / 3;
    } else if (scaleMode == 5 && finitePositive(aspectByUser)) {
      aspect = aspectByUser;
    } else if (finitePositive(videoWidth) && finitePositive(videoHeight)) {
      aspect = videoWidth / videoHeight; // scaleMode 0 / 5(非法回退) / 其它未知
    }
  }
  if (!noLetterbox && aspect == null) {
    // contain 类但拿不到有效比例：**尊重用户的收起意图**，其余情况保守按手动宽分栏，且不超窗口
    final double rw = math.min(userW.clamp(kMessagePanelMinWidth, kMessagePanelMaxWidth), maxPanelByWindow);
    final bool collapsed = userW < kMessagePanelMinWidth || rw < kMessagePanelMinWidth;
    return PanelLayout(
      overlay: collapsed,
      renderW: collapsed ? 0 : rw,
      overlayW: overlayWidthOf(contentWidth),
      available: maxPanelByWindow,
      reason: 'no-video-size',
    );
  }

  // ③ 可留给面板的空间
  final double availRaw = noLetterbox
      // fill/cover：为播放区保留 kMinPlayerWidth
      ? math.max(0.0, maxPanelByWindow - kMinPlayerWidth)
      : (finitePositive(playerHeight) ? contentWidth - playerHeight * aspect! : maxPanelByWindow);
  final double avail = availRaw.isFinite ? math.max(0.0, availRaw) : 0.0;
  final String baseReason = noLetterbox ? 'fill-cover' : 'ready';

  // ④ 判定（2026-10-21 Howe 定：**面板宽 ≥ 180 且窗口放得下 180 → 一律分栏**，
  //    不再因「意图宽放不下」整个切覆盖式；覆盖式只剩两种：用户收起（<180）/窗口物理放不下（avail<180））
  bool overlay;
  String reason;
  if (userW < kMessagePanelMinWidth) {
    overlay = true;
    reason = 'user-collapsed';
  } else if (avail < kMessagePanelMinWidth) {
    overlay = true;
    reason = 'no-room';
  } else if (overlayActive) {
    overlay = avail < kMessagePanelMinWidth + kPanelOverlayHysteresis;
    reason = 'hysteresis';
  } else {
    overlay = false;
    reason = 'fits';
  }
  // 保真：把"基准"信息保留在 reason 里（否则 ready / fill-cover 永远看不到）
  if (baseReason != 'ready') {
    reason = '$baseReason|$reason';
  }

  // ⑤ 渲染宽（与判定同源；恒 ≤ 窗口内容宽）
  //    auto 模式：恒 = avail（视频保比例、面板吃余量）；
  //    手动模式：按意图宽渲染（视频让位/留黑边）——只受 [180,800] 与窗口宽度约束、**不钳到 avail**，
  //    否则拖宽面板会被钳住、看起来「拖了不变」（2026-10-21 Howe 反馈）。
  final double rawRender = autoMode ? avail : userW;
  double renderW = rawRender.clamp(kMessagePanelMinWidth, kMessagePanelMaxWidth);
  renderW = math.min(renderW, maxPanelByWindow);
  if (renderW < kMessagePanelMinWidth) {
    overlay = true;
    reason = 'no-room';
  }

  return PanelLayout(
    overlay: overlay,
    renderW: overlay ? 0 : renderW,
    overlayW: overlayWidthOf(contentWidth),
    available: avail,
    reason: reason,
  );
}
