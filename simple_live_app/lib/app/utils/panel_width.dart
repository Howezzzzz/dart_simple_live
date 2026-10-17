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
