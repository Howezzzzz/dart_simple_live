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
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_app/modules/live_room/danmaku/danmaku_emoticon.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:window_manager/window_manager.dart';

/// 音量均衡滤镜：EBU R128 loudnorm 单遍动态模式（面向直播场景）
/// I=-16 目标响度 LUFS / TP=-1.5 真峰值 dBTP / LRA=11 响度范围
/// 单遍动态模式无前瞻延迟；相比 dynaudnorm 更贴近响度标准，跨直播间响度一致性更好
const String volumeNormFilter = 'loudnorm=I=-16:TP=-1.5:LRA=11';

/// 音量均衡探测期错误抑制时长：mpv 的 af 写入失败会以 stream.error 事件异步到达，
/// 需在 set 之后留出窗口，避免误触发 mediaError 重拉流（PR #195 教训）
const Duration volumeNormSuppressDuration = Duration(seconds: 2);

mixin PlayerMixin {
  GlobalKey<VideoState> globalPlayerKey = GlobalKey<VideoState>();
  GlobalKey globalDanmuKey = GlobalKey();

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
    // media_kit 仓库更新导致的问题，临时解决办法
    if (Platform.isAndroid) {
      // 通过错误参数强制media_kit不seek, 解决了加载-pause-seek 在直播流上的开屏问题
      await pp.setProperty('force-seekable', 'yes');
    }
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
      await pp.setProperty('vf', 'd3d11vpp=scale=2:scaling-mode=nvidia');
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
    // todo: 还应该关闭所有的dialog
    SmartDialog.dismiss();
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
        //选择保存文件夹
        var path = await FilePicker.saveFile(
          allowedExtensions: ["jpg"],
          type: FileType.image,
          fileName: "${DateTime.now().millisecondsSinceEpoch}.jpg",
        );
        if (path == null) {
          SmartDialog.showToast("取消保存");
          SmartDialog.dismiss(status: SmartStatus.loading);
          return;
        }
        var file = File(path);
        await file.writeAsBytes(imageData);
        SmartDialog.showToast("已保存截图至${file.path}");
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
    super.onInit();
  }

  /// 音量均衡：进程级能力缓存（null=未探测；libmpv 构建固定，探测一次即可）
  static bool? afLoudnormSupported;

  /// 音量均衡：探测/切换期间抑制错误重试（af 写入失败会以 stream.error 到达，
  /// 不抑制会误触发 mediaError→重拉流/切线路，PR #195 的实测缺陷）
  bool _suppressErrorRetry = false;

  /// 音量均衡：抑制令牌（并发/时序保护，仅最新令牌允许解除抑制）
  int _suppressToken = 0;

  /// 音量均衡：本房间是否已应用 af
  bool _volumeNormApplied = false;

  /// 音量均衡：本房间首帧播放的一次性探测是否已执行
  bool _volumeNormInitialized = false;

  /// 音量均衡：热切换监听器句柄（onClose 必须释放；裸 ever() 退房后断言，PR #195 教训）
  Worker? _volumeNormWorker;

  /// 音量均衡：操作串行队列（探测/应用/移除按发起顺序执行，避免并发交错导致 af 与状态标记不一致）
  Future<void> _volumeNormQueue = Future<void>.value();

  /// 播放器已释放标记（异步回调短路，防止已释放播放器断言）
  bool _playerDisposed = false;

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
    });
    _widthSubscription = player.stream.width.listen((event) {
      Log.d('width:$event  W:${(player.state.width)}  H:${(player.state.height)}');
      if (player.state.width == null) {
        return;
      } else {
        // 可获取直播流size时且不为全屏模式时判断是否进入全屏模式
        isVertical.value = player.state.height! > player.state.width!;
        if (AppSettingsController.instance.autoFullScreen.value && !fullScreenState.value) {
          enterFullScreen();
        }
      }
    });
    _heightSubscription = player.stream.height.listen((event) {
      Log.d('height:$event  W:${(player.state.width)}  H:${(player.state.height)}');
      isVertical.value = (player.state.height ?? 9) > (player.state.width ?? 16);
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
    WakelockPlus.disable();
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
        if (afLoudnormSupported == true) {
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
      await pp.setProperty('af', volumeNormFilter);
      // 回读校验：af 为未知滤镜时 mpv 会拒绝写入并保持旧值，
      // 因此回读是否包含 loudnorm 即可判定二进制是否支持
      final readback = await pp.getProperty('af');
      supported = readback.contains('loudnorm');
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
          _volumeNormApplied = readback.contains('loudnorm');
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

  void _scheduleSuppressRelease(int token) {
    // 延迟解除抑制：mpv 错误事件可能略晚于 setProperty 返回
    Future.delayed(volumeNormSuppressDuration, () {
      if (_playerDisposed) {
        return;
      }
      if (token == _suppressToken) {
        _suppressErrorRetry = false;
      }
    });
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
