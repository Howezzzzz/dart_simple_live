import 'dart:async';
import 'dart:io';
import 'package:auto_orientation_v2/auto_orientation_v2.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'package:floating/floating.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:flutter_image_gallery_saver/flutter_image_gallery_saver.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:path_provider/path_provider.dart';
import 'package:simple_live_app/app/event_bus.dart';
import 'package:simple_live_app/services/window_service.dart';
import 'package:volume_controller/volume_controller.dart';
import 'package:screen_brightness_platform_interface/screen_brightness_platform_interface.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/controller/base_controller.dart';
import 'package:simple_live_app/app/custom_throttle.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/app/utils/panel_width.dart';
import 'package:simple_live_app/app/utils/rtx_vsr_crop.dart';
import 'package:simple_live_app/app/utils/volume_norm.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_app/modules/live_room/danmaku/danmaku_emoticon.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:window_manager/window_manager.dart';

// 音量均衡滤镜链与纯逻辑见 app/utils/volume_norm.dart
// （两段：dynaudnorm 轻压 + loudnorm 定标准；选用依据见该文件头注释与
//   文件/Slive/文档/音量均衡-方案调研-20261110.md）。

/// 音量均衡探测期错误抑制时长：mpv 的 af 写入失败会以 stream.error 事件异步到达，
/// 需在 set 之后留出窗口，避免误触发 mediaError 重拉流（PR #195 教训）
const Duration volumeNormSuppressDuration = Duration(seconds: 2);

mixin PlayerMixin {
  GlobalKey<VideoState> globalPlayerKey = GlobalKey<VideoState>();
  GlobalKey globalDanmuKey = GlobalKey();

  /// 当前视频分辨率（供布局判定「覆盖式面板」实时刷新，2026-10-21 RISK-17）。
  /// 由 player 的 width/height 流直接更新（与自适应/全屏等设置**解耦**）——
  /// 页面 Obx 读取它触发重建；fitPanelWidthToVideo 亦会更新（冗余但无害）。
  var videoWidthRx = 0.obs;
  var videoHeightRx = 0.obs;

  /// 播放器实例
  late final player = Player(
    configuration: PlayerConfiguration(
      title: "Slive Player",
      logLevel: AppSettingsController.instance.logEnable.value ? MPVLogLevel.debug : MPVLogLevel.error,
    ),
  );

  /// 初始化播放器并设置 ao 参数
  Future<void> initializePlayer() async {
    var pp = player.platform as NativePlayer;
    // 设置音频输出驱动
    if (AppSettingsController.instance.customPlayerOutput.value) {
      await pp.setProperty(
        'ao',
        AppSettingsController.instance.audioOutputDriver.value,
      );
    } else if (Platform.isLinux) {
      await pp.setProperty('ao', 'alsa');
    }
    // 直播流（如斗鱼 FLV）不可 seek；不强制 seekable 时，一旦发生 seek 会报
    //   "Cannot seek in this stream. You can force it with '-force-seekable=yes'"
    // （原仅 Android 设置；Windows/桌面同样会踩，故改为全平台）
    await pp.setProperty('force-seekable', 'yes');
    // 低内存管理
    //
    // 根据：https://mpv.io/manual/stable/#cache
    // --cache=<yes|no|auto>// --cache-secs=<seconds>
    // --demuxer-seekable-cache=<yes|no|auto>
    // --demuxer-max-back-bytes=<bytesize>
    // --demuxer-donate-buffer==<yes|no>
    //
    // 内存换空间, 同时通过调整参数禁用mpv回放缓存（直播暂时不需要）
    // hls流/令牌流/.. 根据mdk-sdk作者回复, rtsp 在 ffmpeg存在内存泄露, 这意味着我们只能等待修复
    // temporary fix of android platform
    if (!Platform.isAndroid) {
      await pp.setProperty("cache", "no");
      await pp.setProperty("cache-secs", "0");
      await pp.setProperty('demuxer-seekable-cache', 'no');
      await pp.setProperty('demuxer-donate-buffer', 'no');
      await pp.setProperty("demuxer-max-back-bytes", "0");
    }
    // 在所有平台上正确启用双重缓存,覆写mpv设置
    if (AppSettingsController.instance.videoDoubleBuffering.value) {
      final directory = await getTemporaryDirectory();
      await pp.setProperty("cache", "yes");
      await pp.setProperty("cache-secs", "3");
      await pp.setProperty('demuxer-seekable-cache', 'yes');
      await pp.setProperty('demuxer-donate-buffer', 'yes');
      await pp.setProperty("demuxer-cache-dir", directory.path);
    }
    // bili/douyin流存在时间戳跳变问题
    // 真机建议-空间换内存-暂时不需要
    //  windows:
    //  icc-cache-dir = "~~/cache/icc";
    //  gpu-shader-cache-dir = "~~/cache/shader"
    //  watch-later-dir = "~~/cache/watch_later"
    // NVIDIA RTX VSR 支持 (Windows 平台)
    if (Platform.isWindows && AppSettingsController.instance.enableRtxVsr.value) {
      await pp.setProperty('hwdec', 'd3d11va');
      // 放大倍数与 rtx_vsr_crop.dart 的 rtxVsrScale 单一事实来源（复核 P3-4）：
      // 手动写两处 scale 会脱钩——倍数调大时裁切矩形落在放大帧内 → 裁错且无 safe-fail。
      await pp.setProperty('vf', rtxVsrVfChain(rtxVsrScale));
      _lastRtxVsrScale = rtxVsrScale;
      _rtxVsrChainApplied = true;
    } else if (Platform.isWindows) {
      // 关闭 VSR 时必须摘掉已挂上的滤镜链（复核 P2-1）：只改标志不摘链的话，
      // 同一会话 F5/切清晰度重初始化后，链仍在放大画面、裁切却被清空 → 绿条复现且 VSR 代价照付。
      await pp.setProperty('vf', '');
      _lastRtxVsrScale = null;
      _rtxVsrChainApplied = false;
    }
    // 音量均衡：**起流前**预挂滤镜链（此处早于 live_room_controller 的 player.open）。
    // 旧的「首帧播放后才挂」会让进房头 1–3s 完全没有处理（两轮复核整合结论）。
    // 幂等：已挂则不重复 set —— set 会重建整条链并重置 loudnorm 的收敛状态。
    if (!_volumeNormApplied &&
        volumeNormShouldPreApply(
          userOn: AppSettingsController.instance.volumeNorm.value,
          supported: afLoudnormSupported,
        )) {
      await _preApplyVolumeNorm();
    }
    // 同步底部补边裁切（VSR 开启才裁；关闭时显式清空，避免切线路等场景残留上次的裁切）
    await _syncRtxVsrCrop();
  }

  /// 本次播放是否已挂上 VSR 滤镜链（决定能否动 video-crop）。
  bool _rtxVsrChainApplied = false;

  /// 记录最近一次**已应用**的 VSR 同步签名（裁切值 + 源尺寸 + 链状态），用于去重。
  /// 不能只用裁切值当键：无补边流的裁切值都是空串，切分辨率/切直播间时会误判「未变化」
  /// → 渲染尺寸与显示比例漏更（复核 P0）。
  String? _lastRtxVsrSignature;

  /// 当前已挂上的 VSR 倍数（null = 未挂链），用于判断是否需要重挂滤镜链。
  double? _lastRtxVsrScale;

  /// 播放区尺寸变化的防抖计时器（合并密集 resize 事件，避免滤镜链反复重挂）。
  Timer? _vsrSyncDebounce;

  /// 错误抑制（音量均衡探测/切换 + VSR 重挂滤镜链共用；PR #195 教训）：抑制窗口内
  /// mpv 的 stream.error 直接跳过，避免被误当媒体错误去重拉流/切线路。
  /// 注：声明在 mixin 内——VSR 的同步逻辑在 mixin，需库内可见。
  bool _suppressErrorRetry = false;
  int _suppressToken = 0;

  /// 播放器已释放标记（异步回调短路，防止已释放播放器断言）。
  bool _playerDisposed = false;

  /// 延迟解除错误抑制（mpv 错误事件可能略晚于 setProperty 返回）。
  void _scheduleSuppressRelease(int token) {
    Future.delayed(volumeNormSuppressDuration, () {
      if (_playerDisposed) {
        return;
      }
      if (token == _suppressToken) {
        _suppressErrorRetry = false;
      }
    });
  }

  /// 串行队列：width/height 双监听并发调用时按序执行，避免交错产生竞态假告警（复核 P3-2）。
  Future<void> _cropWriteQueue = Future<void>.value();

  /// Windows 下按 VSR 状态同步 mpv 的底部补边裁切。
  ///
  /// VSR 把画面放大 2 倍，而编码按 16 对齐补边（如 540p 流实际帧高 544），
  /// D3D11 视频处理器只写“真实内容高度”，末尾未写入的行显示为绿色 → 画面底部绿条。
  /// 用 mpv `--video-crop` 裁掉补边；**坐标空间是滤镜之后的帧**（见 rtx_vsr_crop.dart 注释）。
  ///
  /// 两种状态都写：开了 → 裁切值；没开（或未挂上滤镜链）→ 空串（取消手动裁切）。
  Future<void> _syncRtxVsrCrop() async {
    // 注：不引用 _playerDisposed（它在 PlayerController 内，mixin 不可见）；
    // 播放器已 dispose 时 media_kit 的 setProperty/getProperty 会抛 AssertionError
    // 或 StateError（_checkNativeHandle），由 _enqueueCropWrite 的 catch 兜底。
    if (!Platform.isWindows) return;
    final pp = player.platform;
    if (pp is! NativePlayer) return;
    final rawW = player.state.width ?? 0;
    final rawH = player.state.height ?? 0;
    // 尺寸未知（如 initializePlayer 在 open 之前那次调用）先不处理：否则会把空值写进去重
    // 缓存，令随后无补边流（裁切值为空串）的真实尺寸事件被误判为「未变化」而漏更（复核 P0）。
    if (rawW <= 0 || rawH <= 0) return;
    // 纯逻辑决策（自适应倍数 / 裁切 / 显示比例 / 画布），便于单测（见 rtx_vsr_crop.dart）。
    // 自适应倍数：目标 ≈ 播放区物理分辨率（源低就多放大）；拿不到播放区尺寸走固定 2x 兜底；
    // S≤1.05（源≥播放区）→ 不挂 VSR。
    final area = _rtxVsrChainApplied ? _playerAreaPhysicalSize() : null;
    final plan = rtxVsrPlan(
      enabled: _rtxVsrChainApplied,
      areaW: area?.$1,
      areaH: area?.$2,
      srcW: rawW,
      srcH: rawH,
    );
    final s = plan.scale; // 捕获为 final，便于闭包里做空值提升
    final enable = plan.applied;
    final desired = plan.crop;
    final aspectValue = plan.aspect;
    final renderSize = plan.renderSize;
    // 去重签名：倍数 + 裁切值 + 源尺寸 + 链状态（**不能只用裁切值当键**，见字段注释）。
    final signature = '${s ?? -1}|$desired|${rawW}x$rawH|$_rtxVsrChainApplied';
    if (signature == _lastRtxVsrSignature) return;
    _enqueueCropWrite(() async {
      // 队列内再查一次：并发同值时只写第一笔，避免重复设置触发滤镜链重建。
      if (signature == _lastRtxVsrSignature) return;
      final (vfAction, vfValue) = rtxVsrVfAction(
          enable: enable, scale: s, currentScale: _lastRtxVsrScale);
      if (vfAction != 'none') {
        // 写/摘 vf 会重建 D3D11 链路，期间可能冒 stream.error → 误触重拉流（PR #195）：
        // 所有会动 vf 的路径（开关、切分辨率、resize 防抖）统一在此加抑制窗。
        final token = ++_suppressToken;
        _suppressErrorRetry = true;
        try {
          if (vfAction == 'set') {
            // d3d11vpp 需 D3D11 硬件帧上下文
            await pp.setProperty('hwdec', 'd3d11va');
            await pp.setProperty('vf', vfValue);
            _lastRtxVsrScale = s;
          } else {
            await pp.setProperty('vf', '');
            _lastRtxVsrScale = null;
          }
        } finally {
          _scheduleSuppressRelease(token);
        }
      }
      await pp.setProperty('video-crop', desired);
      await pp.setProperty(
          'video-aspect-override', aspectValue.toStringAsFixed(6));
      if (renderSize != null) {
        await videoController
            .setSize(width: renderSize.$1, height: renderSize.$2);
      } else {
        await videoController.setSize();
      }
      // 写入成功后才记缓存（复核 P3-3）：异常（dispose 竞态）时保持旧值，下次同步会重试。
      _lastRtxVsrSignature = signature;
      if (desired.isEmpty) return;
      // 回读校验（参考音量均衡 af 的做法）：media_kit 的 setProperty 不返回错误，
      // 属性缺失/语法级拒绝时会静默失败 → 回读一次让失败可见（RISK-58）。
      // 注意：回读只能证明“属性被接受”，不能证明 VO 逐帧应用成功（越界值由 mpv
      // 在应用阶段忽略并打印日志）——成功日志措辞按此收敛为“已写入”。
      final readback = (await pp.getProperty('video-crop')).trim();
      if (readback.replaceAll(' ', '') == desired) {
        Log.d('[VSR] 已写入底部补边裁切 video-crop=$desired'
            ' scale=${s?.toStringAsFixed(2)}'
            ' aspect=${aspectValue.toStringAsFixed(6)}'
            ' renderSize=${renderSize?.$1}x${renderSize?.$2}'
            '（源 ${player.state.width}x${player.state.height}）');
      } else {
        Log.w('[VSR] video-crop 未生效：期望 $desired，回读 "$readback"'
            '（源 ${player.state.width}x${player.state.height}）—— 可能 libmpv 不支持该属性');
      }
    });
  }

  /// 串行执行一次 video-crop 写入（参考 _enqueueVolumeNorm 的既有惯例）。
  Future<void> _enqueueCropWrite(Future<void> Function() task) {
    final next = _cropWriteQueue.then((_) async {
      try {
        await task();
      } catch (e) {
        Log.d('[VSR] 设置 video-crop 失败: $e');
      }
    });
    _cropWriteQueue = next;
    return next;
  }

  /// 防抖入口：播放区尺寸变化（窗口缩放/面板拖动/进退全屏）等场景调用。
  void scheduleRtxVsrSync() {
    _vsrSyncDebounce?.cancel();
    _vsrSyncDebounce = Timer(const Duration(milliseconds: 250), () {
      _syncRtxVsrCrop();
    });
  }

  /// 播放区（Video widget）的物理像素尺寸；不可得时返回 null（调用方走固定 2x 兜底）。
  (int, int)? _playerAreaPhysicalSize() {
    try {
      final ctx = globalPlayerKey.currentContext;
      if (ctx == null) return null;
      final size = ctx.size;
      if (size == null) return null;
      if (size.width < 2 || size.height < 2) return null;
      final dpr = MediaQuery.maybeOf(ctx)?.devicePixelRatio ?? 1.0;
      final w = (size.width * dpr).round();
      final h = (size.height * dpr).round();
      if (w < 2 || h < 2) return null;
      return (w, h);
    } catch (e) {
      Log.d('[VSR] 取播放区尺寸失败: $e');
      return null;
    }
  }

  /// 视频控制器
  late final videoController = VideoController(
    player,
    configuration: AppSettingsController.instance.customPlayerOutput.value
        ? VideoControllerConfiguration(
            vo: AppSettingsController.instance.videoOutputDriver.value,
            hwdec: AppSettingsController.instance.videoHardwareDecoder.value,
          )
        : AppSettingsController.instance.playerCompatMode.value
            ? const VideoControllerConfiguration(
                vo: 'mediacodec_embed',
                hwdec: 'mediacodec',
              )
            : VideoControllerConfiguration(
                enableHardwareAcceleration: AppSettingsController.instance.hardwareDecode.value,
                androidAttachSurfaceAfterVideoParameters: false,
              ),
  );
}
mixin PlayerStateMixin on PlayerMixin {
  ///音量控制条计时器
  Timer? hidevolumeTimer;

  /// 是否进入桌面端小窗
  RxBool smallWindowState = false.obs;

  /// 是否显示弹幕
  RxBool showDanmakuState = false.obs;

  /// 是否显示视频
  RxBool showVideoState = true.obs;

  /// 是否显示控制器
  RxBool showControlsState = false.obs;

  /// 是否显示设置窗口
  RxBool showSettingState = false.obs;

  /// 是否显示弹幕设置窗口
  RxBool showDanmakuSettingState = false.obs;

  /// 是否处于锁定控制器状态
  RxBool lockControlsState = false.obs;

  /// 是否处于全屏状态
  RxBool fullScreenState = false.obs;

  /// 是否处于窗口全屏状态（画面占满整个软件窗口，窗口自身状态不变）
  RxBool windowFillState = false.obs;

  /// 是否处于窗口最大化状态
  RxBool windowMaxState = false.obs;

  /// 显示手势Tip
  RxBool showGestureTip = false.obs;

  /// 手势Tip文本
  RxString gestureTipText = "".obs;

  /// 显示提示底部Tip
  RxBool showBottomTip = false.obs;

  /// 是否显示OSD统计信息
  RxBool showOSDStats = false.obs;

  /// 提示底部Tip文本
  RxString bottomTipText = "".obs;

  /// 自动隐藏控制器计时器
  Timer? hideControlsTimer;

  /// 自动隐藏提示计时器
  Timer? hideSeekTipTimer;

  /// 是否为竖屏直播间
  var isVertical = false.obs;

  Widget? danmakuView;

  var showQualites = false.obs;
  var showLines = false.obs;

  void setVideoState() async {
    showVideoState.value = !showVideoState.value;
    if (showVideoState.value) {
      await player.setVideoTrack(VideoTrack.auto());
    } else {
      await player.setVideoTrack(VideoTrack.no());
    }
  }

  /// 隐藏控制器
  void hideControls() {
    showControlsState.value = false;
    hideControlsTimer?.cancel();
  }

  void setLockState() {
    lockControlsState.value = !lockControlsState.value;
    if (lockControlsState.value) {
      showControlsState.value = false;
    } else {
      showControlsState.value = true;
    }
  }

  /// 显示控制器
  void showControls() {
    showControlsState.value = true;
    resetHideControlsTimer();
  }

  /// 开始隐藏控制器计时
  /// - 当点击控制器上时功能时需要重新计时
  void resetHideControlsTimer() {
    hideControlsTimer?.cancel();

    hideControlsTimer = Timer(
      const Duration(
        seconds: 5,
      ),
      hideControls,
    );
  }

  void updateScaleMode() {
    var boxFit = BoxFit.contain;
    double? aspectRatio;
    if (player.state.width != null && player.state.height != null) {
      aspectRatio = player.state.width! / player.state.height!;
    }

    if (AppSettingsController.instance.scaleMode.value == 0) {
      boxFit = BoxFit.contain;
    } else if (AppSettingsController.instance.scaleMode.value == 1) {
      boxFit = BoxFit.fill;
    } else if (AppSettingsController.instance.scaleMode.value == 2) {
      boxFit = BoxFit.cover;
    } else if (AppSettingsController.instance.scaleMode.value == 3) {
      boxFit = BoxFit.contain;
      aspectRatio = 16 / 9;
    } else if (AppSettingsController.instance.scaleMode.value == 4) {
      boxFit = BoxFit.contain;
      aspectRatio = 4 / 3;
    } else if (AppSettingsController.instance.scaleMode.value == 5) {
      boxFit = BoxFit.contain;
      double aspectByUser = AppSettingsController.instance.aspectByUser.value;
      aspectRatio = aspectByUser;
    }
    // todo: 代码复用
    globalPlayerKey.currentState?.update(
      aspectRatio: aspectRatio,
      fit: boxFit,
    );
  }
}
mixin PlayerDanmakuMixin on PlayerStateMixin {
  /// 弹幕控制器
  late DanmakuController? danmakuController;

  void initDanmakuController(DanmakuController e) {
    danmakuController = e;
  }

  void updateDanmuOption(DanmakuOption? option) {
    if (option == null) return;
    danmakuController?.updateOption(option);
  }

  void disposeDanmakuController() {
    danmakuController?.clear();
  }

  void addDanmaku(List<DanmakuContentItem> items) {
    if (!showDanmakuState.value) {
      return;
    }
    for (var item in items) {
      danmakuController?.addDanmaku(item);
      _applyDanmakuEmoticon(item);
    }
  }

  /// 表情包弹幕的渲染接管。
  ///
  /// 弹幕库只认纯文本，这里用它公开的 [DanmakuController] 接口做后置替换：
  /// 先让库按占位符文本入轨，等图片取回后再把该条的位图换成「文本 + 表情」的
  /// 行内混排版本，并把该 [DanmakuItem] 的宽高改写成位图尺寸。
  ///
  /// 已知限制：库的滚动轨道是等高网格、排轨只看入轨时的文本宽高，改写尺寸后
  /// 不会重排。行内小表情与占位符文本尺寸接近、看不出来；大表情
  /// （[LiveMessageEmoticon.large]）比占位符文本宽高都大，会与同轨 / 相邻轨的
  /// 弹幕重叠——这是接受了的取舍，真要让位得改 canvas_danmaku 的排轨。
  ///
  /// 取图失败 / 弹幕已过期时直接放弃替换 —— 库渲染的占位符文本就是兜底表现，
  /// 不会出现空白弹幕。
  void _applyDanmakuEmoticon(DanmakuContentItem item) {
    if (!AppSettingsController.instance.danmuEmoticonEnable.value) {
      return;
    }
    final extra = item.extra;
    if (!DanmakuEmoticonRenderer.canRender(extra)) {
      return;
    }
    final controller = danmakuController;
    if (controller == null) {
      return;
    }
    unawaited(DanmakuEmoticonRenderer.apply(
      controller: controller,
      content: item,
      emoticons: extra as List<LiveMessageEmoticon>,
    ));
  }
}
mixin PlayerSystemMixin on PlayerMixin, PlayerStateMixin, PlayerDanmakuMixin {
  final DeviceInfoPlugin deviceInfo = DeviceInfoPlugin();
  final VolumeController volumeController = VolumeController.instance;
  final pip = Floating();
  StreamSubscription<PiPStatus>? _pipSubscription;

  /// 初始化一些系统状态
  void initSystem() async {
    if (Platform.isAndroid || Platform.isIOS) {
      volumeController.showSystemUI = false;
    }

    // 屏幕常亮
    //WakelockPlus.enable();

    // 开始隐藏计时
    resetHideControlsTimer();
  }

  /// 释放一些系统状态
  Future resetSystem() async {
    _pipSubscription?.cancel();
    //pip.dispose();
    await SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.edgeToEdge,
      overlays: SystemUiOverlay.values,
    );

    await setPortraitOrientation();
    if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS) {
      // 亮度重置,桌面平台可能会报错,暂时不处理桌面平台的亮度
      try {
        await ScreenBrightnessPlatform.instance.resetApplicationScreenBrightness();
      } catch (e) {
        Log.logPrint(e);
      }
    }

    await WakelockPlus.disable();
  }

  /// 进入全屏
  void enterFullScreen() async {
    fullScreenState.value = true;
    if (Platform.isAndroid || Platform.isIOS) {
      //全屏
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: []);
      if (!isVertical.value) {
        //横屏
        setLandscapeOrientation();
      }
    } else {
      // todo: animation isn't smooth...
      // fix: pip->full->normal bug
      // 不再考虑从什么状态切换，逻辑混乱，而是确定窗口状态直接设置属性
      // 记忆进入全屏前的状态
      windowMaxState.value = await windowManager.isMaximized();
      // 读取窗口大小
      smallWindowState.value = false; // no pip
      WindowService.instance.isPIP = smallWindowState.value;
      await windowManager.setFullScreen(true); // in full
      await windowManager.setTitleBarStyle(TitleBarStyle.hidden); // no title
      await WindowService.instance.danmakuFontClamped();
      await windowManager.setAlwaysOnTop(false);
    }
    //danmakuController?.clear();
  }

  /// 退出全屏
  void exitFull() async {
    SmartDialog.dismiss(status: SmartStatus.allCustom);
    if (Platform.isAndroid || Platform.isIOS) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge, overlays: SystemUiOverlay.values);
      setPortraitOrientation();
    } else {
      // 退回原来的大小
      if (windowMaxState.value) await windowManager.maximize();
      if (_lastWindowSize != null) {
        await windowManager.setSize(_lastWindowSize!);
      }
      if (_lastWindowPosition != null) {
        await windowManager.setPosition(_lastWindowPosition!);
      }
      Log.d('last_window_size:${_lastWindowSize?.width}__${_lastWindowSize?.height}');
      Log.d('last_window_position:${_lastWindowPosition?.dx}__${_lastWindowPosition?.dy}');
      windowManager.setFullScreen(false);
      windowManager.setTitleBarStyle(TitleBarStyle.normal);
      await WindowService.instance.danmakuFontClamped();
    }
    fullScreenState.value = false;
    //danmakuController?.clear();
  }

  /// 进入窗口全屏：画面占满整个软件窗口（不改变系统级窗口状态，不动标题栏）
  void enterWindowFill() {
    windowFillState.value = true;
  }

  /// 退出窗口全屏
  void exitWindowFill() {
    windowFillState.value = false;
  }

  Size? _lastWindowSize;
  Offset? _lastWindowPosition;

  /// 进入直播间后：**不改变窗口大小**，按当前直播流分辨率调整「右侧弹幕栏宽度」，
  /// 使播放区贴合原始比例（无黑边）。因为不动窗口，**最大化/各种窗口状态下同样生效**。
  Future<void> fitPanelWidthToVideo({int attempt = 0}) async {
    if (Platform.isAndroid || Platform.isIOS) return;
    // 这些状态下面板不可见，无从调整
    if (fullScreenState.value || windowFillState.value || smallWindowState.value) {
      return;
    }
    final w = player.state.width ?? 0;
    final h = player.state.height ?? 0;
    if (w <= 0 || h <= 0) return;
    // 供页面判定覆盖式面板（分辨率变化时也能刷新；RISK-17）
    videoWidthRx.value = w;
    videoHeightRx.value = h;
    Size? playerSize;
    double? contentWidth;
    try {
      final ctx = globalPlayerKey.currentContext;
      playerSize = ctx?.size;
      contentWidth = ctx == null ? null : MediaQuery.maybeOf(ctx)?.size.width;
    } catch (e) {
      Log.d('fitPanelWidthToVideo 取尺寸异常: $e');
    }
    if (playerSize == null || playerSize.height < 50 || playerSize.width < 50 || contentWidth == null) {
      Log.d('fitPanelWidthToVideo[try$attempt] 未就绪: video=${w}x$h playerSize=$playerSize contentWidth=$contentWidth');
      // 分辨率事件常常早于首帧布局 → 稍后重试几次
      if (attempt < 12) {
        Future.delayed(const Duration(milliseconds: 400), () => fitPanelWidthToVideo(attempt: attempt + 1));
      }
      return;
    }
    // 播放区高度不变，按比例算它应有的宽度；余下留给右侧弹幕栏。
    // 低于下限时仍设为下限（继续自适应、把播放区放到能放到的最大），
    // 而不是保持旧值不动 —— 详见 app/utils/panel_width.dart。
    final target = panelWidthForVideo(
      contentWidth: contentWidth,
      videoWidth: w.toDouble(),
      videoHeight: h.toDouble(),
      playerHeight: playerSize.height,
    );
    final current = AppSettingsController.instance.messagePanelWidth.value;
    Log.d(
        'fitPanelWidthToVideo[try$attempt] video=${w}x$h player=${playerSize.width}x${playerSize.height} contentW=$contentWidth -> panel $current -> $target');
    // 2026-10-21 rev.5：**不再回写面板宽度**（面板宽度改为"单帧派生"，见 panel_width.dart 的
    // computePanelLayout）。这里只保留计算与日志，用于排障；否则"自适应"会与"用户意图宽"
    // 互相覆盖、导致判定阈值失真。
    Log.d('fitPanelWidthToVideo（已停用回写）-> 派生建议值 $target（当前 $current）');
  }

  ///小窗模式()
  void enterSmallWindow() async {
    if (!(Platform.isAndroid || Platform.isIOS)) {
      fullScreenState.value = true;
      smallWindowState.value = true;
      WindowService.instance.isPIP = smallWindowState.value;
      // 进入小窗会自动恢复默认弹幕大小
      // 读取窗口大小
      _lastWindowSize = await windowManager.getSize();
      _lastWindowPosition = await windowManager.getPosition();
      Log.d('last_window_size:${_lastWindowSize?.width}__${_lastWindowSize?.height}');
      Log.d('last_window_position:${_lastWindowPosition?.dx}__${_lastWindowPosition?.dy}');
      windowManager.setTitleBarStyle(TitleBarStyle.hidden);
      // 获取视频窗口大小
      var width = player.state.width ?? 16;
      var height = player.state.height ?? 9;
      var px = AppSettingsController.instance.windowPipX.value;
      var py = AppSettingsController.instance.windowPipY.value;
      var pWidth = AppSettingsController.instance.windowPipWidth.value;
      var pHeight = AppSettingsController.instance.windowPipHeight.value;
      // 横屏还是竖屏
      if (height < width) {
        windowManager.setSize(Size(pWidth, pHeight));
        windowManager.setPosition(Offset(px, py));
      } else {
        windowManager.setSize(Size(pHeight, pWidth));
        windowManager.setPosition(Offset(px, py));
      }

      windowManager.setAlwaysOnTop(true);
    }
  }

  ///退出小窗模式()
  void exitSmallWindow() {
    if (!(Platform.isAndroid || Platform.isIOS)) {
      fullScreenState.value = false;
      smallWindowState.value = false;
      WindowService.instance.isPIP = smallWindowState.value;
      windowManager.setTitleBarStyle(TitleBarStyle.normal);
      windowManager.setSize(_lastWindowSize!);
      windowManager.setPosition(_lastWindowPosition!);
      windowManager.setAlwaysOnTop(false);
      //windowManager.setAlignment(Alignment.center);
    }
  }

  /// 设置横屏
  Future setLandscapeOrientation() async {
    if (await beforeIOS16()) {
      AutoOrientation.landscapeAutoMode();
    } else {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    }
  }

  /// 设置竖屏
  Future setPortraitOrientation() async {
    if (await beforeIOS16()) {
      AutoOrientation.portraitAutoMode();
    } else {
      await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    }
  }

  /// 是否是IOS16以下
  Future<bool> beforeIOS16() async {
    if (Platform.isIOS) {
      var info = await deviceInfo.iosInfo;
      var version = info.systemVersion;
      var versionInt = int.tryParse(version.split('.').first) ?? 0;
      return versionInt < 16;
    } else {
      return false;
    }
  }

  Future saveScreenshot() async {
    final imageSaver = ImageGallerySaver();
    try {
      SmartDialog.showLoading(msg: "正在保存截图");
      //检查相册权限,仅iOS需要
      var permission = await Utils.checkPhotoPermission();
      if (!permission) {
        SmartDialog.showToast("没有相册权限");
        SmartDialog.dismiss(status: SmartStatus.loading);
        return;
      }

      var imageData = await player.screenshot();
      if (imageData == null) {
        SmartDialog.showToast("截图失败,数据为空");
        SmartDialog.dismiss(status: SmartStatus.loading);
        return;
      }

      if (Platform.isIOS || Platform.isAndroid) {
        await imageSaver.saveImage(
          imageData,
        );
        SmartDialog.showToast("已保存截图至相册");
      } else {
        // 选择保存位置（file_picker 13：提供字节+文件名，由插件写入；返回选中位置 Uri）
        var uri = await FilePicker.saveFile(
          fileName: "${DateTime.now().millisecondsSinceEpoch}.jpg",
          bytes: imageData,
          mimeType: "image/jpeg",
        );
        if (uri == null) {
          SmartDialog.showToast("取消保存");
          SmartDialog.dismiss(status: SmartStatus.loading);
          return;
        }
        SmartDialog.showToast("已保存截图至${uri.toFilePath()}");
      }
    } catch (e) {
      Log.logPrint(e);
      SmartDialog.showToast("截图失败");
    } finally {
      SmartDialog.dismiss(status: SmartStatus.loading);
    }
  }

  /// 开启小窗播放前弹幕状态
  bool danmakuStateBeforePIP = false;

  Future enablePIP() async {
    if (!Platform.isAndroid) {
      return;
    }
    if (await pip.isPipAvailable == false) {
      SmartDialog.showToast("设备不支持小窗播放");
      return;
    }
    danmakuStateBeforePIP = showDanmakuState.value;
    //关闭并清除弹幕
    if (AppSettingsController.instance.pipHideDanmu.value && danmakuStateBeforePIP) {
      showDanmakuState.value = false;
    }
    danmakuController?.clear();
    //关闭控制器
    showControlsState.value = false;

    //监听事件
    var width = player.state.width ?? 0;
    var height = player.state.height ?? 0;
    Rational ratio = const Rational.landscape();
    if (height > width) {
      ratio = const Rational.vertical();
    } else {
      ratio = const Rational.landscape();
    }
    await pip.enable(
      ImmediatePiP(
        aspectRatio: ratio,
      ),
    );

    _pipSubscription ??= pip.pipStatusStream.listen((event) {
      if (event == PiPStatus.disabled) {
        // 返回前台时恢复弹幕
        danmakuController?.resume();
        showDanmakuState.value = danmakuStateBeforePIP;
      }
      Log.w(event.toString());
    });
  }
}
mixin PlayerGestureControlMixin on PlayerStateMixin, PlayerMixin, PlayerSystemMixin {
  /// 单击显示/隐藏控制器
  void onTap() {
    if (showControlsState.value) {
      hideControls();
    } else {
      showControls();
    }
  }

  //桌面端操控
  void onEnter(PointerEnterEvent event) {
    if (!showControlsState.value) {
      showControls();
    }
  }

  void onExit(PointerExitEvent event) {
    if (showControlsState.value) {
      hideControls();
    }
  }

  void onHover(PointerHoverEvent event, BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;
    final targetPosition = screenHeight * 0.25; // 计算屏幕顶部25%的位置
    if (event.position.dy <= targetPosition || event.position.dy >= targetPosition * 3) {
      if (!showControlsState.value) {
        showControls();
      }
    }
  }

  /// 双击全屏/退出全屏
  void onDoubleTap(TapDownDetails details) {
    if (lockControlsState.value) {
      return;
    }
    if (fullScreenState.value) {
      exitFull();
    } else {
      enterFullScreen();
    }
  }

  bool verticalDragging = false;
  bool leftVerticalDrag = false;
  var _currentVolume = 0.0;
  var _currentBrightness = 1.0;
  var verStartPosition = 0.0;

  DelayedThrottle? throttle;

  /// 竖向手势开始
  void onVerticalDragStart(DragStartDetails details) async {
    if (lockControlsState.value && fullScreenState.value) {
      return;
    }
    if (AppSettingsController.instance.verticalDragLock.value) {
      return;
    }
    final dy = details.globalPosition.dy;
    // 开始位置必须是中间2/4的位置
    if (dy < Get.height * 0.25 || dy > Get.height * 0.75) {
      return;
    }

    verStartPosition = dy;
    leftVerticalDrag = details.globalPosition.dx < Get.width / 2;

    throttle = DelayedThrottle(200);

    verticalDragging = true;
    if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS || Platform.isWindows) {
      showGestureTip.value = true;
    }
    if (Platform.isAndroid || Platform.isIOS) {
      _currentVolume = await volumeController.getVolume();
    } else if (Platform.isWindows) {
      // Windows 走播放器音量（volume_controller 不支持 Windows 系统音量）
      _currentVolume = player.state.volume / 100;
    }
    if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS) {
      _currentBrightness = await ScreenBrightnessPlatform.instance.application;
    }
  }

  /// 竖向手势更新
  void onVerticalDragUpdate(DragUpdateDetails e) async {
    if (lockControlsState.value && fullScreenState.value) {
      return;
    }
    // todo: lockControls 可以临时解锁，滑动结束后再次上锁，让ai来做这些简单的工作
    if (AppSettingsController.instance.verticalDragLock.value) {
      return;
    }
    if (verticalDragging == false) return;
    if (!Platform.isAndroid && !Platform.isIOS && !Platform.isWindows) {
      return;
    }
    //String text = "";
    //double value = 0.0;

    Log.logPrint("$verStartPosition/${e.globalPosition.dy}");

    if (Platform.isWindows) {
      // Windows 全区域竖滑调音量（不做亮度调节）
      setGestureVolume(e.globalPosition.dy);
    } else if (leftVerticalDrag) {
      setGestureBrightness(e.globalPosition.dy);
    } else {
      setGestureVolume(e.globalPosition.dy);
    }
  }

  int lastVolume = -1; // it's ok to be -1

  void setGestureVolume(double dy) {
    double value = 0.0;
    double seek;
    if (dy > verStartPosition) {
      value = ((dy - verStartPosition) / (Get.height * 0.5));

      seek = _currentVolume - value;
      if (seek < 0) {
        seek = 0;
      }
    } else {
      value = ((dy - verStartPosition) / (Get.height * 0.5));
      seek = value.abs() + _currentVolume;
      if (seek > 1) {
        seek = 1;
      }
    }
    int volume = _convertVolume((seek * 100).round());
    if (volume == lastVolume) {
      return;
    }
    lastVolume = volume;
    // update UI outside throttle to make it more fluent
    gestureTipText.value = "音量 $volume%";
    throttle?.invoke(() async => await _realSetVolume(volume));
  }

  // 0 to 100, 5 step each
  int _convertVolume(int volume) {
    return (volume / 5).round() * 5;
  }

  Future _realSetVolume(int volume) async {
    Log.logPrint(volume);
    if (Platform.isWindows) {
      // Windows 用播放器音量并同步到设置（volume_controller 不支持 Windows）
      player.setVolume(volume.toDouble());
      AppSettingsController.instance.setPlayerVolume(volume.toDouble());
    } else {
      volumeController.setVolume(volume / 100);
    }
  }

  void setGestureBrightness(double dy) {
    double value = 0.0;
    if (dy > verStartPosition) {
      value = ((dy - verStartPosition) / (Get.height * 0.5));

      var seek = _currentBrightness - value;
      if (seek < 0) {
        seek = 0;
      }
      ScreenBrightnessPlatform.instance.setApplicationScreenBrightness(seek);

      gestureTipText.value = "亮度 ${(seek * 100).toInt()}%";
      Log.logPrint(value);
    } else {
      value = ((dy - verStartPosition) / (Get.height * 0.5));
      var seek = value.abs() + _currentBrightness;
      if (seek > 1) {
        seek = 1;
      }

      ScreenBrightnessPlatform.instance.setApplicationScreenBrightness(seek);
      gestureTipText.value = "亮度 ${(seek * 100).toInt()}%";
      Log.logPrint(value);
    }
  }

  /// 竖向手势完成
  void onVerticalDragEnd(DragEndDetails details) async {
    if (lockControlsState.value && fullScreenState.value) {
      return;
    }
    if (AppSettingsController.instance.verticalDragLock.value) {
      return;
    }
    throttle = null;
    verticalDragging = false;
    leftVerticalDrag = false;
    showGestureTip.value = false;
  }
}

class PlayerController extends BaseController
    with PlayerMixin, PlayerStateMixin, PlayerDanmakuMixin, PlayerSystemMixin, PlayerGestureControlMixin {
  @override
  void onInit() {
    initSystem();
    initStream();
    //设置音量
    player.setVolume(AppSettingsController.instance.playerVolume.value);
    //音量均衡：回填已持久化的能力探测结果（跨启动记忆；App 版本变化则自动失效重探）
    afLoudnormSupported ??= _readPersistedCapability();
    if (afLoudnormSupported != null) {
      AppSettingsController.instance.setVolumeNormSupported(afLoudnormSupported);
    }
    //音量均衡热切换：设置页/房内开关拨动即时生效
    //PR #195 教训：句柄化管理 + onClose 释放 + 回调内 disposed 短路
    _volumeNormWorker = ever(AppSettingsController.instance.volumeNorm, (bool on) {
      if (_playerDisposed) {
        return;
      }
      //未播放且能力未知：不在此刻探测（空闲探测不可靠，可能假成功），留到首帧钩子统一处理
      if (afLoudnormSupported == null && !player.state.playing) {
        return;
      }
      _syncVolumeNorm();
    });
    // VSR：直播间接开关即生效（复用音量均衡的热切换范式：worker + 串行队列 + 错误抑制）
    _rtxVsrWorker = ever(AppSettingsController.instance.enableRtxVsr, (bool on) {
      if (_playerDisposed || !Platform.isWindows) {
        return;
      }
      _applyRtxVsrSetting();
    });
    super.onInit();
  }

  /// 音量均衡：进程级能力缓存（null=未探测；libmpv 构建固定，探测一次即可）
  static bool? afLoudnormSupported;

  /// 音量均衡：本房间是否已应用 af
  bool _volumeNormApplied = false;

  /// 音量均衡：本房间首帧播放的一次性探测是否已执行
  bool _volumeNormInitialized = false;

  /// 音量均衡：抑制窗口内播放器日志是否报出滤镜链失败（静默降级防线）
  bool _volumeNormLogFailure = false;

  /// 音量均衡：热切换监听器句柄（onClose 必须释放；裸 ever() 退房后断言，PR #195 教训）
  Worker? _volumeNormWorker;

  /// VSR：开关热切换监听器句柄（onClose 必须释放，PR #195 教训）
  Worker? _rtxVsrWorker;

  /// 音量均衡：操作串行队列（探测/应用/移除按发起顺序执行，避免并发交错导致 af 与状态标记不一致）
  Future<void> _volumeNormQueue = Future<void>.value();

  StreamSubscription<String>? _errorSubscription;
  StreamSubscription? _completedSubscription;
  StreamSubscription? _widthSubscription;
  StreamSubscription? _heightSubscription;
  StreamSubscription? _logSubscription;
  StreamSubscription? _playingSubscription;
  StreamSubscription? _escSubscription;

  void initStream() {
    _errorSubscription = player.stream.error.listen((event) {
      Log.d("播放器错误：$event");
      // 音量均衡探测/切换期间：af 写入失败的错误事件直接跳过，不触发重拉流（PR #195 教训）
      if (_suppressErrorRetry) {
        Log.d("音量均衡探测期，抑制错误事件：$event");
        return;
      }
      // 跳过无音频输出的错误
      // Could not open/initialize audio device -> no sound.
      if (event.contains('no sound.')) {
        return;
      }
      //SmartDialog.showToast(event);
      mediaError(event);
    });

    _playingSubscription = player.stream.playing.listen((event) {
      if (event) {
        WakelockPlus.enable();
        Log.d("Playing");
        // 进入直播间按分辨率自适应窗口宽度（播放开始时布局已就绪，重试至生效）
        if (AppSettingsController.instance.autoFitWindowWidth.value &&
            !AppSettingsController.instance.autoFullScreen.value) {
          fitPanelWidthToVideo();
        }
        // 音量均衡：首帧播放后一次性同步（能力未知时顺带探测，必须播放中做）
        if (!_volumeNormInitialized) {
          _volumeNormInitialized = true;
          _syncVolumeNorm();
        }
      }
    });

    _completedSubscription = player.stream.completed.listen((event) {
      if (event) {
        mediaEnd();
      }
    });
    _logSubscription = player.stream.log.listen((event) {
      Log.d("播放器日志：$event");
      // 音量均衡静默降级防线（复核建议）：抑制窗口内命中滤镜错误关键字即标记失败，
      // 由 _probeVolumeNormCapability 结合回读结果判定「不支持」。
      if (_suppressErrorRetry && volumeNormLogIndicatesFailure(event)) {
        Log.d("音量均衡：日志命中滤镜错误关键字 → 判定链未挂上：$event");
        _volumeNormLogFailure = true;
      }
    });
    _widthSubscription = player.stream.width.listen((event) {
      Log.d('width:$event  W:${(player.state.width)}  H:${(player.state.height)}');
      _syncRtxVsrCrop();
      // RISK-17：分辨率一到就记下来（与「自适应/自动全屏」等设置解耦），
      // 供页面判定覆盖式面板；否则在未开自适应或处于全屏时该值恒为 0 → 永不折叠。
      if ((player.state.width ?? 0) > 0 && (player.state.height ?? 0) > 0) {
        videoWidthRx.value = player.state.width!;
        videoHeightRx.value = player.state.height!;
      }
      if (player.state.width == null) {
        return;
      } else {
        // 可获取直播流size时且不为全屏模式时判断是否进入全屏模式
        isVertical.value = player.state.height! > player.state.width!;
        if (AppSettingsController.instance.autoFullScreen.value && !fullScreenState.value) {
          enterFullScreen();
        } else if (AppSettingsController.instance.autoFitWindowWidth.value) {
          // 进入直播间后按分辨率自适应窗口宽度（保持高度）
          Future.delayed(const Duration(milliseconds: 350), fitPanelWidthToVideo);
        }
      }
    });
    _heightSubscription = player.stream.height.listen((event) {
      Log.d('height:$event  W:${(player.state.width)}  H:${(player.state.height)}');
      _syncRtxVsrCrop();
      if ((player.state.width ?? 0) > 0 && (player.state.height ?? 0) > 0) {
        videoWidthRx.value = player.state.width!;
        videoHeightRx.value = player.state.height!;
      }
      isVertical.value = (player.state.height ?? 9) > (player.state.width ?? 16);
      if (AppSettingsController.instance.autoFitWindowWidth.value &&
          !AppSettingsController.instance.autoFullScreen.value) {
        Future.delayed(const Duration(milliseconds: 350), fitPanelWidthToVideo);
      }
    });
    _escSubscription = EventBus.instance.listen(EventBus.kEscapePressed, (event) {
      exitFull();
    });
  }

  void disposeStream() {
    _errorSubscription?.cancel();
    _completedSubscription?.cancel();
    _widthSubscription?.cancel();
    _heightSubscription?.cancel();
    _logSubscription?.cancel();
    _pipSubscription?.cancel();
    _playingSubscription?.cancel();
    _escSubscription?.cancel();
  }

  void mediaEnd() {
    // 弱网调整：用户自责
    // WakelockPlus.disable();
  }

  void mediaError(String error) {
    // 弱网调整：用户自责
    // WakelockPlus.disable();
  }

  /// 音量均衡：把播放器 af 状态同步到「用户意愿 + 已探测能力」（首帧钩子 / 热切换共用）
  /// 所有 af 操作经队列串行化：探测期间用户拨开关时，后一次同步会排队到探测结束后执行，
  /// 避免两次探测并发导致「af 已开但标记为关」而无法关闭的错乱
  Future<void> _syncVolumeNorm() {
    return _enqueueVolumeNorm(() async {
      if (_playerDisposed) {
        return;
      }
      afLoudnormSupported ??= _readPersistedCapability();
      if (afLoudnormSupported == null) {
        // 能力未知：执行一次探测（探测后按用户意愿自动还原/保持）
        await _probeVolumeNormCapability();
        return;
      }
      if (AppSettingsController.instance.volumeNorm.value) {
        if (volumeNormShouldApply(userOn: true, supported: afLoudnormSupported)) {
          await _applyVolumeNorm(enable: true);
        }
      } else if (_volumeNormApplied) {
        await _applyVolumeNorm(enable: false);
      }
    });
  }

  /// 音量均衡：操作串行队列（异常在队列内消化，避免 fire-and-forget 产生未处理异步异常）
  Future<void> _enqueueVolumeNorm(Future<void> Function() task) {
    final next = _volumeNormQueue.then((_) async {
      try {
        await task();
      } catch (e) {
        Log.logPrint(e);
      }
    });
    _volumeNormQueue = next;
    return next;
  }

  /// 音量均衡：起流前预挂链（由 `initializePlayer` 在 `player.open` 之前调用）。
  ///
  /// 失败不阻塞起流：仅记录，交由首帧回读校验兜底（不支持会自动还原并置灰开关）。
  Future<void> _preApplyVolumeNorm() async {
    final pp = player.platform;
    if (pp is! NativePlayer) {
      return;
    }
    final token = ++_suppressToken;
    _suppressErrorRetry = true;
    _volumeNormLogFailure = false;
    try {
      await pp.setProperty('af', volumeNormFilter);
      _volumeNormApplied = true;
    } catch (e) {
      Log.logPrint(e);
      _volumeNormApplied = false;
    }
    _scheduleSuppressRelease(token);
  }

  /// 音量均衡：探测能力（设置 af → 回读校验），探测后按用户意愿还原或保持
  Future<void> _probeVolumeNormCapability() async {
    if (_playerDisposed) {
      return;
    }
    final pp = player.platform;
    if (pp is! NativePlayer) {
      return;
    }
    final token = ++_suppressToken;
    _suppressErrorRetry = true;
    var supported = false;
    try {
      // 起流前已预挂（_volumeNormApplied=true）时只回读校验、不再 set：
      // set 会重建整条链并重置 loudnorm 收敛状态 → 进房第一秒响度又爬一遍。
      if (!_volumeNormApplied) {
        _volumeNormLogFailure = false;
        await pp.setProperty('af', volumeNormFilter);
      }
      // 回读校验：mpv 对非法/不存在的滤镜会拒绝写入并保持旧值，
      // 因此回读必须同时包含 dynaudnorm 与 loudnorm 才算支持（只查 loudnorm 不严）。
      final readback = await pp.getProperty('af');
      supported =
          volumeNormSupportedFromReadback(readback) && !_volumeNormLogFailure;
    } catch (e) {
      Log.logPrint(e);
      supported = false;
    }
    afLoudnormSupported = supported;
    _persistCapability(supported);
    AppSettingsController.instance.setVolumeNormSupported(supported);
    final keepOn = supported && AppSettingsController.instance.volumeNorm.value;
    if (keepOn) {
      _volumeNormApplied = true;
    } else {
      // 用户未开启或能力不支持：探测后立即还原为空 af，不影响实际听感
      try {
        await pp.setProperty('af', '');
      } catch (e) {
        Log.logPrint(e);
      }
      _volumeNormApplied = false;
    }
    if (!supported) {
      SmartDialog.showToast("当前播放核心不支持音量均衡，开关已禁用");
    }
    _scheduleSuppressRelease(token);
  }

  /// 音量均衡：对播放器应用/移除 loudnorm 滤镜（能力已知时使用；仅由 _syncVolumeNorm 在队列内调用）
  Future<void> _applyVolumeNorm({required bool enable}) async {
    if (_playerDisposed) {
      return;
    }
    final pp = player.platform;
    if (pp is! NativePlayer) {
      return;
    }
    if (enable == _volumeNormApplied) {
      return;
    }
    if (enable && afLoudnormSupported == false) {
      // 已知不支持：不再尝试（UI 已禁用，这里是保险短路）
      return;
    }
    final token = ++_suppressToken;
    _suppressErrorRetry = true;
    try {
      await pp.setProperty('af', enable ? volumeNormFilter : '');
      _volumeNormApplied = enable;
    } catch (e) {
      Log.logPrint(e);
      if (enable) {
        // 开启失败：保守回退到无滤镜并禁用开关
        try {
          await pp.setProperty('af', '');
        } catch (_) {}
        _volumeNormApplied = false;
        afLoudnormSupported = false;
        _persistCapability(false);
        AppSettingsController.instance.setVolumeNormSupported(false);
        SmartDialog.showToast("音量均衡应用失败，已禁用开关");
      } else {
        // 关闭失败：回读真实状态，避免 UI 显示与实际听感不一致
        try {
          final readback = await pp.getProperty('af');
          _volumeNormApplied = volumeNormSupportedFromReadback(readback);
        } catch (e2) {
          Log.logPrint(e2);
          // 回读也失败：保守保持「已应用」，下次关闭会重试
          _volumeNormApplied = true;
        }
        if (_volumeNormApplied) {
          SmartDialog.showToast("音量均衡关闭失败，请重试");
        }
      }
    }
    _scheduleSuppressRelease(token);
  }

  /// 音量均衡：读取已持久化的能力探测结果（带 App 版本前缀，版本变化即失效重探）
  bool? _readPersistedCapability() {
    final raw = LocalStorageService.instance.getValue<String>(
      LocalStorageService.kVolumeNormSupported,
      "",
    );
    final prefix = "${Utils.packageInfo.version}:";
    if (raw.isEmpty || !raw.startsWith(prefix)) {
      return null;
    }
    return raw.substring(prefix.length) == "true";
  }

  void _persistCapability(bool supported) {
    LocalStorageService.instance.setValue(
      LocalStorageService.kVolumeNormSupported,
      "${Utils.packageInfo.version}:$supported",
    );
  }

  /// 应用 NVIDIA RTX VSR 设置（进房与直播间接开关共用）：更新链状态并立即同步。
  ///
  /// 重挂/摘除滤镜链会让 mpv 重建 D3D11 链路，期间可能冒 `stream.error` → 被当成
  /// 媒体错误去重拉流/切线路（PR #195 教训）→ 用音量均衡同款抑制窗口兜住。
  /// 不走 250ms 防抖（用户点了要立即生效），串行安全由 `_syncRtxVsrCrop` 内部队列兜底。
  Future<void> _applyRtxVsrSetting() async {
    if (_playerDisposed || !Platform.isWindows) return;
    final pp = player.platform;
    if (pp is! NativePlayer) return;
    final enabled = AppSettingsController.instance.enableRtxVsr.value;
    _rtxVsrChainApplied = enabled;
    // 强制重算（开关变化必须重挂/摘链）。
    _lastRtxVsrSignature = null;
    // 注：**不清 `_lastRtxVsrScale`**——它是「mpv 实际已挂链」的唯一记录，摘链判断依赖它非空；
    // 在决定动作前清空会导致关闭时永不摘链→绿条复现（阶段4 复核 P0）。
    // hwdec 与错误抑制由 `_syncRtxVsrCrop` 内部统一处理。
    try {
      await _syncRtxVsrCrop();
    } catch (e) {
      Log.d('[VSR] 热切换失败: $e');
    }
  }

  Future<void> toggleOSDStats() async {
    showOSDStats.value = !showOSDStats.value;
    if (player.platform is NativePlayer) {
      await (player.platform as NativePlayer).command([
        'script-binding',
        'stats/display-page-1-toggle',
      ]);
    }
  }

  void showDebugInfo() {
    Utils.showBottomSheet(
      title: "播放信息",
      child: ListView(
        children: [
          Obx(() => SwitchListTile(
              title: const Text("OSD 显示"), value: showOSDStats.value, onChanged: (value) => toggleOSDStats())),
          ListTile(
            title: const Text("Resolution"),
            subtitle: Text('${player.state.width}x${player.state.height}'),
            onTap: () {
              Clipboard.setData(
                ClipboardData(
                  text: "Resolution\n${player.state.width}x${player.state.height}",
                ),
              );
            },
          ),
          ListTile(
            title: const Text("VideoParams"),
            subtitle: Text(player.state.videoParams.toString()),
            onTap: () {
              Clipboard.setData(
                ClipboardData(
                  text: "VideoParams\n${player.state.videoParams}",
                ),
              );
            },
          ),
          ListTile(
            title: const Text("AudioParams"),
            subtitle: Text(player.state.audioParams.toString()),
            onTap: () {
              Clipboard.setData(
                ClipboardData(
                  text: "AudioParams\n${player.state.audioParams}",
                ),
              );
            },
          ),
          ListTile(
            title: const Text("Media"),
            subtitle: Text(player.state.playlist.toString()),
            onTap: () {
              Clipboard.setData(
                ClipboardData(
                  text: "Media\n${player.state.playlist}",
                ),
              );
            },
          ),
          ListTile(
            title: const Text("AudioTrack"),
            subtitle: Text(player.state.track.audio.toString()),
            onTap: () {
              Clipboard.setData(
                ClipboardData(
                  text: "AudioTrack\n${player.state.track.audio}",
                ),
              );
            },
          ),
          ListTile(
            title: const Text("VideoTrack"),
            subtitle: Text(player.state.track.video.toString()),
            onTap: () {
              Clipboard.setData(
                ClipboardData(
                  text: "VideoTrack\n${player.state.track.audio}",
                ),
              );
            },
          ),
          ListTile(
            title: const Text("AudioBitrate"),
            subtitle: Text(player.state.audioBitrate.toString()),
            onTap: () {
              Clipboard.setData(
                ClipboardData(
                  text: "AudioBitrate\n${player.state.audioBitrate}",
                ),
              );
            },
          ),
          ListTile(
            title: const Text("Volume"),
            subtitle: Text(player.state.volume.toString()),
            onTap: () {
              Clipboard.setData(
                ClipboardData(
                  text: "Volume\n${player.state.volume}",
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  @override
  void onClose() async {
    Log.w("播放器关闭");
    _playerDisposed = true;
    _volumeNormWorker?.dispose();
    _volumeNormWorker = null;
    _rtxVsrWorker?.dispose();
    _rtxVsrWorker = null;
    if (smallWindowState.value) {
      exitSmallWindow();
    }
    disposeStream();
    disposeDanmakuController();
    await resetSystem();
    // todo: https://github.com/media-kit/media-kit/issues/1443
    // only in debug mode
    await player.dispose();
    super.onClose();
  }
}
