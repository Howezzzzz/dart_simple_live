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
import 'package:simple_live_app/app/utils/ready_gate.dart';
import 'package:simple_live_app/app/utils/rtx_vsr_crop.dart';
import 'package:simple_live_app/app/utils/serial_queue.dart';
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

/// 一次 VSR 链写入的完整目标（P1-1 起播前单次写链：门控期吞中间写，
/// settle 尾沿 / 超时放行时一次性写入终值）。
class _VsrTarget {
  const _VsrTarget({
    required this.signature,
    required this.trigger,
    required this.enable,
    required this.scale,
    required this.crop,
    required this.aspect,
    required this.renderSize,
    required this.rawW,
    required this.rawH,
    required this.area,
  });

  /// 去重签名（与 _lastRtxVsrSignature 同格式）。
  final String signature;

  /// 触发来源（size / layout / toggle / init / release），用于日志归因。
  final String trigger;

  /// 是否挂链（VSR 开且倍数有效）。
  final bool enable;

  /// 自适应倍数（null = 不挂）。
  final double? scale;

  /// mpv video-crop 目标值（空串 = 不裁）。
  final String crop;

  /// video-aspect-override 目标值。
  final double aspect;

  /// 渲染画布尺寸（null = 恢复默认）。
  final (int, int)? renderSize;

  /// 决策时的源尺寸（写后用于校验尺寸是否已变）。
  final int rawW;
  final int rawH;

  /// 决策时的播放区物理尺寸（日志用）。
  final (int, int)? area;
}

mixin PlayerMixin {
  GlobalKey<VideoState> globalPlayerKey = GlobalKey<VideoState>();
  GlobalKey globalDanmuKey = GlobalKey();

  /// 当前视频分辨率（供布局判定「覆盖式面板」实时刷新，2026-10-21 RISK-17）。
  /// 由 player 的 width/height 流直接更新（与自适应/全屏等设置**解耦**）——
  /// 页面 Obx 读取它触发重建；fitPanelWidthToVideo 亦会更新（冗余但无害）。
  var videoWidthRx = 0.obs;
  var videoHeightRx = 0.obs;

  /// 起播就绪遮罩（RISK-69 优雅版 / 方案 §三 B2）：进房后「管线就绪」前为 true，
  /// 页面据此在播放区盖加载态，遮掉「闪一下 → 黑 → 再闪」；就绪/超时后置 false（150ms 淡出）。
  var showReadyMaskRx = false.obs;

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
    // 诊断：起播时间线起点 + 相关设置快照（下版真机复测直读）
    _tlReset();
    _tlMark('t0 进房');
    Log.d('[DIAG] 设置: VSR=${AppSettingsController.instance.enableRtxVsr.value}'
        ' 均衡=${AppSettingsController.instance.volumeNorm.value}'
        ' 双缓冲=${AppSettingsController.instance.videoDoubleBuffering.value}'
        ' 自适应窗口宽度=${AppSettingsController.instance.autoFitWindowWidth.value}'
        ' 自动全屏=${AppSettingsController.instance.autoFullScreen.value}');

    // NVIDIA RTX VSR 支持 (Windows 平台)
    // 注：抽成纯函数用于回归防线——「是否因 VSR 而延迟起播」只允许 Windows+VSR 开启，
    // 其它情况必须保持自动起播（见 rtx_vsr_crop.dart 的 vsrShouldDeferPlay）。
    final vsrOn = vsrShouldDeferPlay(
      isWindows: Platform.isWindows,
      vsrEnabled: AppSettingsController.instance.enableRtxVsr.value,
    );
    if (vsrOn) {
      await pp.setProperty('hwdec', 'd3d11va');
      // 起播门控（P1-1 起播前单次写链）：不再预挂 2.0 兜底链——链在门控放行时按自适应
      // 终值**一次**写入；预挂 2.0 只在门控**超时**路径兜底（见 _preHangFallbackChain）。
      // _rtxVsrChainApplied 置 true 表示本次播放启用 VSR（门控期 plan 按「开」算自适应倍数）。
      _rtxVsrChainApplied = true;
    } else if (Platform.isWindows) {
      // 关闭 VSR 时必须摘掉已挂上的滤镜链（复核 P2-1）：只改标志不摘链的话，
      // 同一会话 F5/切清晰度重初始化后，链仍在放大画面、裁切却被清空 → 绿条复现且 VSR 代价照付。
      await pp.setProperty('vf', '');
      _lastRtxVsrScale = null;
      _rtxVsrChainApplied = false;
      // 注（复核澄清）：这里 disarm 是安全的——initializePlayer 全仓只有一个调用点
      // （initPlaylist），它紧接着就 `open(play: !vsrDeferPlayPending)`，VSR 关时即 play:true，必起播。
      _disarmVsrDeferPlay();
    }
    // 音量均衡：**起流前**预挂滤镜链（此处早于 live_room_controller 的 player.open）。
    // 旧的「首帧播放后才挂」会让进房头 1–3s 完全没有处理（两轮复核整合结论）。
    // 幂等：已挂则不重复 set —— set 会重建整条链并重置 loudnorm 的收敛状态。
    // 复核 P0-3：仅「能力已知支持」才预挂——能力未知时 mpv 可能静默拒绝链
    // （media_kit 的 setProperty 忽略返回码），未知即预挂会起流期无声且把错误能力
    // 持久化；未知时交给首帧探测（自带 set+回读），探测成功后本进程后续进房即享预挂。
    // 复核 P1-5：预挂也走串行队列（_enqueueVolumeNorm），避免与热切换的 set af 交错
    // （进房瞬间拨开关时，后落地的 set 会把已关的均衡又打开且状态标 false）。
    // glm 复核 P2：initializePlayer 可能因切清晰度/重开被再次调用——重置首帧钩子，
    // 让 open 后的 playing 重发时再跑一次自愈+复查（否则一次性钩子跳过，open 清链
    // 后本房静默失去均衡且无人重挂）。
    _volumeNormInitialized = false;
    if (!_volumeNormApplied &&
        volumeNormShouldPreApply(
          userOn: AppSettingsController.instance.volumeNorm.value,
          supported: afLoudnormSupported,
        )) {
      await _enqueueVolumeNorm(() => _preApplyVolumeNorm());
    }
    // 同步底部补边裁切（VSR 开启才裁；关闭时显式清空，避免切线路等场景残留上次的裁切）。
    // 起播门控：在**末尾**才武装（复核 P6：让超时从 open 前一刻起算，不被前面的音量均衡
    // 预挂等 await 吃掉预算）；武装时跳过此处预同步——此刻 player.state 还是上一路流的旧尺寸，
    // 同步会写入错的链/裁切；真正的同步由 open 后「尺寸重置 → 新尺寸」事件驱动（见 width/height 监听）。
    if (vsrOn && _vsrGateApplicable) {
      _armVsrDeferPlay();
    } else {
      // 复验 P3：vsrOn 是本函数**开头**的快照，中途热关 VSR 会让它过期——若仍按它武装，
      // 后面 open(play:false) 就会白等到超时（最长 3s）。这里用实时判据再确认一次。
      _disarmVsrDeferPlay();
      await _syncRtxVsrCrop(trigger: 'init');
    }
    // 诊断：进房后 5s 快照（看得见现场状态）；绑定代际，避免跨初始化时旧定时器错标
    final snapshotEpoch = _tlEpoch;
    Future.delayed(const Duration(seconds: 5), () {
      if (!_playerDisposed && snapshotEpoch == _tlEpoch) {
        _diagSnapshot('进房+5s');
      }
    });
  }

  /// 本次播放是否**应启用** VSR 滤镜链（P1-1 起：门控放行前链尚未挂，此标志=用户意愿+链状态
  /// 合一，决定 plan 按「开」算自适应倍数、能否动 video-crop；放行写链后即真实已挂）。
  bool _rtxVsrChainApplied = false;

  /// 记录最近一次**已应用**的 VSR 同步签名（裁切值 + 源尺寸 + 链状态），用于去重。
  /// 不能只用裁切值当键：无补边流的裁切值都是空串，切分辨率/切直播间时会误判「未变化」
  /// → 渲染尺寸与显示比例漏更（复核 P0）。
  String? _lastRtxVsrSignature;

  /// 当前已挂上的 VSR 倍数（null = 未挂链），用于判断是否需要重挂滤镜链。
  double? _lastRtxVsrScale;

  /// VSR 起播门控（方案 20261111）：Windows + VSR 开启时**先不自动起播**，
  /// 等源分辨率就绪、按自适应倍数把 vf 挂好之后再 `play()`。
  /// 否则起播后才挂/改 vf 会触发 mpv playback restart → 进房「出画面又重载」。
  bool _vsrDeferPlay = false;
  Timer? _vsrDeferPlayTimer;

  /// 起播门控超时兜底（拿不到源分辨率时不卡死，超时直接起播）。
  /// 复核 P6：慢网拉流可能 >2s，给到 3s。
  static const Duration vsrDeferPlayTimeout = Duration(seconds: 3);

  /// 起播门控的「布局稳定」尾沿：每次同步都往后顺延，静默这么长时间才真的起播
  /// （复核 P1：避免 play() 后布局（全屏/窗口自适应/拖窗）变化又改 vf → 重载）。
  Timer? _vsrDeferPlaySettleTimer;
  DateTime? _vsrDeferPlayArmedAt;

  /// 门控代际：每次武装 +1。
  /// 用于挡掉「已过期 release」：P1-1 起播前单次写链在 play() 前插入了 await（写链
  /// `_applyVsrTarget` / `_preHangFallbackChain`），写链期间若恰逢重武装（换线路/出错重试
  /// 触发 openSourceGated → initializePlayer → _armVsrDeferPlay），过期 release 的 play()
  /// 会落到新源、绕过新门控一次（ISS-283）。故 **play() 前必须复查本代际**（两处比对：
  /// disarm 后、以及所有 await 之后）。
  int _vsrGateEpoch = 0;
  static const Duration vsrDeferPlaySettle = Duration(milliseconds: 500);
  static const Duration vsrDeferPlaySettleMax = Duration(milliseconds: 1200);

  /// 已写/摘 VSR 链次数（观测用：真机日志可看出进房是否只挂一次）。
  int _vsrChainWriteCount = 0;

  /// P1-1 起播前单次写链：门控期内吞中间写，暂存的最新写链目标
  /// （settle 尾沿 / 超时放行时一次消费）。null = 暂无目标（超时路径走预挂兜底 2.0）。
  _VsrTarget? _vsrDeferPlayTarget;

  /// 供宿主（LiveRoomController）在 `player.open` 时读取：本次是否应延迟起播。
  bool get vsrDeferPlayPending => _vsrDeferPlay;

  /// [TL] 时间线：记录 `player.open` 发起节点（宿主在 open 前调用；E 批遗留，P1-1 补）。
  /// 宿主（LiveRoomController）在 `player.open` / `jump` **前一刻**调用：记时间线 + 武装就绪门。
  /// 就绪门武装点放这里（而非 initializePlayer 开头）——既避开前面若干 await 吃掉 6s 预算
  /// （复核 E），又让「换线路/出错重试」（`setPlayer`）同享遮罩/声音门（复核 G）。
  void tlMarkOpen() {
    _tlMark('open 发起');
    _armReadyGate();
  }

  /// 起播门控是否适用（Windows + VSR 开启）。进房 / 换线路 / 出错重试共用同一判据，
  /// 与 initializePlayer 里的 vsrOn 同源（纯函数 vsrShouldDeferPlay）。
  bool get _vsrGateApplicable => vsrShouldDeferPlay(
        isWindows: Platform.isWindows,
        vsrEnabled: AppSettingsController.instance.enableRtxVsr.value,
      );

  /// 换线路 / 出错重试专用：带 VSR 起播门控地换源（阶段4 复核发现的既有缺口）。
  /// 返回 true = 已由门控路径接管（已按 play:false 打开，链挂好后自动起播），调用方不必再 jump。
  ///
  /// 为什么用 open 而不是「jump 后再 pause」：media_kit 的 stream.width/height 带 distinct
  /// 去重，新旧分辨率相同时不会发尺寸事件 → 门控只能等超时 → 切线路白卡几秒；
  /// 而 open() 内部会 stop() 发 null 尺寸，保证即便分辨率相同也能拿到尺寸事件。
  Future<bool> openSourceGated(List<Media> mediaList, {int index = 0}) async {
    if (!_vsrGateApplicable) {
      return false;
    }
    _lastRtxVsrSignature = null;
    // 复核（换线路）：open 内部会 stop()，等价一次「重开」——音量均衡的首帧自愈钩子
    // 只在 initializePlayer 里重置过，换线路/重试不走那条路，这里补一次重置。
    // 否则（RISK-71：open 可能清掉链）换线路后均衡会静默丢失，直到下次重初始化。
    _volumeNormInitialized = false;
    Log.d('[VSR] 换线路/重试走起播门控：open(play:false) index=$index');
    _tlMark('open 发起');
    _armVsrDeferPlay();
    try {
      await player.open(Playlist(mediaList, index: index), play: false);
    } catch (e) {
      // open 失败：门控已武装但没人会 play。dispose 竞态下 jump 同样会抛（入口 disposed → AssertionError），
      // 回退也救不回 → 直接认领（返回 true）避免二次未捕获异常；否则撤门控、交回调用方 jump 兜底。
      Log.d('[VSR] 门控换源失败（disposed=$_playerDisposed）: $e');
      _disarmVsrDeferPlay();
      return _playerDisposed;
    }
    return true;
  }

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

  /// 音量均衡：进程级能力缓存（null=未探测；libmpv 构建固定，探测一次即可）。
  /// 声明在 PlayerMixin：initializePlayer（预挂决策）在 mixin 内，mixin 无 on 约束，
  /// 被引用的状态必须自持（复核 P0-1，CI analyze 报 Undefined name）。
  static bool? afLoudnormSupported;

  /// 音量均衡：本房间是否已应用 af
  bool _volumeNormApplied = false;

  /// 音量均衡：本房间首帧播放的一次性探测是否已执行
  bool _volumeNormInitialized = false;

  /// 音量均衡：抑制窗口内播放器日志是否报出滤镜链失败（静默降级防线）
  bool _volumeNormLogFailure = false;

  /// 音量均衡：日志防线记录是否武装（预挂/热开/探测起即武装，窗末终裁一次后解除；
  /// 与抑制窗解耦——记录只认武装，不依赖 _suppressErrorRetry，真机 P0 ISS-278）
  bool _volumeNormLogArmed = false;

  /// 音量均衡：终裁代际计数器（仅音量均衡自身操作递增；与 _suppressToken 解耦——
  /// VSR 重挂 vf 也递增 _suppressToken，共用会让 VSR 误取消音量均衡待决终裁，glm 复核 P1）
  int _volumeNormToken = 0;

  /// 音量均衡：待办的拨动意愿（未播放 + 能力未知时 worker 不再静默吞，记此待办、复播时消费）
  bool? _pendingVolumeNormIntent;

  /// 起播时间线（[TL]）：每次进房/重开一条，定位「进房等很久」到底卡在哪一段。
  DateTime? _tlT0;
  final Map<String, int> _tlMarks = <String, int>{};
  /// 时间线代际：`initializePlayer` 每次重置自增；延时汇总绑定代际，避免「旧房间的
  /// 延时 dump 提前把新房间的汇总打空」（阶段4 复核发现：切清晰度/重开后必现）。
  int _tlEpoch = 0;

  void _tlReset() {
    _tlT0 = DateTime.now();
    _tlMarks.clear();
    _tlEpoch++;
  }

  void _tlMark(String key) {
    final t0 = _tlT0;
    if (t0 == null || _tlMarks.containsKey(key)) {
      return;
    }
    final ms = DateTime.now().difference(t0).inMilliseconds;
    _tlMarks[key] = ms;
    Log.d('[TL] $key +${ms}ms');
  }

  void _tlDump() {
    final t0 = _tlT0;
    if (t0 == null) {
      return;
    }
    final total = DateTime.now().difference(t0).inMilliseconds;
    final sb = StringBuffer('[TL] 汇总: 总=${total}ms');
    _tlMarks.forEach((k, v) => sb.write('; $k=${v}ms'));
    Log.d(sb.toString());
    _tlT0 = null;
  }

  /// 诊断快照（[DIAG] 快照）：进房后 5s / 拨开关后 2s 各一条，便于直读现场状态。
  Future<void> _diagSnapshot(String when) async {
    try {
      final pp = player.platform;
      var af = '-';
      var crop = '-';
      if (pp is NativePlayer) {
        try {
          af = (await pp.getProperty('af', waitForInitialization: false)).trim();
        } catch (_) {}
        try {
          crop =
              (await pp.getProperty('video-crop', waitForInitialization: false))
                  .trim();
        } catch (_) {}
      }
      final area = _playerAreaPhysicalSize();
      Log.d('[DIAG] 快照($when): vsr=${AppSettingsController.instance.enableRtxVsr.value}'
          ' scale=${_lastRtxVsrScale?.toStringAsFixed(2) ?? "-"} crop="$crop"'
          ' 源=${player.state.width}x${player.state.height}'
          ' 播放区=${area?.$1 ?? "-"}x${area?.$2 ?? "-"}'
          ' 缓存=${AppSettingsController.instance.videoDoubleBuffering.value ? "on" : "off"}'
          ' playing=${player.state.playing} af="$af"');
    } catch (e) {
      Log.logPrint(e);
    }
  }

  /// 就绪门（方案 §三 B1/B2）：进房后在「首帧真正就绪」前盖遮罩。
  /// ready ＝ 收到 `playback restart complete`（media_kit 补丁转发的等价日志行）∧ 无在途管线写入。
  /// 兜底 6s 超时（脏流 GOP 上限）→ 强制解除 + 提示，不静默。
  bool _readyPending = false;
  Timer? _readyTimeoutTimer;
  static const Duration readyGateTimeout = Duration(seconds: 6);

  /// 就绪门前置条件（阶段4 复核 B/C：缺「play 已发」→ 热拨 VSR/seek 会被误判成进房就绪）。
  bool _playIssued = false; // 本次门控内 play() 是否已发出
  bool _readyRestartSeen = false; // 本次门控内「play 已发之后」是否已见 restart 完成

  /// 在途管线写入计数（音量均衡队列 + VSR 裁切队列）。
  /// 注：**放行点写链不经队列**（在 play() 之前 await 完成，restart 必在其后），故不计入也不影响判定。
  int _pipelineBusy = 0;

  /// af/vf 写序互斥（P1-3）：两条队列保持**分离**（C3 硬约束：不合并——避免长 af 建链堆住
  /// VSR 的 vf 写入、破坏「VSR 点即生效」），但**真正写 mpv 的瞬间**互斥，避免「vf 重建中写 af」
  /// 交错。只在**叶子写函数**取锁（三个叶子互不调用 → 无嵌套、无死锁；锁内无长耗时环节）。
  Future<void> _writeMutex = Future<void>.value();
  Future<T> _withWriteMutex<T>(Future<T> Function() body) {
    final prev = _writeMutex;
    final gate = Completer<void>();
    _writeMutex = gate.future;
    return prev.then((_) => body()).whenComplete(gate.complete);
  }

  void _armReadyGate() {
    _readyPending = true;
    _playIssued = false;
    _readyRestartSeen = false;
    showReadyMaskRx.value = true;
    // 声音门（§8.2【硬】/§三 B1）：就绪前静音（用 mpv `mute` 属性，不动用户音量值），
    // 与遮罩淡出同一刻解除。VSR 关时 `open` 即 play:true，此门是唯一保证「就绪前不出声」的机制。
    _setGateMute(true);
    _readyTimeoutTimer?.cancel();
    _readyTimeoutTimer = Timer(readyGateTimeout, () {
      if (_playerDisposed) {
        return;
      }
      // 只在「确实开过流」时提示，避免未开播房间误弹
      final hadSource = (player.state.width ?? 0) > 0 ||
          player.state.buffering ||
          player.state.playing;
      _finishReadyGate('timeout');
      if (hadSource) {
        SmartDialog.showToast('网络较慢，已直接播放');
      }
    });
  }

  void _finishReadyGate(String reason) {
    if (!_readyPending) {
      return;
    }
    _readyPending = false;
    _readyTimeoutTimer?.cancel();
    _readyTimeoutTimer = null;
    showReadyMaskRx.value = false;
    _setGateMute(false); // 与遮罩淡出同一刻解除声音门
    _tlMark('就绪($reason)');
    Log.d('[ready] 就绪门解除（$reason）');
  }

  /// 任一前置条件变化后调用（restart 到达 / play 发出 / 写链完成）——
  /// 避开「restart 到时 busy>0 就永不复检」（复核 C：只能等 6s 超时且误报网络慢）。
  void _maybeFinishReadyGate() {
    if (readyGateCanFinish(
      pending: _readyPending,
      playIssued: _playIssued,
      restartSeen: _readyRestartSeen,
      pipelineBusy: _pipelineBusy,
    )) {
      _finishReadyGate('restart');
    }
  }

  /// 门控静音开关（用 mpv `mute` 属性，不动音量值；非原生平台空操作）。
  Future<void> _setGateMute(bool muted) async {
    try {
      final pp = player.platform;
      if (pp is NativePlayer) {
        await pp.setProperty('mute', muted ? 'yes' : 'no');
      }
    } catch (e) {
      Log.logPrint(e);
    }
  }

  /// 音量均衡：操作串行队列（探测/应用/移除按发起顺序执行，避免并发交错导致 af 与状态标记不一致）。
  /// 用 [SerialTaskQueue]：**队列任务内再次入队会内联执行**，杜绝嵌套自死锁（P0，ISS-281）。
  final SerialTaskQueue _volumeNormQueue = SerialTaskQueue();

  /// 音量均衡：入队执行一次 af 操作（异常在队列内消化，避免 fire-and-forget 产生未处理异步异常）。
  /// ⚠️ 队列任务体内**不要**再调 [_syncVolumeNorm]（它＝入队）；任务内用 [_syncVolumeNormLocked]。
  Future<void> _enqueueVolumeNorm(Future<void> Function() task) {
    _pipelineBusy++;
    return _volumeNormQueue.run(() async {
      try {
        await task();
      } finally {
        _pipelineBusy--;
        _maybeFinishReadyGate();
      }
    }, onError: (e, _) => Log.logPrint(e));
  }

  /// 音量均衡：起流前预挂链（由 `initializePlayer` 在 `player.open` 之前调用，经串行队列执行）。
  ///
  /// v2（优雅版，ISS-274）：**探测式预挂**——能力未知（null）也挂（volumeNormShouldPreApply
  /// 语义：非已知不支持即预挂），set 后回读校验链已挂上（applied 标记）。
  /// 复核（v2 第 2 轮，ISS-275）：**不在此刻持久化能力**——起流前无音频，解析期通过≠运行时
  /// 建链成功；能力判定推迟到首帧（播放中）：null 能力走既有探测（_probeVolumeNormCapability，
  /// 自带开窗+日志防线+持久化），已知支持走首帧复查（_verifyVolumeNormFirstFrame）。
  /// 由此「运行时 init 失败」不会被 persist(true) 固化、「回读瞬时失败」也不会被
  /// persist(false) 永久误杀（qwen P1/P2 修复）。
  /// 失败不阻塞起流：异常路径仅记录（applied=false），首帧按能力状态探测/复查兜底。
  /// 复核 P1-1：预挂**不**开错误抑制窗——它发生在起流建连期，2s 抑制窗会吞掉真实
  /// 建连错误（死链/鉴权失败 → 黑屏不重拉流）。af 写入失败本不产生 stream.error
  /// （PR #195 的抑制窗针对播放中重建链路场景），无需窗口。
  Future<void> _preApplyVolumeNorm() async {
    final pp = player.platform;
    if (pp is! NativePlayer) {
      return;
    }
    // 复核 P1-5：队列内二次校验——排到我们之前可能已有热切换任务改变了开关或状态。
    if (_volumeNormApplied ||
        !volumeNormShouldPreApply(
          userOn: AppSettingsController.instance.volumeNorm.value,
          supported: afLoudnormSupported,
        )) {
      return;
    }
    // 复核（真机 P0，ISS-278）：武装日志防线记录——起流后 mpv 建 af 图若失败，
    // 失败日志在播放事件之后异步到达；qwen 排查：media_kit play() 返回时即发
    // playing（早于图构建），只有「预挂起持续记录、窗末终裁消费」才抓得到。
    _volumeNormLogFailure = false;
    _volumeNormLogArmed = true;
    try {
      // 复核 P2-7：起流前 set 无需等待播放器/视频控制器初始化（mpv 在初始化时应用
      // 该选项）；waitForInitialization:false 避免进房起流被 setProperty 阻塞。
      await pp.setProperty('af', volumeNormFilter, waitForInitialization: false);
      // 复核 P0-3：预挂后立即回读校验——media_kit 的 setProperty 忽略 mpv 返回码，
      // 「滤镜不存在/参数非法」会静默失败；不回读会把未生效的链标记成已挂。
      final readback = await pp.getProperty('af', waitForInitialization: false);
      _volumeNormApplied = volumeNormSupportedFromReadback(readback);
      if (!_volumeNormApplied) {
        // 链未挂上（解析期拒绝）：清链保证与 mpv 状态一致；**不持久化能力**——
        // 能力判定交给首帧（null→探测 / 已知→复查），避免瞬时失败被永久 persist false。
        await pp.setProperty('af', '', waitForInitialization: false);
        Log.w('音量均衡：预挂回读未确认（af="$readback"），能力判定推迟到首帧');
      }
    } catch (e) {
      Log.logPrint(e);
      _volumeNormApplied = false;
    }
  }

  /// 音量均衡：首帧复查（播放中，仅对「已知支持 + 已预挂」的房间执行一次）。
  ///
  /// 复核（v2 第 2 轮，ISS-275）：预挂成功路径上日志防线无消费点、首帧 _applyVolumeNorm
  /// 因 applied==true 短路 → 「解析期通过但运行时建链失败」无人兜底（P1）。
  /// 复核（真机 P0，ISS-278）：media_kit 的 playing 事件在 play() 返回时即发出
  /// （real.dart 立即 add(true)），**早于** mpv 建音频滤镜图 → 立即回读/查标志是
  /// 「系统性过早」，v1.08.62 真机即此形态（失败日志到达时复查已结束）。
  /// 因此只开 2s 抑制窗 + 预约窗末终裁（_scheduleVolumeNormAdjudication）：终裁时
  /// 失败日志必然已到（播放开始后数百 ms 内），回读+日志双查才有效。
  Future<void> _verifyVolumeNormFirstFrame() async {
    if (player.platform is! NativePlayer || !_volumeNormApplied) {
      return;
    }
    final token = ++_suppressToken;
    _suppressErrorRetry = true;
    // 不复位失败标志：预挂已武装，此处只消费（kimi 排查 ISS-278）
    _scheduleVolumeNormAdjudication(
      vnToken: ++_volumeNormToken,
      suppressToken: token,
      source: '首帧复查',
    );
  }

  /// 音量均衡：抑制窗末终裁一次（消费日志防线标志 + 回读），失败则清链并禁用。
  ///
  /// 终裁语义（真机 P0，ISS-278）：预挂/热开/探测都只武装记录（_volumeNormLogArmed），
  /// 真正判成败放在播放开始后的窗末——此时 mpv 已尝试建 af 图，失败日志（lavfi
  /// configure 失败 / Disabling filter ... because it has failed）必然已入记录。
  /// 失败处理与「核心不支持」同语义：清链 + applied=false + persist(false) + 置灰 +
  /// toast（kimi 排查 ISS-278：单房失败自愈会在系统性故障下变成每房 toast 循环，
  /// 统一持久化禁用、新版本/重建后自然重探）。
  void _scheduleVolumeNormAdjudication({
    required int vnToken,
    required int suppressToken,
    required String source,
  }) {
    final pp = player.platform;
    if (pp is! NativePlayer) {
      return;
    }
    // Zone.root.bindCallback：该回调与「当前队列任务」已无关，必须转义出任务 Zone，
    // 否则体内的 [_enqueueVolumeNorm] 会被误判为重入而内联（丢失串行化）
    Future.delayed(const Duration(milliseconds: 2000), Zone.root.bindCallback(() async {
      if (vnToken != _volumeNormToken || _playerDisposed) {
        return; // 已被更新的音量均衡操作取代或资源已释放（新操作的释放逻辑自会收尾）
      }
      if (!_volumeNormLogArmed) {
        _scheduleSuppressRelease(suppressToken);
        return;
      }
      _volumeNormLogArmed = false; // 终裁一次后解除武装
      // 阶段1（L3）修正：失败判定只信日志标志——回读失链不判失败。原因：
      // ①死链自动重拉时 open 会清空 af 链（RISK-71），若把回读失链当失败会把
      // 能力永久 persist false + 置灰（一次死链误杀开关）；②运行态图构建失败时
      // 属性层链串仍在（回读必含），日志标志才是可靠信号。回读仅作诊断记录。
      var failed = _volumeNormLogFailure;
      String? readbackNote;
      try {
        final readback = await pp.getProperty('af', waitForInitialization: false);
        readbackNote = readback;
      } catch (e) {
        Log.logPrint(e);
      }
      if (failed) {
        // glm 复核 P3：清链/持久化入队执行（终裁不在队列内，体内 await 期间新热开
        // 可能落地，被旧终裁误清并误 persist false）；入队后再查一次代际与 disposed。
        await _enqueueVolumeNorm(() async {
          if (vnToken != _volumeNormToken || _playerDisposed) {
            return; // 排队期间被新操作取代：放弃清理
          }
          _volumeNormApplied = false;
          try {
            await pp.setProperty('af', '', waitForInitialization: false);
          } catch (_) {}
          PlayerMixin.afLoudnormSupported = false;
          _persistCapability(false);
          AppSettingsController.instance.setVolumeNormSupported(false);
          Log.w('音量均衡：$source 终裁未通过（logFailure=$_volumeNormLogFailure af="$readbackNote"）→ 已清链并禁用开关');
          // glm 复核 P3：toast 前复查 disposed（终裁体内 await 期间可能已退房）
          if (!_playerDisposed) {
            SmartDialog.showToast("当前播放核心不支持音量均衡，开关已禁用");
          }
        });
      } else if (readbackNote != null && !volumeNormSupportedFromReadback(readbackNote)) {
        // 回读失链（如 open 复位选项级链）：仅诊断记录，不判失败（下房预挂自愈）
        Log.d('音量均衡：$source 终裁回读失链（af="$readbackNote"）——疑似 open 复位，下房自愈');
      }
      _scheduleSuppressRelease(suppressToken);
    }));
  }

  /// 音量均衡：持久化能力探测结果（带 App 版本前缀，版本变化即失效重探）。
  /// 声明在 PlayerMixin：探测式预挂（_preApplyVolumeNorm，v2 ISS-274）也写能力，
  /// mixin 无 on 约束必须自持被引用成员（复核 P0-1）。
  void _persistCapability(bool supported) {
    LocalStorageService.instance.setValue(
      LocalStorageService.kVolumeNormSupported,
      "${Utils.packageInfo.version}:$supported",
    );
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
  Future<void> _syncRtxVsrCrop({String trigger = 'sync'}) async {
    // 注：_playerDisposed 在 PlayerMixin 内可直接引用，但此处不依赖它——
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
    _tlMark('源分辨率 ${rawW}x$rawH');
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
    // 起播门控（P1-1 起播前单次写链）：门控期内**吞中间写**——不立即写链，只把最新目标
    // 记入 _vsrDeferPlayTarget（后续尺寸/布局同步会覆盖成更新目标），settle 尾沿 / 超时
    // 放行时**一次写入终值**（vf 3 写→1 写，N4/N5）。
    // 例外：链路已与目标一致（vfAction 'none' + 裁切回读一致）→ 立即放行，0 等待（e8e3dac）。
    // 判定用**回读**（留存签名会被 open 清链弄陈旧）：vf 用 rtxVsrVfAction 判
    // （依赖跨 open 存活的 _lastRtxVsrScale），戴切回读比对（戴切/显示比例/画布同源）。
    if (_vsrDeferPlay) {
      final (vfAction0, _) = rtxVsrVfAction(
          enable: enable, scale: s, currentScale: _lastRtxVsrScale);
      if (vfAction0 == 'none' && await _rtxCropMatches(desired)) {
        Log.d('[VSR] 门控: 链路无需改动 → 立即放行（chain-unchanged）');
        _releaseVsrDeferPlay('chain-unchanged');
        return;
      }
      _vsrDeferPlayTarget = _VsrTarget(
        signature: signature,
        trigger: trigger,
        enable: enable,
        scale: s,
        crop: desired,
        aspect: aspectValue,
        renderSize: renderSize,
        rawW: rawW,
        rawH: rawH,
        area: area,
      );
      Log.d('[VSR] 门控: 暂存写链目标(触发=$trigger) scale=${s?.toStringAsFixed(2) ?? '-'}'
          ' crop="$desired" → settle 尾沿单次写入');
      _scheduleVsrDeferPlayRelease();
      return;
    }
    if (signature == _lastRtxVsrSignature) return;
    _enqueueCropWrite(() async {
      // 队列内再查一次：并发同值时只写第一笔，避免重复设置触发滤镜链重建。
      if (signature == _lastRtxVsrSignature) return;
      await _applyVsrTarget(_VsrTarget(
        signature: signature,
        trigger: trigger,
        enable: enable,
        scale: s,
        crop: desired,
        aspect: aspectValue,
        renderSize: renderSize,
        rawW: rawW,
        rawH: rawH,
        area: area,
      ));
    });
  }

  /// 应用一次 VSR 链写入（vf / video-crop / video-aspect-override / setSize + 回读校验）。
  /// 常规同步与起播门控放行点共用（P1-1 单次写链）。
  /// 共用写链逻辑（P1-3 写序互斥）：入写锁后执行 `_applyVsrTargetUnlocked`。
  Future<void> _applyVsrTarget(_VsrTarget t) =>
      _withWriteMutex(() => _applyVsrTargetUnlocked(t));

  Future<void> _applyVsrTargetUnlocked(_VsrTarget t) async {
    final pp = player.platform;
    if (pp is! NativePlayer) return;
    // 队列内再查一次（并发同值 / 放行点防重）：只写第一笔，避免重复设置触发滤镜链重建。
    if (t.signature == _lastRtxVsrSignature) return;
    // 打点放内层去重之后（定向复验）：width/height 是同一事件成对下发，height 侧那次
    // 调用时外层签名尚未回填（回填在任务末尾）→ 打在外层仍会双打且归因失真。
    Log.d('[VSR] 布局同步(触发=${t.trigger}): 源=${t.rawW}x${t.rawH}'
        ' 播放区=${t.area?.$1 ?? "-"}x${t.area?.$2 ?? "-"}'
        ' → scale=${t.scale?.toStringAsFixed(2) ?? "-"} crop="${t.crop}" 链=${t.enable}');
    final (vfAction, vfValue) = rtxVsrVfAction(
        enable: t.enable, scale: t.scale, currentScale: _lastRtxVsrScale);
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
          _lastRtxVsrScale = t.scale;
          Log.d('[VSR] 写入滤镜链 #${++_vsrChainWriteCount}'
              ' scale=${t.scale?.toStringAsFixed(2)}');
        } else {
          await pp.setProperty('vf', '');
          _lastRtxVsrScale = null;
          Log.d('[VSR] 摘除滤镜链 #${++_vsrChainWriteCount}');
        }
      } finally {
        _scheduleSuppressRelease(token);
      }
    }
    await pp.setProperty('video-crop', t.crop);
    await pp.setProperty('video-aspect-override', t.aspect.toStringAsFixed(6));
    // record 字段不参与 field promotion，先落局部变量再判空（analyze 门禁）。
    final renderSize = t.renderSize;
    if (renderSize != null) {
      await videoController.setSize(width: renderSize.$1, height: renderSize.$2);
    } else {
      await videoController.setSize();
    }
    // 写入成功后才记缓存（复核 P3-3）：异常（dispose 竞态）时保持旧值，下次同步会重试。
    // 复核 P4：若写期间源尺寸已变（open/切流把签名作废后又来新尺寸），别用旧签名回填
    // ——否则新尺寸与旧签名相同会被短路 → 链不纠正、门控只能等超时。
    if (player.state.width != t.rawW || player.state.height != t.rawH) {
      Log.d('[VSR] 尺寸已变（${player.state.width}x${player.state.height}'
          ' != ${t.rawW}x${t.rawH}）—— 不回填签名，等下个尺寸事件重算');
      return;
    }
    _lastRtxVsrSignature = t.signature;
    _tlMark('链就绪');
    if (t.crop.isEmpty) return;
    // 回读校验（参考音量均衡 af 的做法）：media_kit 的 setProperty 不返回错误，
    // 属性缺失/语法级拒绝时会静默失败 → 回读一次让失败可见（RISK-58）。
    // 注意：回读只能证明“属性被接受”，不能证明 VO 逐帧应用成功（越界值由 mpv
    // 在应用阶段忽略并打印日志）——成功日志措辞按此收敛为“已写入”。
    final readback = (await pp.getProperty('video-crop')).trim();
    if (readback.replaceAll(' ', '') == t.crop) {
      Log.d(
        '[VSR] 已写入底部补边裁切 video-crop=${t.crop}'
        ' scale=${t.scale?.toStringAsFixed(2)}'
        ' aspect=${t.aspect.toStringAsFixed(6)}'
        ' renderSize=${t.renderSize?.$1}x${t.renderSize?.$2}'
        '（源 ${player.state.width}x${player.state.height}）',
      );
    } else {
      Log.w(
        '[VSR] video-crop 未生效：期望 ${t.crop}，回读 "$readback"'
        '（源 ${player.state.width}x${player.state.height}）—— 可能 libmpv 不支持该属性',
      );
    }
  }

  /// 回读比对：当前已挂的 `video-crop` 是否与目标一致（供「链路 noop 立即放行」判定）。
  /// 只读、免留存（阶段4 复盘：留存签名会被 open 清链弄陈旧）；读失败按「不一致」处理（保守）。
  Future<bool> _rtxCropMatches(String desired) async {
    final pp = player.platform;
    if (pp is! NativePlayer) return false;
    try {
      final readback =
          (await pp.getProperty('video-crop', waitForInitialization: false)).trim();
      return readback.replaceAll(' ', '') == desired.replaceAll(' ', '');
    } catch (e) {
      Log.logPrint(e);
      return false;
    }
  }

  /// 串行执行一次 video-crop 写入（参考 _enqueueVolumeNorm 的既有惯例）。
  Future<void> _enqueueCropWrite(Future<void> Function() task) {
    _pipelineBusy++;
    final next = _cropWriteQueue.then((_) async {
      try {
        await task();
      } catch (e) {
        Log.d('[VSR] 设置 video-crop 失败: $e');
      } finally {
        _pipelineBusy--;
        _maybeFinishReadyGate();
      }
    });
    _cropWriteQueue = next;
    return next;
  }

  /// 防抖入口：播放区尺寸变化（窗口缩放/面板拖动/进退全屏）等场景调用。
  void scheduleRtxVsrSync() {
    _vsrSyncDebounce?.cancel();
    _vsrSyncDebounce = Timer(const Duration(milliseconds: 250), () {
      _syncRtxVsrCrop(trigger: 'layout');
    });
  }

  /// 武装「起播门控」（Windows + VSR 开启时，由 initializePlayer 末尾调用）。
  void _armVsrDeferPlay() {
    _vsrDeferPlayTimer?.cancel();
    _vsrDeferPlaySettleTimer?.cancel();
    _vsrDeferPlaySettleTimer = null;
    _vsrGateEpoch++;
    _vsrDeferPlayTarget = null;
    _vsrDeferPlayArmedAt = DateTime.now();
    _vsrDeferPlay = true;
    Log.d('[VSR] 门控: 武装 timeout=${vsrDeferPlayTimeout.inMilliseconds}ms');
    _vsrDeferPlayTimer = Timer(vsrDeferPlayTimeout, () {
      // 兜底：拿不到源分辨率（异常流）时不卡住，直接起播（此时可能仍有一次重启，属降级）。
      _releaseVsrDeferPlay('timeout');
    });
  }

  /// 安排「布局稳定后放开起播」：每次已知尺寸的同步都往后顺延，直到静默
  /// [vsrDeferPlaySettle]；但从武装起超过 [vsrDeferPlaySettleMax] 就硬放开（复核 P1/P5）。
  void _scheduleVsrDeferPlayRelease() {
    if (!_vsrDeferPlay) {
      return;
    }
    final armedAt = _vsrDeferPlayArmedAt;
    if (armedAt != null &&
        DateTime.now().difference(armedAt) >= vsrDeferPlaySettleMax) {
      _releaseVsrDeferPlay('settle-max');
      return;
    }
    _vsrDeferPlaySettleTimer?.cancel();
    _vsrDeferPlaySettleTimer = Timer(vsrDeferPlaySettle, () {
      _releaseVsrDeferPlay('settled');
    });
  }

  /// 取消起播门控（未武装时为空操作）。
  void _disarmVsrDeferPlay() {
    _vsrDeferPlayTimer?.cancel();
    _vsrDeferPlayTimer = null;
    _vsrDeferPlaySettleTimer?.cancel();
    _vsrDeferPlaySettleTimer = null;
    _vsrDeferPlayArmedAt = null;
    _vsrDeferPlayTarget = null;
    _vsrDeferPlay = false;
  }

  /// 放开起播门控：先把门控期暂存的写链目标**一次写入**（起播前单次写链；预挂只在超时路径
  /// 兜底），再恢复播放（幂等；未武装则不做）。
  Future<void> _releaseVsrDeferPlay(String reason) async {
    if (!_vsrDeferPlay) {
      return;
    }
    final epoch = _vsrGateEpoch;
    final armedAt = _vsrDeferPlayArmedAt;
    // 先取出暂存目标（_disarmVsrDeferPlay 会清空它），放行点单次写链。
    final target = _vsrDeferPlayTarget;
    _disarmVsrDeferPlay();
    if (_playerDisposed) {
      return;
    }
    // 复核 P3：门控武装期间错误抑制窗必然与「首次起播」重合，窗口内到达的真错误
    // （403/超时/流下线）会被直接 return 掉、不重试也不提示。起播这一刻链重建写操作
    // 早已完成，故解除抑制，让真错误走正常 mediaError 路径。
    _suppressErrorRetry = false;
    // 守卫①（await 之前）：挡掉「已被 disarm、又被新换源取代」的过期 release。
    if (epoch != _vsrGateEpoch) {
      Log.d('[VSR] 起播门控 release 作废（已有新换源）: $reason');
      return;
    }
    if (target != null) {
      // 起播前单次写链（P1-1）：门控期吞掉的中间写在放行点一次性写入终值。
      Log.d('[VSR] 门控: 放行点单次写链(原因=$reason) scale=${target.scale?.toStringAsFixed(2) ?? '-'}'
          ' crop="${target.crop}" 链=${target.enable}');
      try {
        await _applyVsrTarget(target);
      } catch (e) {
        // 放行点是 fire-and-forget（定时器/宿主 unawaited），不 catch 会成未处理异步异常；
        // 写链失败不阻塞起播（降级为不带 VSR 直接播）。
        Log.d('[VSR] 门控放行点写链失败: $e');
      }
    } else if (reason == 'timeout') {
      // 预挂只在超时路径（P1-1）：拿不到源分辨率 → 预挂 2.0 兜底链再起播（降级）。
      try {
        await _preHangFallbackChain();
      } catch (e) {
        Log.d('[VSR] 门控超时预挂失败: $e');
      }
    } else if (reason == 'vsr-off' &&
        _lastRtxVsrScale != null &&
        !_rtxVsrChainApplied) {
      // 门控期热关 VSR 且从未收到尺寸事件（sync 早退、未写摘链目标）——上一路流遗留的链
      // 仍挂在 mpv 里，这里兜底摘掉，避免「关 VSR 后画面仍被放大/绿条复现」（P0 级残留）。
      try {
        await _withWriteMutex(() async {
          final pp = player.platform;
          if (pp is NativePlayer) {
            await pp.setProperty('vf', '');
            _lastRtxVsrScale = null;
            Log.d('[VSR] 门控 vsr-off 兜底摘链 #${++_vsrChainWriteCount}（无尺寸事件，sync 未写）');
          }
        });
      } catch (e) {
        Log.d('[VSR] 门控 vsr-off 兜底摘链失败: $e');
      }
    }
    // 守卫②（所有 await 之后，ISS-283 收口）：上面写链/摘链均为 await，期间可能被重武装取代。
    if (_playerDisposed || epoch != _vsrGateEpoch) {
      Log.d('[VSR] 门控 release 作废（写链期间已被新换源取代）: $reason');
      return;
    }
    _tlMark('play()');
    Log.d('[VSR] 门控放开（$reason）等待=${armedAt == null ? "?" : "${DateTime.now().difference(armedAt).inMilliseconds}ms"} → play()');
    try {
      await player.play();
    } catch (e) {
      Log.d('[VSR] 起播门控 play() 失败: $e');
    }
  }

  /// 门控超时兜底（P1-1「预挂只在超时路径」）：拿不到源分辨率时预挂 2.0 兜底链，
  /// 保证开了 VSR 就有放大效果（此时尺寸未知、无法自适应，可能仍有一次重载，属降级）。
  /// 若上一路流遗留的链仍在（_lastRtxVsrScale 非空）则不动它，避免无谓改倍数。
  Future<void> _preHangFallbackChain() =>
      _withWriteMutex(_preHangFallbackChainUnlocked);

  Future<void> _preHangFallbackChainUnlocked() async {
    if (!_rtxVsrChainApplied || _lastRtxVsrScale != null) return;
    final pp = player.platform;
    if (pp is! NativePlayer) return;
    final token = ++_suppressToken;
    _suppressErrorRetry = true;
    try {
      await pp.setProperty('hwdec', 'd3d11va');
      await pp.setProperty('vf', rtxVsrVfChain(rtxVsrScale));
      _lastRtxVsrScale = rtxVsrScale;
      Log.d('[VSR] 预挂兜底链 #${++_vsrChainWriteCount}'
          ' scale=${rtxVsrScale.toStringAsFixed(2)}（门控超时降级）');
    } finally {
      _scheduleSuppressRelease(token);
    }
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
            // P1-3（启动编排）：Windows + 硬解开启 + VSR 开启 → create 期就把硬解定为 `d3d11va`。
            // 否则起流后 initializePlayer 再写一次 hwdec → 软解→硬解 Reinit → 首帧要等下一个 IDR
            // （N6 的主要代价）；create 期给定后首帧直接走硬解。其余情况传 null，走 media_kit 默认 'auto'。
            hwdec: (AppSettingsController.instance.hardwareDecode.value &&
                    Platform.isWindows &&
                    AppSettingsController.instance.enableRtxVsr.value)
                ? 'd3d11va'
                : null,
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
    unawaited(
      DanmakuEmoticonRenderer.apply(
        controller: controller,
        content: item,
        emoticons: extra as List<LiveMessageEmoticon>,
      ),
    );
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
      'fitPanelWidthToVideo[try$attempt] video=${w}x$h player=${playerSize.width}x${playerSize.height} contentW=$contentWidth -> panel $current -> $target',
    );
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
    PlayerMixin.afLoudnormSupported ??= _readPersistedCapability();
    if (PlayerMixin.afLoudnormSupported != null) {
      AppSettingsController.instance.setVolumeNormSupported(PlayerMixin.afLoudnormSupported);
    }
    //音量均衡热切换：设置页/房内开关拨动即时生效
    //PR #195 教训：句柄化管理 + onClose 释放 + 回调内 disposed 短路
    _volumeNormWorker = ever(AppSettingsController.instance.volumeNorm, (bool on) {
      Log.d('[DIAG] 操作: 音量均衡 → $on'
          '（disposed=$_playerDisposed applied=$_volumeNormApplied supported=${PlayerMixin.afLoudnormSupported} playing=${player.state.playing}）');
      if (_playerDisposed) {
        return;
      }
      Future.delayed(const Duration(seconds: 2), () {
        if (!_playerDisposed) _diagSnapshot('拨均衡后+2s');
      });
      // 复核 P1-6：已挂链时无条件入队同步——关闭不需要能力探测，
      // 不能因「未播放 + 能力未知」被吞（否则开关拨关、链却仍在均衡）。
      if (_volumeNormApplied) {
        _syncVolumeNorm();
        return;
      }
      // 未播放且能力未知：不在此刻探测（空闲探测不可靠，可能假成功），留到首帧钩子统一处理。
      // 复核 N2：**不能静默吞**——记待办，复播时消费，避免「暂停中拨开关」永远失效
      // （首帧钩子是一次的，不会为复播重跑）。
      if (PlayerMixin.afLoudnormSupported == null && !player.state.playing) {
        _pendingVolumeNormIntent = on;
        Log.d('[VN] toggle($on) deferred: not playing');
        return;
      }
      _syncVolumeNorm();
    });
    // VSR：直播间接开关即生效（复用音量均衡的热切换范式：worker + 串行队列 + 错误抑制）
    _rtxVsrWorker = ever(AppSettingsController.instance.enableRtxVsr, (bool on) {
      if (_playerDisposed || !Platform.isWindows) {
        return;
      }
      Log.d('[DIAG] 操作: VSR → $on');
      _applyRtxVsrSetting();
      Future.delayed(const Duration(seconds: 2), () {
        if (!_playerDisposed) _diagSnapshot('拨VSR后+2s');
      });
    });
    super.onInit();
  }

  /// 音量均衡：热切换监听器句柄（onClose 必须释放；裸 ever() 退房后断言，PR #195 教训）
  Worker? _volumeNormWorker;

  /// VSR：开关热切换监听器句柄（onClose 必须释放，PR #195 教训）
  Worker? _rtxVsrWorker;

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
        // 就绪门前置：play 已发出（media_kit 在 play() 返回时即发 playing）
        _playIssued = true;
        _maybeFinishReadyGate();
        _tlMark('首帧/playing');
        final tlEpoch = _tlEpoch;
        Future.delayed(const Duration(milliseconds: 2500), () {
          if (!_playerDisposed && tlEpoch == _tlEpoch) {
            _tlDump();
            _diagSnapshot('起播后');
          }
        });
        // 进入直播间按分辨率自适应窗口宽度（播放开始时布局已就绪，重试至生效）
        if (AppSettingsController.instance.autoFitWindowWidth.value &&
            !AppSettingsController.instance.autoFullScreen.value) {
          fitPanelWidthToVideo();
        }
        // 音量均衡：首帧播放后一次性同步（能力未知时顺带探测，必须播放中做）
        if (!_volumeNormInitialized) {
          _volumeNormInitialized = true;
          _pendingVolumeNormIntent = null; // 首帧已统一同步（读的是当前意愿），清待办
          Log.d('[VN] 首帧钩子: 触发（本房间首次 playing）');
          // 复核（真机 P0，ISS-278）：首帧的两条路径统一入队，与热切换/探测严格串行；
          // 探测与复查的成败判定都在抑制窗末终裁（playing 事件早于 af 图构建，立即读必漏）。
          _enqueueVolumeNorm(() async {
            // glm 复核 P2：切清晰度重开（initializePlayer+open 复用同一控制器）时 open
            // 可能清空选项级 af 链（RISK-71）——applied 残留 true 会让预挂短路、此处
            // 复查也短路 → 本房静默失去均衡。先回读自愈：失链则重置 applied，让 sync
            // 走 apply(true) 重挂（重新武装+终裁，运行时失败同样会被抓住）。
            if (_volumeNormApplied) {
              final pp = player.platform;
              if (pp is NativePlayer) {
                try {
                  final rb = await pp.getProperty('af', waitForInitialization: false);
                  if (!volumeNormSupportedFromReadback(rb)) {
                    Log.d('音量均衡：首帧回读失链（af="$rb"）——open 已清链，重挂中');
                    _volumeNormApplied = false;
                  }
                } catch (e) {
                  Log.logPrint(e);
                }
              }
            }
            // ⚠️ 此处已在队列任务内：必须调**无队版**，否则会嵌套入队 → 自死锁（ISS-281）
            await _syncVolumeNormLocked();
            if (_volumeNormApplied &&
                PlayerMixin.afLoudnormSupported == true &&
                AppSettingsController.instance.volumeNorm.value) {
              await _verifyVolumeNormFirstFrame();
            }
          });
        } else if (_pendingVolumeNormIntent != null) {
          // N2：暂停期被推迟的拨动 → 复播时消费
          _pendingVolumeNormIntent = null;
          Log.d('[VN] 待办消费: 复播 → 同步');
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
      // 起播时间线补充节点（需日志级别到 debug——真机复测时会开着日志开关）
      if (event.text.contains('Using hardware decoding')) _tlMark('硬解生效');
      if (event.text.contains('playback restart complete')) {
        _tlMark('restart完成');
        // 就绪门：只认 **play 已发出之后** 的 restart（起播前链写入/seek 触发的 restart 不算数），
        // 再按完整条件判定（定向复验：原 _readyEpoch 是死字段，改用 _playIssued 作门槛）。
        if (_playIssued) {
          _readyRestartSeen = true;
          _maybeFinishReadyGate();
        }
      }
      // 音量均衡静默降级防线（复核建议）：武装期内命中滤镜错误关键字即标记失败，
      // 由首帧/探测/热开的窗末终裁消费（真机 P0 ISS-278：记录与抑制窗解耦——失败日志
      // 可能早于/晚于抑制窗，只有「预挂起持续记录、窗末终裁」才不漏）。
      // 复核 P0-2：event 是 PlayerLog（prefix/level/text），需拼成行文本再判关键字。
      // 复核 P0-4：关键字是通用措辞，必须限定音频作用域（volumeNormLogIndicatesFailure
      // 内部要求出现 dynaudnorm/loudnorm 或行首裸前缀 `af `——media_kit 的 PlayerLog.prefix
      // 无方括号，阶段4 第3轮 P3 修正），否则 VSR 重挂 vf（d3d11vpp）的报错
      // 会落进共用抑制窗 → 音量均衡被误判不支持并持久化禁用、开关置灰。
      if (_volumeNormLogArmed && volumeNormLogIndicatesFailure('${event.prefix} ${event.text}')) {
        Log.d("音量均衡：日志命中滤镜错误关键字 → 判定链未挂上：${event.prefix} ${event.text}");
        _volumeNormLogFailure = true;
      }
    });
    _widthSubscription = player.stream.width.listen((event) {
      Log.d('width:$event  W:${(player.state.width)}  H:${(player.state.height)}');
      // 源尺寸被重置（open/stop 后 media_kit 会发 null）→ 作废去重签名：
      // 否则新流尺寸与上次完全相同时签名相同→短路→链不纠正、起播门控只靠超时放开（复核发现）。
      if (event == null) {
        _lastRtxVsrSignature = null;
      }
      _tlMark('源分辨率 ${player.state.width}x${player.state.height}');
      _syncRtxVsrCrop(trigger: 'size');
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
      // 同 width 监听：尺寸重置即作废签名（复核发现）。
      if (event == null) {
        _lastRtxVsrSignature = null;
      }
      _syncRtxVsrCrop(trigger: 'size');
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
    // 复验 P4：统一走 _disarmVsrDeferPlay，别手写清字段（会漏清 _vsrDeferPlayArmedAt）。
    _disarmVsrDeferPlay();
    // 就绪门：退房/换房即解除（取消超时并收起遮罩）
    _readyTimeoutTimer?.cancel();
    _readyTimeoutTimer = null;
    _readyPending = false;
    showReadyMaskRx.value = false;
  }

  void mediaEnd() {
    // 弱网调整：用户自责
    // WakelockPlus.disable();
  }

  void mediaError(String error) {
    // 弱网调整：用户自责
    // WakelockPlus.disable();
  }

  /// 音量均衡：同步入口（**队列外**调用，如热切换 worker）。内部入队执行 [_syncVolumeNormLocked]。
  Future<void> _syncVolumeNorm() => _enqueueVolumeNorm(_syncVolumeNormLocked);

  /// 音量均衡同步体（**无队版**，供队列任务内直接调用）。
  ///
  /// ⚠️ 只能在队列任务内调用；且任务内**禁止**改调 [_syncVolumeNorm]——那会在队列任务里
  /// 再入队，形成「内层等外层、外层 await 内层」的嵌套自死锁（P0，ISS-281）。
  Future<void> _syncVolumeNormLocked() async {
    if (_playerDisposed) {
      return;
    }
    PlayerMixin.afLoudnormSupported ??= _readPersistedCapability();
    if (PlayerMixin.afLoudnormSupported == null) {
      // 能力未知：执行一次探测（探测后按用户意愿自动还原/保持）
      await _probeVolumeNormCapability();
      return;
    }
    if (AppSettingsController.instance.volumeNorm.value) {
      // 复核 P3：这里等价于 afLoudnormSupported == true（volumeNormShouldApply 的
      // userOn 恒为 true 时是冗余包装），直接判断避免误导。
      if (PlayerMixin.afLoudnormSupported == true) {
        await _applyVolumeNorm(enable: true);
      }
    } else if (_volumeNormApplied) {
      await _applyVolumeNorm(enable: false);
    }
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
    // 复核（真机 P0，ISS-278）：探测入口复位 + 武装日志防线——成败判定推迟到
    // 窗末终裁（playing 事件早于 af 图构建，立即读标志必漏；失败日志在播放开始后
    // 数百 ms 内到达）。旧逻辑「回读后立即读标志」在真机上系统性漏判。
    _volumeNormLogFailure = false;
    _volumeNormLogArmed = true;
    Log.d('[VN] 探测: applied=$_volumeNormApplied supported=${PlayerMixin.afLoudnormSupported}');
    var chainSet = true;
    try {
      // 起流前已预挂（_volumeNormApplied=true）时只回读校验、不再 set：
      // set 会重建整条链并重置 loudnorm 收敛状态 → 进房第一秒响度又爬一遍。
      if (!_volumeNormApplied) {
        await pp.setProperty('af', volumeNormFilter);
      }
      // 回读校验：mpv 对非法/不存在的滤镜会拒绝写入并保持旧值，
      // 因此回读必须同时包含 dynaudnorm 与 loudnorm 才算支持（只查 loudnorm 不严）。
      final readback = await pp.getProperty('af');
      chainSet = volumeNormSupportedFromReadback(readback);
    } catch (e) {
      Log.logPrint(e);
      chainSet = false;
    }
    if (!chainSet) {
      // 解析期拒绝（滤镜缺失/参数非法）：当场判不支持（EV-411：这类失败在解析期
      // 即被拒，回读即真相，无需等终裁）
      _volumeNormLogArmed = false;
      _finishVolumeNormProbe(supported: false, token: token);
      return;
    }
    // 链已挂上但「运行时是否真的建链成功」→ 窗末终裁（失败日志异步到达）
    final vnToken = ++_volumeNormToken;
    // 转义出任务 Zone（同 _scheduleVolumeNormAdjudication）：定时器回调属队列外
    Future.delayed(const Duration(milliseconds: 2000), Zone.root.bindCallback(() async {
      if (vnToken != _volumeNormToken || _playerDisposed) {
        // glm 复核 P3：终裁被更新的音量均衡操作取代时能力停留 null（本房不再重探，
        // 下房预挂/探测重来）——低频边角，可接受。
        return;
      }
      _volumeNormLogArmed = false;
      // 阶段1（L3）修正：与终裁同语义——只信日志标志；回读失链（open 复位/死链
      // 重拉）仅诊断记录，不判失败（死链误杀会 persist false 置灰、需版本才能恢复）
      final failed = _volumeNormLogFailure;
      try {
        final readback = await pp.getProperty('af', waitForInitialization: false);
        if (!failed && !volumeNormSupportedFromReadback(readback)) {
          Log.d('音量均衡：探测终裁回读失链（af="$readback"）——疑似 open 复位，下房重探');
        }
      } catch (e) {
        Log.logPrint(e);
      }
      // 复核 N2/C1 补充：终裁落地入队执行（体内 setProperty 不再绕过队列与热切换交错）
      await _enqueueVolumeNorm(() async {
        // 阶段4 复核：入队后再自查代际——排队等待期间可能被新热切换/新探测取代
        // （对齐 _scheduleVolumeNormAdjudication 的入队后复查惯例）
        if (vnToken != _volumeNormToken || _playerDisposed) {
          return;
        }
        await _finishVolumeNormProbe(supported: !failed, token: token);
      });
    }));
  }

  /// 音量均衡：探测终裁落地（能力持久化 + UI 同步 + 链状态收敛）。
  Future<void> _finishVolumeNormProbe({required bool supported, required int token}) async {
    final pp = player.platform;
    if (pp is! NativePlayer) {
      return;
    }
    PlayerMixin.afLoudnormSupported = supported;
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
      Log.w('音量均衡：探测终裁未通过（logFailure=$_volumeNormLogFailure）→ 清链并禁用开关');
      SmartDialog.showToast("当前播放核心不支持音量均衡，开关已禁用");
    }
    _scheduleSuppressRelease(token);
  }

  /// 音量均衡：对播放器应用/移除 loudnorm 滤镜（能力已知时使用；仅由 _syncVolumeNorm 在队列内调用）。
  /// 入写锁（P1-3 写序互斥）后执行。
  Future<void> _applyVolumeNorm({required bool enable}) =>
      _withWriteMutex(() => _applyVolumeNormUnlocked(enable: enable));

  Future<void> _applyVolumeNormUnlocked({required bool enable}) async {
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
    if (enable && PlayerMixin.afLoudnormSupported == false) {
      // 已知不支持：不再尝试（UI 已禁用，这里是保险短路）
      return;
    }
    final token = ++_suppressToken;
    _suppressErrorRetry = true;
    final opStart = DateTime.now();
    Log.d('[VN] 执行: enable=$enable（原 applied=$_volumeNormApplied supported=${PlayerMixin.afLoudnormSupported}）');
    // 阶段1（L3）修正：日志防线记录在 set **之前**武装——set 完成到武装赋值之间
    // 有微任务间隙，失败日志（异步到达）可能落入该缝而漏记；预挂/探测均为 set 前
    // 武装，此处对齐。
    if (enable) {
      _volumeNormLogFailure = false;
      _volumeNormLogArmed = true;
    } else {
      // 关闭：先解除武装，避免旧失败记录污染后续房间
      _volumeNormLogArmed = false;
      _volumeNormLogFailure = false;
    }
    try {
      await pp.setProperty('af', enable ? volumeNormFilter : '');
      _volumeNormApplied = enable;
      Log.d('[VN] 执行完成: enable=$enable 耗时=${DateTime.now().difference(opStart).inMilliseconds}ms');
    } catch (e) {
      Log.logPrint(e);
      if (enable) {
        // 开启失败：保守回退到无滤镜并禁用开关
        try {
          await pp.setProperty('af', '');
        } catch (_) {}
        _volumeNormApplied = false;
        _volumeNormLogArmed = false; // set 抛异常：解除武装（无终裁可消费，防泄漏）
        PlayerMixin.afLoudnormSupported = false;
        _persistCapability(false);
        AppSettingsController.instance.setVolumeNormSupported(false);
        SmartDialog.showToast("音量均衡应用失败，已禁用开关");
      } else {
        // 关闭失败：回读真实状态，避免 UI 显示与实际听感不一致
        try {
          final readback = await pp.getProperty('af');
          if (readback.trim().isNotEmpty) {
            // 复核 P2-1：残留**部分**链（如只清了 loudnorm 剩 dynaudnorm）也视为
            // 「仍在均衡」——只按「整条链」判定会把残留链误标成已关闭（UI 关、
            // 实际还在均衡）。再清一次。
            await pp.setProperty('af', '');
            // 复核（阶段4 第3轮 P3）：复清后再回读确认——setProperty 忽略 mpv 返回码，
            // 静默拒绝时残留链仍在，不能直接标已关（UI 关、实际仍均衡）。
            final after = await pp.getProperty('af');
            _volumeNormApplied = after.trim().isNotEmpty;
          } else {
            _volumeNormApplied = false;
          }
        } catch (e2) {
          Log.logPrint(e2);
          // 回读/复清也失败：保守保持「已应用」，下次关闭会重试
          _volumeNormApplied = true;
        }
        if (_volumeNormApplied) {
          SmartDialog.showToast("音量均衡关闭失败，请重试");
        }
      }
    }
    if (enable && _volumeNormApplied) {
      // 复核（真机 P0，ISS-278）：热开也预约窗末终裁——
      // 旧逻辑 set 成功即 applied=true、无任何复核，破构建上热开静默无效。
      // glm 复核 P2：热开再做一次回读校验（setProperty 忽略 mpv 返回码，解析期静默
      // 拒绝且无 af 前缀日志时终裁只信标志会放行）——失链当场清链、不预约终裁。
      String? readback;
      try {
        readback = await pp.getProperty('af');
      } catch (e) {
        Log.logPrint(e);
      }
      if (readback != null && !volumeNormSupportedFromReadback(readback)) {
        _volumeNormLogArmed = false; // 链没挂上：取消终裁（无失败可消费）
        _volumeNormApplied = false;
        try {
          await pp.setProperty('af', '');
        } catch (_) {}
        Log.w('音量均衡：热开回读未确认（af="$readback"）→ 已清链，能力现状维持待下房');
      } else {
        _scheduleVolumeNormAdjudication(
          vnToken: ++_volumeNormToken,
          suppressToken: token,
          source: '热切换开启',
        );
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
    // 复核（复验 P3）：门控正武装着（等尺寸事件挂链）时热关 VSR → 没有链可等，别白等超时兜底
    // （最长 3s 黑屏）；但必须**先摘链、后放行**——media_kit 的 play/setProperty 同走一把锁 FIFO，
    // 若先 play()，摘链就落在播放态 → mpv 又一次 playback restart（正是门控要避免的「出画面又重载」）。
    // 此刻还在暂停态，先摘链不可见；摘完再放行，顺带消掉「放行到摘链之间」的错误抑制空窗。
    final releaseGateAfterSync = !enabled && _vsrDeferPlay;
    // 注：**不清 `_lastRtxVsrScale`**——它是「mpv 实际已挂链」的唯一记录，摘链判断依赖它非空；
    // 在决定动作前清空会导致关闭时永不摘链→绿条复现（阶段4 复核 P0）。
    // hwdec 与错误抑制由 `_syncRtxVsrCrop` 内部统一处理。
    try {
      await _syncRtxVsrCrop(trigger: 'toggle');
    } catch (e) {
      Log.d('[VSR] 热切换失败: $e');
    }
    if (releaseGateAfterSync) {
      Log.d('[VSR] 门控期间热关 VSR → 摘链后放行起播');
      unawaited(_releaseVsrDeferPlay('vsr-off'));
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
          Obx(
            () => SwitchListTile(
              title: const Text("OSD 显示"),
              value: showOSDStats.value,
              onChanged: (value) => toggleOSDStats(),
            ),
          ),
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
