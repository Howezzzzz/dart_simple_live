import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/event_bus.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:window_manager/window_manager.dart';

class WindowService extends GetxService implements WindowListener {
  static WindowService get instance => Get.find<WindowService>();

  bool isPIP = false;
  bool isMaxAuto = false;
  bool isMaxState = false;

  WindowService() {
    windowManager.addListener(this);
  }

  Future<void> init() async {
    isMaxAuto = AppSettingsController.instance.windowMaxAuto.value;
    isMaxState = AppSettingsController.instance.windowMaxState.value;
    final width = LocalStorageService.instance.getValue(LocalStorageService.kWindowWidth, 1280.0);
    final height = LocalStorageService.instance.getValue(LocalStorageService.kWindowHeight, 720.0);
    final x = LocalStorageService.instance.getValue(LocalStorageService.kWindowX, 320.0);
    final y = LocalStorageService.instance.getValue(LocalStorageService.kWindowY, 180.0);
    final wasMaximized =
        LocalStorageService.instance.getValue(LocalStorageService.kWindowWasMaximized, false);

    AppSettingsController.instance.danmakuFontResize = await danmakuFontClamped();
    await windowManager.setPosition(Offset(x, y));
    WindowOptions windowOptions = WindowOptions(
      size: Size(width, height),
      minimumSize: Size(320, 280), // 防止无脑小窗导致界面报错
      center: false,
      title: "Slive",
    );
    await windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
      // 最大化在显示之后 防止卡白屏
      // 恢复上次关闭时的最大化状态；或开启「开屏最大化」时强制最大化
      if (wasMaximized || (isMaxAuto && isMaxState)) {
        await WidgetsBinding.instance.endOfFrame;
        await windowManager.maximize();
      }
      await windowManager.focus();
    });
  }

  @override
  void onWindowBlur() {}

  @override
  void onWindowClose() async {
    // 关闭前兜底保存窗口状态（不只依赖拖动/缩放事件）
    await saveNormalWindowState();
    if (Platform.isLinux) {
      exit(0);
    }
  }

  @override
  void onWindowDocked() {}

  @override
  Future<void> onWindowEnterFullScreen() async {
    // https://github.com/leanflutter/window_manager/issues/560
    // https://github.com/leanflutter/window_manager/pull/531
    await danmakuFontClamped();
  }

  @override
  void onWindowEvent(String eventName) {}

  @override
  void onWindowFocus() {}

  @override
  Future<void> onWindowLeaveFullScreen() async {
    // issues 同上
    await danmakuFontClamped();
  }

  @override
  Future<void> onWindowMaximize() async {
    LocalStorageService.instance.setValue(LocalStorageService.kWindowWasMaximized, true);
    if(AppSettingsController.instance.windowMaxAuto.value){
      AppSettingsController.instance.setWindowMaxState(true);
    }
    await danmakuFontClamped();
  }

  @override
  void onWindowMinimize() {}

  @override
  Future<void> onWindowMove() async {}

  @override
  Future<void> onWindowMoved() async {
    await windowStateChanged();
  }

  @override
  Future<void> onWindowResize() async {}

  @override
  Future<void> onWindowResized() async {
    await windowStateChanged();
  }

  @override
  void onWindowRestore() {}

  @override
  void onWindowUndocked() {}

  @override
  Future<void> onWindowUnmaximize() async {
    LocalStorageService.instance.setValue(LocalStorageService.kWindowWasMaximized, false);
    AppSettingsController.instance.setWindowMaxState(false);
    await danmakuFontClamped();
  }

  Future<void> windowStateChanged() async {
    final size = await windowManager.getSize();
    final position = await windowManager.getPosition();
    if (!isPIP) {
      await danmakuFontClamped();
      await saveNormalWindowState();
    } else {
      _savePipSizeAndPositon(size, position);
    }
  }

  /// 保存「正常窗口状态」：最大化/全屏时不覆盖尺寸（避免把最大化尺寸存进去），
  /// 但始终记录「上次是否最大化」以在重开时恢复。
  Future<void> saveNormalWindowState() async {
    try {
      final isMax = await windowManager.isMaximized();
      final isFull = await windowManager.isFullScreen();
      LocalStorageService.instance
          .setValue(LocalStorageService.kWindowWasMaximized, isMax);
      if (isMax || isFull) {
        return;
      }
      final size = await windowManager.getSize();
      final position = await windowManager.getPosition();
      _saveSizeAndPositon(size, position);
    } catch (e) {
      Log.logPrint(e);
    }
  }

  void _saveSizeAndPositon(Size s, Offset position) {
    LocalStorageService.instance.setValue(LocalStorageService.kWindowX, position.dx);
    LocalStorageService.instance.setValue(LocalStorageService.kWindowY, position.dy);
    LocalStorageService.instance.setValue(LocalStorageService.kWindowWidth, s.width);
    LocalStorageService.instance.setValue(LocalStorageService.kWindowHeight, s.height);
  }

  void _savePipSizeAndPositon(Size s, Offset position) {
    AppSettingsController.instance.setWindowPipX(position.dx);
    AppSettingsController.instance.setWindowPipY(position.dy);
    AppSettingsController.instance.setWindowPipWidth(s.width);
    AppSettingsController.instance.setWindowPipHeight(s.height);
  }

  // 启用后，当 Resized/Maximize/full -> re 后调整
  // 通过service 通知 live_controller 更新 danmaku_option
  // 因为media_kit的 w/h 均为 null, 所以只能从外部window_manager设计
  Future<double> danmakuFontClamped() async {
    // 应该更进一步判断用户是否在直播间界面, 小窗模式恢复默认弹幕尺寸
    if (AppSettingsController.instance.danmakuFontClamped.value && !isPIP) {
      final size = await windowManager.getSize();
      var windowH = size.height;
      Log.i('player_danmaku_size_h: $windowH');
      // 窗口设计分辨率默认 1280x720
      var reSizeFont =  Utils.scaleValue(
        value: AppSettingsController.instance.danmuSize.value,
        playerH: windowH,
        designH: 720.0,
        upSens: AppSettingsController.instance.danmakuFontClampUpSens.value / 10,
        downSens: AppSettingsController.instance.danmakuFontClampDownSens.value / 10,
        minSize: 8,
        maxSize: 48,
      );
      EventBus.instance.emit(Constant.kUpdateDanmaku, reSizeFont);
      Log.i('player_danmaku_size: $reSizeFont');
      return reSizeFont;
    } else {
      // 防御性，反复测试功能过程中弹幕
      EventBus.instance.emit(Constant.kUpdateDanmaku, AppSettingsController.instance.danmuSize.value);
      return AppSettingsController.instance.danmuSize.value;
    }
  }
}
