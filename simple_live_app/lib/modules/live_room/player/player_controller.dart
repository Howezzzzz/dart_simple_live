import 'dart:async';
import 'dart:convert';
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
import 'package:simple_live_app/app/utils/pipeline.dart';
import 'package:simple_live_app/app/utils/rtx_vsr_crop.dart';
import 'package:simple_live_app/app/utils/vsr_replay_policy.dart';
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

  /// ① 批次 B（1.08.84 / C3 R3）：进房预挂的**统一中枢留痕钩子**（留痕 only，零播放器 I/O）。
  ///
  /// 为何是钩子而非直呼：`initializePlayer` 在 `mixin PlayerMixin`（**无 `on` 约束**）内，
  /// 而统一中枢 `applyPipelineChange` 实现在 `class PlayerController` —— Dart 不允许 mixin
  /// 直呼「使用它的类」的成员（analyzer: undefined_method；同 L404-406「被引用的状态必须
  /// 自持」复核 P0-1 的同一类问题）⇒ 采「**可覆写钩子**」形（§11.3 N2 同款），
  /// 以保住 R4-2 钉死的插入点（旧 `[APPLY]` 行之后、写点之前）与日志时序。
  /// 默认空实现 = 零行为（不碰播放器、不碰队列）；`PlayerController` 覆写为
  /// `applyPipelineChange(source, norm: false, vsr: false)`（委派条件 `if (norm)` /
  /// `if (vsr && Platform.isWindows)` 均跳过 ⇒ 只跑聚合留痕）。
  Future<void> _tracePipelinePreApply(String source) async {}

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
      // P1-3：硬解已在 `videoController` 创建期随 `hwdec: 'd3d11va'` 一次给定（见 videoController），
      // 此处不再重复写（此前三笔同值写之一，阶段4 复核抓）。
      // 起播门控（P1-1 起播前单次写链）：不再预挂 2.0 兜底链——链在门控放行时按自适应
      // 终值**一次**写入；预挂 2.0 只在门控**超时**路径兜底（见 _preHangFallbackChain）。
      // _rtxVsrChainApplied 置 true 表示本次播放启用 VSR（门控期 plan 按「开」算自适应倍数）。
      _rtxVsrChainApplied = true;
    } else if (Platform.isWindows) {
      // 关闭 VSR 时必须摘掉已挂上的滤镜链（复核 P2-1）：只改标志不摘链的话，
      // 同一会话 F5/切清晰度重初始化后，链仍在放大画面、裁切却被清空 → 绿条复现且 VSR 代价照付。
      await _withWriteMutex(() => pp.setProperty('vf', ''));
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
    // ② P3/P2：进房重置 VSR 面板比例缓存 + 作废旧的重试代际/目标。
    _vsrDisplayAspect = null;
    _vsrCropRetryToken++;
    _vsrDesiredCrop = '';
    // v3.2 g1：代际重置 VO 尺寸缓存（本点在 initializePlayer 内，新源起流后由事件重填）。
    _resetLastVoutDwh();
    if (!_volumeNormApplied &&
        volumeNormShouldPreApply(
          userOn: AppSettingsController.instance.volumeNorm.value,
          supported: afLoudnormSupported,
        )) {
      // 实际会预挂才留痕（避免「什么都没做」也打 [APPLY]，阶段4 复核）
      Log.d('[APPLY] source=room-enter/reinit 均衡预挂（已挂=$_volumeNormApplied'
          ' 能力=${PlayerMixin.afLoudnormSupported}）');
      // ① 批次 B（1.08.84）R3：进房预挂改走统一中枢的**留痕 only**。
      // - **写点（下一行 `_enqueueVolumeNorm(() => _preApplyVolumeNorm())`）一字不动**，
      //   中枢也不接管落地：M1/N3 —— 整段委派会在 cap==null 时走 probe ⇒ 起流期开抑制窗
      //   （违 L609-611 铁律）+ `set af` 缺 `waitForInitialization:false` ⇒ 复发 ISS-269。
      // - `norm:false, vsr:false` ⇒ 中枢体内**零播放器 I/O、零真 await**（委派条件
      //   `if (norm)` L2947 / `if (vsr && Platform.isWindows)` L2950 均跳过，
      //   `_buildDesired` L2899 与 `_aggregateApplied` 全同步读）⇒ 日志**同步落序**
      //   （R3-2 乱序担忧消解）、仅微任务级 yield、不吃 P6 就绪门预算（§11.6 ① 正面新证）。
      // - 上面旧 `[APPLY] source=room-enter/reinit` 行**保留不删**（N3：删了即丢「均衡预挂」
      //   动作词 = 留痕字段口径实质「减」，违「可增不可减」）。
      // - 注：cap==null 时中枢 `[APPLY-diff]` 行的 `norm=probe`（pipeline.dart L242-243）
      //   **仅为期望描述**（「能力未知应探测」），本点并不真探测——探测仍由首帧钩子
      //   （`_verifyVolumeNormFirstFrame` / `_scheduleVolumeNormAdjudication`）负责，零改动。
      // - R4-2：try-catch **只包留痕、不包写点**——否则中枢留痕异常会静默丢掉预挂。
      // - 经 `_tracePipelinePreApply` 钩子委派（声明处注释：mixin 无 on 约束，不能直呼
      //   PlayerController 的 `applyPipelineChange`）；实现在 PlayerController，参数固定
      //   `norm: false, vsr: false`。
      try {
        await _tracePipelinePreApply('room-enter/reinit-preapply');
      } catch (e) {
        Log.d('[APPLY] source=room-enter/reinit-preapply 留痕异常（不影响预挂）: $e');
      }
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

  // ===== v3.5i（1.08.81 A⁗）：toggle 复用起播门控消「双重建」=====
  /// release 时是否 `play()`——默认 true（进房语义：必起播）；toggle 武装时改为「武装时是否在播」
  /// （防把用户窗口内的暂停强制恢复）。每次 `_armVsrDeferPlay` 重置为 true。
  bool _vsrGatePlayOnRelease = true;
  /// toggle 自己的遮罩所有权（成对显式开关，**禁止**复用 `_armReadyGate`——会连带静音且
  /// finish 条件在 toggle 期永不满足）。`_readyPending` 为真时**不抢所有权**（就绪门遮罩本就在）。
  bool _vsrToggleMaskOn = false;
  Timer? _vsrToggleMaskTimer;
  /// v3.5i：本次门控是 toggle 还是进房（release 的抑制窗是否解除按此区分）。
  bool _vsrGateIsToggle = false;

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
    // 阶段4 整改：换线路/重试＝换源，作废旧流的 crop 重试代际（否则旧重试会重写旧 crop、
    // 且签名短路后续纠正 → 错裁持续）。
    _vsrCropRetryToken++;
    _vsrDesiredCrop = ''; // 换源即清期望目标（严格更强、零风险；新源必有尺寸事件重设）
    // v3.2 g1：换线路/重试路径不走 initializePlayer，这里补 VO 缓存代际重置（轮2 W3-a/轮3 X1 直测
    // 换线路直接 player.open 不经 disposeStream → 此第三点是关键补漏）。
    _resetLastVoutDwh();
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
  /// 注：用 `Zone.root.bindCallback` 转义——该回调在 `_withWriteMutex` 锁体内被调度（:835/:1056 的 finally），
  /// 不转义会把写锁的 Zone 标记泄漏进来；将来若在本回调内新增写点，会静默绕锁（定向复验建议）。
  void _scheduleSuppressRelease(int token) {
    Future.delayed(
        volumeNormSuppressDuration,
        Zone.root.bindCallback(() {
          if (_playerDisposed) {
            return;
          }
          if (token == _suppressToken) {
            _suppressErrorRetry = false;
          }
        }));
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
  /// `_tlDump` 汇总时超过阈值会打 WARN（便于真机一眼看出慢）。
  static const int tlSlowThresholdMs = 4000;
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
    // 超阈判据用「就绪时刻」而非汇总时刻——汇总由 playing 后固定 2.5s 触发，
    // 直接用 total 会系统性多算 2.5s（阶段4 复核：达标的 4s 脏流也会误报 WARN）。
    final readyMs = _tlMarks['restart完成'] ?? _tlMarks['首帧/playing'];
    if (readyMs != null && readyMs > tlSlowThresholdMs) {
      Log.w('[TL] 起播耗时超阈（就绪=${readyMs}ms > ${tlSlowThresholdMs}ms）——见上方分节点耗时');
    }
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

  /// 在途管线写入计数（音量均衡队列 + VSR 裁切队列 + 放行点写链）。
  /// 注：放行点写链（② 改序后落在 play() **之后**）也计入——若不计入，就绪门会在
  /// 「play 已发 + restart 已见 + busy==0」时**提前解除**，随后写链的 VIDEO_RECONFIG 会让
  /// 画面 1080→2160 的跳变在**无遮罩**下可见（阶段4 复核发现）。计入后门会等写链落地才揭。
  int _pipelineBusy = 0;

  /// af/vf 写序互斥（P1-3）：两条队列保持**分离**（C3 硬约束：不合并——避免长 af 建链堆住
  /// VSR 的 vf 写入、破坏「VSR 点即生效」），但**真正写 mpv 的瞬间**互斥，避免「vf 重建中写 af」
  /// 交错。只在**叶子写函数**取锁（三个叶子互不调用 → 无嵌套、无死锁）。
  /// 例外（v3.5 C2 写链定序，复核 B-2 已记录）：`_applyVsrTargetUnlocked` 内「等新 scale 帧
  /// 落定」的等待（≤2s）在锁内——为保证 vf→crop→setSize 原子、不被其它 vf 写插入，属必要
  /// 权衡；等帧期间无写动作，锁占用为纯等待。就绪门（6s）余量因此变窄，已在防回归矩阵跟踪。
  Future<void> _writeMutex = Future<void>.value();
  static final Object _writeMutexZoneKey = Object();
  Future<T> _withWriteMutex<T>(Future<T> Function() body) {
    // 重入（已在锁体内再取锁）：直接执行，避开自死锁（今日无此调用，属未来防护）。
    if (Zone.current[_writeMutexZoneKey] == true) {
      return body();
    }
    final prev = _writeMutex;
    final gate = Completer<void>();
    _writeMutex = gate.future;
    return prev
        .then((_) =>
            runZoned(() => body(), zoneValues: {_writeMutexZoneKey: true}))
        .whenComplete(gate.complete);
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
      await _withWriteMutex(() async {
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
      });
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
            await _withWriteMutex(
                () => pp.setProperty('af', '', waitForInitialization: false));
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
  /// ② P3/C4：当前 VSR 链的**终态显示比例**（= plan.aspect），供面板宽一次到位。
  /// 仅「VSR 已生效」时非空；进房重置/退房时清空。
  double? _vsrDisplayAspect;

  /// v3.2→v3.3：最近一次 VO 输出尺寸（`video-out-params` 的 dw/dh）——v3.2 面板跟随 VO 的主源
  /// （ISS-294 自激闭环主犯，v3.3 已拆回灌边）；现退化为**纯诊断缓存**（[GEOM] 日志用），
  /// 唯一消费方 = 房B 稳态校正器 `_maybeApplyVsrCorrector`（四门一次性）。
  /// 代际（门禁 g1）：`initializePlayer` / `disposeStream` / `openSourceGated` 三点置空。
  (int, int)? _lastVoutDwh;

  /// v3.3（ISS-294）：最近一次写/摘 VSR 滤镜链的时刻（校正器静默门①「距最后链写 ≥2s」），
  /// 在全部四处 `++_vsrChainWriteCount` 处同步刷新。
  DateTime? _lastVsrChainWriteAt;

  /// v3.3（ISS-294）：当前 dw/dh 值**首次出现**的时刻；值变化即重置（稳定门②「dw/dh 连续
  /// ≥2s 不变」的计时起点，P1-3 语义：首现起算/值变重置/零 timer）。
  DateTime? _voutStableSince;

  /// v3.3（ISS-294）：校正器本轮代际是否已写过（一次性标记，防自激）；
  /// 随 `_resetLastVoutDwh` 三点代际重置（P1-5：连同全部时间状态一起清）。
  bool _vsrCorrectorFired = false;

  /// v3.3 校正器时限（ISS-294 终轮验证定）：静默/稳定 2s（过渡态实测 ≤0.6s，裕度 1.5~3×）。
  static const Duration vsrCorrectorQuietAfterWrite = Duration(seconds: 2);
  static const Duration vsrCorrectorStableDuration = Duration(seconds: 2);

  /// v3.3 校正器比值容差（滤 967↔968 量化噪声；也作门④比例比较容差，P1-4 禁裸等值）。
  static const double vsrCorrectorRatioTolerance = 0.005;

  /// ② P2：crop 延迟重写的代际（新进房/重置/换源时自增，旧回调自动作废）。
  int _vsrCropRetryToken = 0;

  /// ② P2：当前**期望**的 crop 目标（供重试回调做「目标未变」守卫——比代际更强）。
  String _vsrDesiredCrop = '';

  // ===== v3.5 C2（写链定序）：vf 重建后等新 scale 帧在 VO 落定，再下发 crop/setSize =====
  /// 非空 = 有写链正在等新 scale 帧落定（事件驱动：`_updateLastVoutDwh` 唤醒）。
  Completer<void>? _vsrSettleWaiter;
  /// 等待超时定时器（可取消——命中/abort/代际重置时撤销，防残留）。v3.5a 复核 C-3。
  Timer? _vsrSettleTimer;
  /// 期望的**新 scale 帧真实尺寸** `(w,h)` 候选对（v3.5h：判据由 dw/dh 改为 w/h）。
  Set<(int, int)>? _vsrSettlePairs;
  /// 帧**真实尺寸**（`video-params/w,h`，crop 不影响）——「新 scale 是否落定」的判据。
  (int, int)? _lastVoutWH;
  /// `w/h` 稳定计时起点（与 dw/dh 的 `_voutStableSince` 分开：前者判落定、后者供校正器）。
  DateTime? _voutWHStableSince;
  /// 等待期间的目标 crop（与 `_vsrDesiredCrop` 比对做 abort）。
  String _vsrSettleCrop = '';
  /// 等待上限（轮4 定值）：双链连写实测 vf 落定 ≈2s。
  static const Duration vsrSettleTimeout = Duration(seconds: 2);

  // ===== v3.5 C1（应用级修因：**条件式**重放，取代固定延迟）=====
  /// 当前链期望的新 scale out 候选对（链写入时布防、代际重置/重臂时清空）；
  /// null = 未布防 → 修因不触发。
  Set<(int, int)>? _vsrRepairPairs;
  /// 本代际修因还可重放几次（有界 3；三站点 + 三处重臂点重置）。
  int _vsrRepairBudget = 3;
  /// 上次修因重放时刻（重放冷却锚点，防同帧重复写）。
  DateTime? _vsrLastRepairAt;
  /// 校正器四门已通过、等修因结果：修因成功 → 清；耗尽/超时 → 落「Rx=960 迁就」兜底。
  bool _vsrCorrectorFallbackPending = false;
  /// v3.5i（1.08.83 / ISS-311）：校正器**开始等待**兜底的时刻——兜底「进度锚点」的一元。
  /// 与 `_vsrCorrectorFallbackPending` 同源生命周期（置位同处、`_clearVsrCorrectorFallback` 清）。
  DateTime? _vsrCorrectorPendingAt;
  /// 代际序号（`_resetLastVoutDwh` 自增）：settle await 前后比对，防写入被换源作废的旧目标。
  int _vsrRepairEpoch = 0;
  /// 修因冷却（两次重放写的最小间隔）。
  static const Duration vsrRepairCooldown = Duration(milliseconds: 400);
  /// 判「新 scale 已落定」所需的 dw/dh 稳定时长。
  static const Duration vsrRepairStableDuration = Duration(milliseconds: 300);
  /// 修因兜底的绝对安全网：校正器请求后若迟迟等不到落定，超此时长仍兜底迁就。
  static const Duration vsrCorrectorFallbackMaxWait = Duration(seconds: 8);
  /// 落定判据的像素容差（防 mpv 输出 ±1px 偏差使「已落定」永假，v3.5c 复核 B-1）。
  static const int vsrRepairPairTolerancePx = 3;
  /// 「校正器等兜底」的安全网定时器（事件断流时仍能兜底，v3.5c 复核 C-2）。
  Timer? _vsrFallbackTimer;
  /// 安全网续挂剩余次数（v3.5e 复核：防「兜底写入恒失败」时无界轮询）。
  int _vsrFallbackRearmsLeft = 3;

  /// ② P3/C4：当前「真源」尺寸 = 解码器输出（mpv `video-params/w,h`），
  /// **不受 `video-aspect-override` 影响**（`state.width/height` 是 dw/dh，会被它污染）。
  /// rotate 90/270 时回退 `state.width/height`（videoParams.w/h 是未旋转的存储尺寸）。
  (int, int) _trueSourceSize() {
    final vp = player.state.videoParams;
    final rotated = vp.rotate == 90 || vp.rotate == 270;
    if (!rotated) {
      final w = vp.w;
      final h = vp.h;
      if (w != null && h != null && w > 0 && h > 0) return (w, h);
    }
    return (player.state.width ?? 0, player.state.height ?? 0);
  }

  // ===== v3 诊断（1.08.75 · 行为零改动，仅打点；用于定位「稳态黑边」的陈旧比例）=====

  /// 是否已订阅 `video-out-params`（防重复订阅）。
  bool _geomObserving = false;

  /// 是否已启动几何轮询。
  bool _geomPolling = false;

  /// 抓一次几何快照（**只读**：getProperty + widget/窗口尺寸 + 面板宽）。
  Future<void> _logGeom(String tag) async {
    try {
      final pp = player.platform;
      if (pp is! NativePlayer) {
        Log.d('[GEOM] $tag platform≠NativePlayer');
        return;
      }
      final vp = await pp.getProperty('video-params');
      final vout = await pp.getProperty('video-out-params');
      final crop = await pp.getProperty('video-crop');
      final ao = await pp.getProperty('video-aspect-override');
      final ctx = globalPlayerKey.currentContext;
      final cs = ctx?.size;
      final panel = AppSettingsController.instance.messagePanelWidth.value;
      Log.d('[GEOM] $tag'
          ' mpv{vp=$vp out=$vout dw=${player.state.width}x${player.state.height}'
          ' crop="$crop" ao=$ao}'
          ' flutter{widget=${cs?.width.toStringAsFixed(1)}x${cs?.height.toStringAsFixed(1)}'
          ' panelIntent=$panel vsrAspect=${_vsrDisplayAspect?.toStringAsFixed(4) ?? "-"}}');
      // 注：面板**实际渲染宽**（renderW）与窗口内容宽由既有 `panelOverlay content=… renderW: …` 行给出
      // （由页面单帧派生，控制器侧拿不到）→ 按时间戳与本行对照即可。
    } catch (e) {
      Log.d('[GEOM] $tag 取样异常: $e');
    }
  }

  /// 每 5s 抓一次稳态几何（自续期；`_playerDisposed` 即停）。
  ///
  /// 注：**不要在续期路径里走同一个守卫**（首个实现踩过：`_startGeomPoller()` 递归时
  /// `_geomPolling` 仍为 true → 守卫直接 return → 整个房间只采一次「+5s」样本）。
  void _startGeomPoller() {
    if (_geomPolling) return;
    _geomPolling = true;
    _scheduleNextGeomPoll();
  }

  void _scheduleNextGeomPoll() {
    Future.delayed(const Duration(seconds: 5), () {
      if (_playerDisposed) {
        _geomPolling = false;
        return;
      }
      unawaited(_logGeom('poll'));
      _scheduleNextGeomPoll();
    });
  }

  /// ② P3/C5：面板用的宽高——VSR 生效时按**终态显示比例**折算（一次到位），否则原样。
  /// 门控＝Windows ∧ `_vsrDisplayAspect` 非空（VSR 关 / 安卓天然不命中）。
  (int, int) _panelAspectSize(int? w, int? h) {
    final a = _vsrDisplayAspect;
    if (Platform.isWindows && a != null && h != null && h > 0) {
      return ((h * a).round(), h);
    }
    return (w ?? 0, h ?? 0);
  }

  /// v3.2：从 `video-out-params` 事件值解析 dw/dh → 更新缓存；**仅当 dw/dh 值变化时**
  /// 重置 120ms one-shot 去抖 timer（门禁 g4 + 首轮验证 P0：事件是 ~30/s 常态连续流，
  /// 按条数重置会让 timer 永不触发——只对值变化才有意义）。解析失败跳过该条、
  /// 缓存保持旧值（30/s 连续流自愈）。**必须纯同步、禁 await 重活**（obs 回调在主
  /// isolate 的 native event drain 里串行执行，拖住会阻塞全部后续 mpv 事件）。
  void _updateLastVoutDwh(String raw) {
    try {
      final m = jsonDecode(raw);
      if (m is! Map<String, dynamic>) return;
      final dwNum = m['dw'];
      final dhNum = m['dh'];
      final dw = dwNum is num ? dwNum.toInt() : null;
      final dh = dhNum is num ? dhNum.toInt() : null;
      // v3.5h：先解析**帧真实尺寸** w/h（crop 不影响）——供 C2 落定 / C1 landed 判据。
      // 与 dw/dh 解耦：任一字段缺失/非法时各自退化（w/h 有值仍可入库）。
      final wNum = m['w'];
      final hNum = m['h'];
      final wv = wNum is num ? wNum.toInt() : null;
      final hv = hNum is num ? hNum.toInt() : null;
      if (wv != null && hv != null && wv > 0 && hv > 0) {
        final prevWH = _lastVoutWH;
        _lastVoutWH = (wv, hv);
        if (prevWH == null || prevWH.$1 != wv || prevWH.$2 != hv) {
          _voutWHStableSince = DateTime.now();
        }
      }
      if (dw == null || dh == null || dw <= 0 || dh <= 0) {
        return; // g4：>0 才入库
      }
      final prev = _lastVoutDwh;
      _lastVoutDwh = (dw, dh);
      // v3.3（ISS-294）：v3.2 的 120ms 去抖回灌已拆除（自激闭环主犯）。退化为纯缓存 + 稳定门计时。
      // P1-3 语义：值变化才重置首现时刻；稳态（值不变）保持原时刻、零 timer 零重置。
      if (prev == null || prev.$1 != dw || prev.$2 != dh) {
        _voutStableSince = DateTime.now();
      }
      _maybeCompleteVsrSettle(); // v3.5 C2：唤醒写链定序等待器
      _maybeApplyVsrCorrector();
      _maybeRepairVsrCrop(); // v3.5 C1：应用级修因（条件式；crop 未被 VO 应用 → 重放自救）
    } catch (_) {
      // 解析失败：跳过该条、缓存保持旧值（g4）。
    }
  }

  /// v3.5 C2/C1（写链定序 + 修因）：计算 vf 重建后新 scale 帧的期望**真实尺寸** `(w,h)`。
  /// v3.5h：判据由显示尺寸 dw/dh 改为帧真实尺寸 w/h（crop 不影响 w/h）——旧判据会被仍生效的
  /// 旧 crop 卡住 → 恒等不到 → 每次死等 2s（开 VSR「等几秒」根因）。纯逻辑抽在
  /// `vsrExpectedFramePairs`（可单测）。
  Set<(int, int)>? _vsrExpectedFramePairs(_VsrTarget t) => vsrExpectedFramePairs(
        rawW: t.rawW,
        rawH: t.rawH,
        scale: t.scale,
      );

  /// v3.5 C2：写链定序等待——vf 重建后等新 scale 帧在 VO 落定，或超时（2s），或被新目标 abort。
  /// 事件驱动（`_updateLastVoutDwh` 唤醒）；锁内 await 期间 obs 回调不取写锁 → 无死锁。
  Future<void> _awaitVsrChainSettle(_VsrTarget t) async {
    final exp = _vsrExpectedFramePairs(t);
    if (exp == null) return;
    final cur = _lastVoutWH; // v3.5h：用帧真实尺寸 w/h 判落定（dw/dh 会被旧 crop 卡住）
    if (cur != null && vsrMatchesPair(exp, cur, tolPx: vsrRepairPairTolerancePx)) {
      return; // 已在新 scale 态，无需等待
    }
    final c = Completer<void>();
    _vsrSettleWaiter = c;
    _vsrSettlePairs = exp;
    _vsrSettleCrop = t.crop;
    _vsrSettleTimer?.cancel();
    _vsrSettleTimer = Timer(vsrSettleTimeout, () {
      if (!c.isCompleted) {
        Log.d('[VSR] 写链定序：等新 scale 帧超时 ${vsrSettleTimeout.inSeconds}s'
            ' → 照写（交 C1 修因兜底）');
        c.complete();
      }
    });
    try {
      await c.future;
    } finally {
      if (identical(_vsrSettleWaiter, c)) {
        _vsrSettleWaiter = null;
        _vsrSettlePairs = null;
        _vsrSettleCrop = '';
      }
      _vsrSettleTimer?.cancel();
      _vsrSettleTimer = null;
    }
  }

  /// v3.5 C2：out-params 事件到达时唤醒等待器——命中期望 dw/dh 或被新目标 abort 即完成。
  void _maybeCompleteVsrSettle() {
    final c = _vsrSettleWaiter;
    if (c == null || c.isCompleted) return;
    if (_vsrDesiredCrop != _vsrSettleCrop) {
      c.complete(); // abort：等待期间目标已被新写链替换（新链排在写锁之后）
      return;
    }
    final v = _lastVoutWH; // v3.5h：帧真实尺寸判落定
    final pairs = _vsrSettlePairs;
    if (v == null || pairs == null) return;
    if (vsrMatchesPair(pairs, v, tolPx: vsrRepairPairTolerancePx)) {
      c.complete();
    }
  }

  /// v3.3（ISS-294）：房B 稳态校正器——唯一允许的 VO→Rx 回灌，四门串联 + 代际一次性。
  ///
  /// 目的：房B（crop 回读匹配但 VO 未应用，dw/dh 滞留源比 3600x2040=1.7647）在开向稳态下
  /// 按实测比例修正面板宽（Rx = curH×dw/dh），消除 13px 黑边（Howe 定不可退让）。
  /// 房A（crop 生效，dw/dh==crop 目标）被门④关死，永不写。
  ///
  /// 四门（全部通过才写一次；外门 = Windows ∧ 链已挂 ∧ 未 dispose，同旧 applier g3）：
  /// ① 静默门：距最后一次滤镜链写 ≥2s（过渡态最长实测 ~0.6s，裕度 1.5~3×）
  /// ② 稳定门：dw/dh 连续 ≥2s 不变（pre-crop 过渡态与房B 病理态同值不可分辨、
  ///    只能靠时间区分——此门是唯一分辨手段）
  /// ③ 容差门：|dw/dh 比 − 当前 Rx 比| > 0.5%（滤 967↔968 量化噪声；校正后自身比值归零
  ///    → 门自关，天然防自激）
  /// ④ crop 指纹门：dw/dh 比 ≠ crop 目标比（**比例比较带容差，禁裸等值**，P1-4）——
  ///    房A dw/dh==crop 目标 → 关死；房B dw/dh=源比 ≠ 目标 → 开
  ///
  /// P1-2：写入 Rx 时同步改写 `_vsrDisplayAspect`=实测比（W3/W4/W5 同值幂等；配合
  /// `_syncRtxVsrCrop` 的代际内守卫，不被后续假说重置冲回）。
  void _maybeApplyVsrCorrector() {
    if (_vsrCorrectorFired) return; // 代际一次性（防自激）
    if (_playerDisposed || !Platform.isWindows || !_rtxVsrChainApplied) return;
    final v = _lastVoutDwh;
    final curW = videoWidthRx.value;
    final curH = videoHeightRx.value;
    if (v == null || v.$1 <= 0 || v.$2 <= 0 || curW <= 0 || curH <= 0) return;
    final now = DateTime.now();
    final lastWrite = _lastVsrChainWriteAt;
    // ① 静默门（链写未知/距今 <2s：过渡态内不校正）。
    if (lastWrite == null ||
        now.difference(lastWrite) < vsrCorrectorQuietAfterWrite) {
      return;
    }
    final stableSince = _voutStableSince;
    // ② 稳定门（dw/dh 未连续 2s 不变）。
    if (stableSince == null ||
        now.difference(stableSince) < vsrCorrectorStableDuration) {
      return;
    }
    final voRatio = v.$1 / v.$2;
    final curRatio = curW / curH;
    // ③ 容差门（比值差 ≤0.5%：967↔968 量化噪声 / 已校正 → 不写）。
    if ((voRatio - curRatio).abs() <= vsrCorrectorRatioTolerance) {
      return;
    }
    // ④ crop 指纹门：dw/dh 比 == crop 目标比（房A）→ 关死，永不写。
    final target = _vsrDesiredCropRatio();
    if (target != null &&
        (voRatio - target).abs() <= vsrCorrectorRatioTolerance) {
      return;
    }
    _vsrCorrectorFired = true;
    // v3.5 C1/C3（校正器降级为兜底）：四门通过 → **先「重放修因」**（应用级修因因 dw/dh 比
    // ≠ crop 目标而触发条件式重放），不再直接迁就 Rx。修因成功 → dw/dh 命中目标 → 门④/门③
    // 自关 → Rx 保持 967（房B 黑边由 crop 应用消除，而非靠迁就面板宽）；修因耗尽/超时 →
    // 落 v3.3「Rx=960 迁就」兜底。无 crop 目标时修因不触发 → 直接迁就（保 v3.3 语义）。
    final cTarget = _vsrDesiredCropRatio();
    if (cTarget != null) {
      // 修因不可用（无预算 / 链未挂 / 无目标）时直接兜底，防 pending 永挂（B-3 复核项）。
      if (_vsrRepairBudget > 0 && _rtxVsrChainApplied && _vsrDesiredCrop.isNotEmpty) {
        _vsrCorrectorFallbackPending = true;
        // v3.5i（ISS-311）：必须**先于** `_armVsrFallbackTimer()` 赋值——`vsrFallbackDue`
        // 用严格 `<`，晚赋值会让首次回调只剩毫秒余量（当场可复现）。
        _vsrCorrectorPendingAt = DateTime.now();
        _vsrFallbackRearmsLeft = 3;
        // v3.5c/d 复核：挂独立安全网定时器（事件断流也能兜底；回调复核进度，不无条件抢跑）。
        _armVsrFallbackTimer();
        Log.d('[VSR] 房B 校正器：四门通过 → 请求 crop 修因重放'
            '（Rx=${curW}x$curH 暂不迁就，dw/dh 比=$voRatio 目标=$cTarget）');
      } else {
        _clearVsrCorrectorFallback();
        Log.d('[VSR] 房B 校正器：四门通过但无可重放（预算/链/目标）→ 直接 Rx 迁就兜底'
            '（Rx=${curW}x$curH 比=$voRatio）');
        _applyVsrCorrectorFallback();
      }
    } else {
      _vsrDisplayAspect = voRatio; // P1-2：同步实测比（W3/W4/W5 同值幂等）
      videoWidthRx.value = (curH * voRatio).round();
      Log.d('[VSR] 房B 稳态校正器（无 crop 目标）：Rx=${curW}x$curH'
          ' → ${videoWidthRx.value}x$curH（dw/dh 比=$voRatio）');
    }
  }

  /// 解析 `_vsrDesiredCrop`（格式 "WxH+X+Y"，如 "3600x2024+0+0"）为宽高比；
  /// 未设置/格式异常返回 null（门④对无裁切源不设防，靠门③即可）。
  double? _vsrDesiredCropRatio() => vsrCropRatio(_vsrDesiredCrop);

  /// v3.2→v3.3：代际重置 VO 尺寸缓存 + 校正器计时状态（门禁 g1，三点：`initializePlayer` /
  /// `disposeStream` / `openSourceGated`）——防换线路/退房/重试把上一线路的 dw/dh 当新线路
  /// 初值；P1-5：清空稳定计时起点与一次性标记（v3.2 的 timer 已随回灌拆除）。
  /// 注（实现复核 P2-偏差1 修正）：`_lastVsrChainWriteAt` **故意不清**——同签名换线路（新源
  /// 与旧源同分辨率）时若清空，静默门①将因 null 而哑火直到下次链写；保留旧时间戳让校正器
  /// 在 ≥2s 后可再次评估（行为方向更优，取舍依据已补记方案文档）。
  void _resetLastVoutDwh() {
    _lastVoutDwh = null;
    _lastVoutWH = null;
    _voutStableSince = null;
    _voutWHStableSince = null;
    _vsrCorrectorFired = false;
    // v3.5 C1：修因状态随代际重置（预算 / 兜底标记 / 布防 / 冷却锚点）。
    _vsrRepairBudget = 3;
    _clearVsrCorrectorFallback();
    _vsrRepairPairs = null;
    _vsrDesiredCrop = ''; // v3.5g 复核 P2：代际重置清期望目标，防旧 crop 比污染校正器门③/④
    _vsrLastRepairAt = null;
    // v3.5 C1（C-2/C-3 复核项）：代际自增 → 作废在飞的 settle 等待（其 await 后比对 epoch），
    // 并主动唤醒 + 撤销超时定时器（不再只能等事件或超时）。
    _vsrRepairEpoch++;
    final w = _vsrSettleWaiter;
    if (w != null && !w.isCompleted) w.complete();
    _vsrSettleTimer?.cancel();
    _vsrSettleTimer = null;
  }

  /// v3.5 C1：dw/dh 比是否已命中 crop 目标比（**应用级**判据，带容差）——
  /// 回读只能证「属性被接受」，此判据才是「VO 逐帧应用成功」。
  bool _voutAppliedCropTarget() {
    final v = _lastVoutDwh;
    if (v == null) return false;
    return vsrOutAppliedCrop(
      dw: v.$1,
      dh: v.$2,
      targetRatio: _vsrDesiredCropRatio(),
      tolerance: vsrCorrectorRatioTolerance,
    );
  }

  /// v3.5 C1（应用级修因 · **条件式**）：链已挂 + 有 crop 目标，且观测到**新 scale 帧已落定**
  /// （w/h ∈ 期望候选对，v3.5h 由 dw/dh 改 w/h）并稳定，但 dw/dh 比 ≠ crop 目标比 ⇒ crop
  /// 未被 VO 应用（写链竞态/被丢弃）→ **立即**重放自救（写在与新 scale 匹配的帧上，不会被丢弃）。
  /// 条件式取代原「静默≥2s + 稳定≥2s + 固定延迟 250/600/1200ms」——不再猜时机（A-2/F-1 复核项）。
  /// 有界（`_vsrRepairBudget`）；命中目标即清 `_vsrCorrectorFallbackPending`；耗尽/超时落 v3.3 兜底。
  void _maybeRepairVsrCrop() {
    if (_playerDisposed || !Platform.isWindows) return;
    if (!_rtxVsrChainApplied || _vsrDesiredCrop.isEmpty) return;
    final v = _lastVoutDwh;
    final vWH = _lastVoutWH; // v3.5h：落定判据用帧真实尺寸 w/h
    if (v == null || vWH == null) return;
    if (_voutAppliedCropTarget()) {
      _clearVsrCorrectorFallback(); // 已应用 → 无需兜底
      return;
    }
    final now = DateTime.now();
    // 绝对兜底（v3.5c 复核 C-1/C-3）：**不以预算耗尽为前提**；校正器在等、任一路径超时
    // 无进展且仍未应用 → 落 v3.3「Rx 迁就」。写入成功才清 pending（失败留待下次）。
    if (vsrFallbackDue(
      chainApplied: _rtxVsrChainApplied,
      crop: _vsrDesiredCrop,
      applied: false,
      correctorPending: _vsrCorrectorFallbackPending,
      sinceProgress: _vsrSinceProgress(),
      maxWait: vsrCorrectorFallbackMaxWait,
    )) {
      Log.d('[VSR] 修因绝对兜底（≥${vsrCorrectorFallbackMaxWait.inSeconds}s 无进展）→ Rx 迁就');
      _finishVsrCorrectorFallback();
      return;
    }
    final pairs = _vsrRepairPairs;
    final go = vsrShouldRepair(
      chainApplied: _rtxVsrChainApplied,
      crop: _vsrDesiredCrop,
      applied: false,
      landed: vsrMatchesPair(pairs, vWH, tolPx: vsrRepairPairTolerancePx),
      stableFor:
          _voutWHStableSince == null ? null : now.difference(_voutWHStableSince!),
      sinceRepair:
          _vsrLastRepairAt == null ? null : now.difference(_vsrLastRepairAt!),
      stable: vsrRepairStableDuration,
      cooldown: vsrRepairCooldown,
      budgetLeft: _vsrRepairBudget,
    );
    if (!go) return;
    // v3.5d 复核 P2：先确认「真能调度」再扣预算/推进冷却锚点（否则守卫静默 return 时空转）。
    if (!_scheduleVsrCropReplay(_vsrDesiredCrop)) return;
    _vsrRepairBudget--;
    _vsrLastRepairAt = now; // v3.5c 复核 B-3：冷却锚点在**发起时**置位（写异常也不失效）
    Log.d('[VSR] 应用级修因：新 scale 已落定（w/h=${vWH.$1}x${vWH.$2}）但 crop 未应用'
        '（dw/dh=${v.$1}x${v.$2} 比 ${(v.$1 / v.$2).toStringAsFixed(6)}'
        ' 目标 ${_vsrDesiredCropRatio()?.toStringAsFixed(6)}）→ 重放'
        '（本代际剩 $_vsrRepairBudget）');
  }

  /// v3.5 C1（C3 降级）：重放耗尽/超时的兜底——v3.3 的「Rx=960 迁就」语义。
  /// 返回是否真的写入（false = 无可用尺寸，调用方保留 pending 待下次）。
  bool _applyVsrCorrectorFallback() {
    final v = _lastVoutDwh;
    final curW = videoWidthRx.value;
    final curH = videoHeightRx.value;
    if (v == null || v.$1 <= 0 || v.$2 <= 0 || curW <= 0 || curH <= 0) {
      return false;
    }
    final voRatio = v.$1 / v.$2;
    _vsrDisplayAspect = voRatio; // P1-2：同步实测比（W3/W4/W5 同值幂等）
    videoWidthRx.value = (curH * voRatio).round();
    Log.d('[VSR] 校正器兜底：Rx=${curW}x$curH'
        ' → ${videoWidthRx.value}x$curH（dw/dh 比=$voRatio）');
    return true;
  }

  /// 清「校正器等兜底」标记（含撤销安全网定时器）。
  void _clearVsrCorrectorFallback() {
    _vsrCorrectorFallbackPending = false;
    _vsrCorrectorPendingAt = null; // v3.5i（ISS-311）：与 pending 同源生命周期
    _vsrFallbackRearmsLeft = 3;
    _vsrFallbackTimer?.cancel();
    _vsrFallbackTimer = null;
  }

  /// 落 v3.3「Rx 迁就」兜底：**写入成功才清 pending**（v3.5c 复核 C-3——旧实现先清后调，
  /// 兜底静默 return 时标志已消费、Rx 未迁就）。
  void _finishVsrCorrectorFallback() {
    if (!_vsrCorrectorFallbackPending) return;
    if (_applyVsrCorrectorFallback()) {
      _clearVsrCorrectorFallback();
    }
  }

  /// 距最近一次「修因进度」（链写 / 重放）的时长；无锚点 → null。
  Duration? _vsrSinceProgress() => vsrSinceProgressAt(
        chainWriteAt: _lastVsrChainWriteAt,
        lastRepairAt: _vsrLastRepairAt,
        pendingAt: _vsrCorrectorPendingAt, // v3.5i（ISS-311）：兜住跨代际陈旧锚点
        now: DateTime.now(),
      );

  /// 挂「兜底安全网」定时器（v3.5d 复核 P1：回调**复核**是否已应用/是否仍有进展，
  /// 未达则续挂——消除「固定 8s 无条件抢跑」把黑边换成画面变形的风险；写入失败也续挂）。
  void _armVsrFallbackTimer() {
    _vsrFallbackTimer?.cancel();
    // v3.5i（ISS-311）：挂表须**略大于** `maxWait`——`vsrFallbackDue` 用严格 `<`，
    // 恰挂 maxWait 会让首次回调只剩毫秒余量（pendingAt 入 max 后尤甚）→ 永不兜底。
    _vsrFallbackTimer = Timer(
        vsrCorrectorFallbackMaxWait + const Duration(milliseconds: 250), () {
      _vsrFallbackTimer = null;
      if (_playerDisposed || !_vsrCorrectorFallbackPending) return;
      if (vsrFallbackDue(
        chainApplied: _rtxVsrChainApplied,
        crop: _vsrDesiredCrop,
        applied: _voutAppliedCropTarget(),
        correctorPending: true,
        sinceProgress: _vsrSinceProgress(),
        maxWait: vsrCorrectorFallbackMaxWait,
      )) {
        _finishVsrCorrectorFallback();
      }
      if (_vsrCorrectorFallbackPending && _vsrFallbackRearmsLeft > 0) {
        _vsrFallbackRearmsLeft--;
        _armVsrFallbackTimer(); // 未解决 → 续挂（有上限，防无界轮询）
      }
    });
  }

  /// v3.5 C1（统一重放调度器）：crop 未被 VO 应用时的**专用单笔重写**（不走 `_syncRtxVsrCrop`，
  /// 避免按当时 area 重算而连带改写 vf 触发链重建）。**条件式**调度——调用方已确认「新 scale
  /// 帧落定」，此处**立即**写（不再固定延迟猜时机）；成功/失败由 out-params 事件流再判（应用级）。
  /// 有界（预算由调用方递减）；单 token 互斥（修因 / 校正器 / 回读失败三源共用）。
  bool _scheduleVsrCropReplay(String crop) {
    if (crop.isEmpty || !_rtxVsrChainApplied || _playerDisposed) return false;
    if (player.platform is! NativePlayer) return false;
    final token = ++_vsrCropRetryToken;
    final epoch = _vsrRepairEpoch; // v3.5g 复核 P2：闭包内复查代际（防落后回写）
    // 必须在**写锁 Zone 之外**调度：本方法可能在 `_applyVsrTargetUnlocked` 锁体内被调用，
    // 直接 await 会命中 `_withWriteMutex` 的重入短路（不排队）。用 `Zone.root.bindCallback`
    // 转义（与 `_scheduleSuppressRelease` 同款，阶段4 定向复验）。
    Zone.root.bindCallback(() async {
      // 守卫①：代际 + 目标未变（比代际更强，防旧目标被新流覆盖后又重写）。
      if (_playerDisposed || epoch != _vsrRepairEpoch || token != _vsrCropRetryToken) return;
      if (!_rtxVsrChainApplied || _vsrDesiredCrop != crop) return;
      final pp = player.platform;
      if (pp is! NativePlayer) return;
      try {
        // 应用级成功判定：命中即停（不再无谓重写）。
        if (_voutAppliedCropTarget()) {
          Log.d('[VSR] crop 修因已生效（应用级）video-crop=$crop');
          _clearVsrCorrectorFallback();
          return;
        }
        // 先清后写，强制走「属性变更」路径（mpv 对同值 set 是否重求值未证实）。
        await _withWriteMutex(() async {
          // ④ 批次 B（G10 / ISS-300，N5 收敛为单点）：把上方入口守卫（基线 L1291）拷入
          // 写锁闭包**首行**——`_withWriteMutex` 会 await 排队，排队期间可能已换代
          // （新源 open / 新目标重写）；stale 时**连「清写 video-crop=''」一并跳过**
          // （否则旧代际回调会把新目标先清掉 → 黑边复现）。
          if (_playerDisposed ||
              epoch != _vsrRepairEpoch ||
              token != _vsrCropRetryToken) return;
          await pp.setProperty('video-crop', '');
          await pp.setProperty('video-crop', crop);
        });
        // 冷却锚点已在 `_maybeRepairVsrCrop` 发起时置位（v3.5c 复核 B-3）。
      } catch (e) {
        Log.d('[VSR] crop 修因重放异常: $e');
      }
    })();
    return true;
  }

  Future<void> _syncRtxVsrCrop({String trigger = 'sync'}) async {
    // 注：_playerDisposed 在 PlayerMixin 内可直接引用，但此处不依赖它——
    // 播放器已 dispose 时 media_kit 的 setProperty/getProperty 会抛 AssertionError
    // 或 StateError（_checkNativeHandle），由 _enqueueCropWrite 的 catch 兜底。
    if (!Platform.isWindows) return;
    final pp = player.platform;
    if (pp is! NativePlayer) return;
    // ② P3/C4：用**真源**（解码器输出，不受 video-aspect-override 污染），
    // 否则第二次尺寸事件（dw 被 aspect 改写后）会让 plan/签名被污染 → 多余写链。
    final (rawW, rawH) = _trueSourceSize();
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
      curS: _lastRtxVsrScale, // v3.3（P1-6）：滞回需要当前已挂倍数
    );
    final s = plan.scale; // 捕获为 final，便于闭包里做空值提升
    final enable = plan.applied;
    final desired = plan.crop;
    _vsrDesiredCrop = desired; // ② P2：供重试回调做「目标未变」守卫
    // v3.5d 复核 P1：修因布防与目标**原子绑定**（同处赋值）——避免「新 crop + 旧 pairs」窗口
    // 把新 crop 写到旧 scale 帧（根因复现，可 2s 内烧光预算）。crop 空 → 不布防。
    final aspectValue = plan.aspect;
    final renderSize = plan.renderSize;
    // v3.5e 复核 P0：修因布防与目标**同处赋值**（与 `_vsrDesiredCrop` 同函数、同 plan 派生）——
    // 避免「新 crop + 旧 pairs」窗口把新 crop 写到旧 scale 帧（根因复现 + 烧光预算）。
    // crop 空（VSR 关/无补边）→ 不布防。assert 锁住「非空 crop 必有布防」不变量。
    _vsrRepairPairs = desired.isEmpty
        ? null
        : vsrExpectedFramePairs(rawW: rawW, rawH: rawH, scale: s);
    assert(_vsrRepairPairs != null || desired.isEmpty,
        'v3.5：非空 crop 必须有修因布防（pairs）');
    // ② P3/C5：缓存终态显示比例（VSR 生效时），供面板宽一次到位。
    // v3.3（ISS-294 P1-2 守卫）：校正器已按实测比写过 `_vsrDisplayAspect` 时不再重置回
    // 假说比（否则下一次尺寸/布局事件 W3/W4/W5 会用假说比把刚校正的面板宽冲回 → 房B 黑边
    // 复现）；保持实测比直到代际重置（`_resetLastVoutDwh`）。VSR 关（链未挂）时仍正常置 null。
    if (!(_vsrCorrectorFired && _rtxVsrChainApplied)) {
      _vsrDisplayAspect = _rtxVsrChainApplied ? aspectValue : null;
    }
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
        // ③ 批次 B（1.08.84 / ISS-289）：放行前**显式作废**暂存 target（双向作废、含关向；
        // **禁开向重建**、禁加签名回填——R4-3：签名回填恰会触发 L1397/L1400/L1427 短路，
        // 且 L1370-1372 注释明记签名会被 open 清链弄陈旧）。
        // 必需性：`_releaseVsrDeferPlay` 先在 **L1689 快照** `_vsrDeferPlayTarget`，
        // `_disarmVsrDeferPlay` 的置 null 在 **L1668**（由 L1694 调用，**晚于快照**）——
        // 即 disarm 那次置 null 清不掉已快照的旧目标 ⇒ 不在此显式置 null，门控期内早先
        // 暂存的**陈旧目标**会在这条「链路已一致」的 0 等待放行里被取出写链（N4：release
        // 是无条件写链路径，且 `vfAction=='none'` 仍跑 crop/aspect/setSize）。
        // 置 null 后 release 走 L1759 `if (target != null)` 假分支 → L1765
        // `else if (reason == 'timeout')`：本分支 reason 恒 'chain-unchanged' ⇒ 不误触
        // `_preHangFallbackChain` 兕底（R3-4 正面证据）。
        _vsrDeferPlayTarget = null;
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
    final epochAtStart = _vsrRepairEpoch; // v3.5 C1：跨 await 的代际守卫
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
          // 实现复核 R8（P1）：链从无到有（上次摘链后重新挂上，如同代际内 toggle-off→on）
          // 时重臂校正器——否则房B 开向修复哑火到下一代际，违反 Howe「不可退让」红线。
          // 振荡期链恒已挂（scale 非 null）→ 不重臂，防自激一次性语义不破坏。
          if (_lastRtxVsrScale == null) {
            _vsrCorrectorFired = false;
            // v3.5 C1（P2-1/A-3）：链无→有（同代际 off→on）重臂时，修因预算/兜底标记/冷却锚点
            // 同步重置，否则校正器/修因重放哑火。
            // v3.5g 复核 P1：**不得清 `_vsrRepairPairs`**——它由 `_syncRtxVsrCrop` 与
            // `_vsrDesiredCrop` 同源维护；此处清空会盖在「首挂链→settle→写 crop」窗口前，
            // 致冷启动直进房B 时修因永不触发。
            _vsrRepairBudget = 3;
            _clearVsrCorrectorFallback();
            _vsrLastRepairAt = null;
          }
          _lastRtxVsrScale = t.scale;
          _lastVsrChainWriteAt = DateTime.now(); // v3.3：校正器静默门计时点
          Log.d('[VSR] 写入滤镜链 #${++_vsrChainWriteCount}'
              ' scale=${t.scale?.toStringAsFixed(2)}');
        } else {
          await pp.setProperty('vf', '');
          _lastRtxVsrScale = null;
          _lastVsrChainWriteAt = DateTime.now(); // v3.3：校正器静默门计时点（摘链也计）
          Log.d('[VSR] 摘除滤镜链 #${++_vsrChainWriteCount}');
        }
        // v3.5 C2（写链定序）：vf 重建（升档/挂链）后，**等新 scale 的帧在 VO 落定**再下发
        // crop/setSize——否则 crop 会在旧 scale 帧上越界被 mpv 静默丢弃
        // （`Ignoring invalid --video-crop…`）且永不自动重放 → VO 滞留未裁满帧 → contain 黑带。
        // 仅「重挂链（set）+ 有 crop 目标」才等；摘链向 / 无裁源（crop=''）不涉及该竞态，跳过
        // （P2-①）。超时 2s 兜底（双链连写实测落定 ≈2s）、可被新目标 abort。
        if (vfAction == 'set' && t.crop.isNotEmpty && t.scale != null) {
          await _awaitVsrChainSettle(t);
          // v3.5 C1（B-1/F-4 复核项）：等待可长达 2s，期间可能换源/退房（代际自增）或销毁
          // → 复查代际与销毁，避免把旧目标写到新源上（对比重放路径每步都查）。
          if (_playerDisposed || epochAtStart != _vsrRepairEpoch) {
            Log.d('[VSR] 写链定序：等待期间代际已变（disposed=$_playerDisposed'
                ' epoch $epochAtStart→$_vsrRepairEpoch）→ 放弃本次下发');
            return;
          }
        }
      } finally {
        _scheduleSuppressRelease(token);
      }
    }
    await pp.setProperty('video-crop', t.crop);
    // v3.5 C1（D-1 复核项）：crop 写自身也是 await，期间代际可能已变 → 复查后再续写 aspect/setSize/Rx。
    if (_playerDisposed || epochAtStart != _vsrRepairEpoch) {
      Log.d('[VSR] crop 写后：代际已变（epoch $epochAtStart→$_vsrRepairEpoch）→ 跳过剩余下发');
      return;
    }
    // v3.5d 复核 P1：修因布防已与目标原子绑定（见 `_syncRtxVsrCrop`），此处不再重复布防。
    // v3.5 C1（C-1 复核项）：crop 写后刷新静默门锚点——原锚点在 vf 写处，crop 写入后不刷新
    // 会让校正器静默门在 crop 刚写完即满足（超时路径下）。
    _lastVsrChainWriteAt = DateTime.now();
    // ② P4/D0（复验-b 裁定 T2）：`video-aspect-override` 不复写计算出的 16:9——
    // 对带补边源它被 mpv 折算成未裁切帧的 PAR=1.0074 → 裁切区显示尺寸膨胀 3868x2160
    // → contain-fit x 卡 → 上下各 8px 黑边（黑边制造者）。恒写 "no"（=mpv 默认 -2.0，
    // PAR 回 1:1 → 裁切区 3840x2160=窗口 → 满窗无黑边无左右条；对 16:9 源 no-op）。
    // 属性有粘性（上房写过 1.777778 后不写不会复位）→ 每房主动写，含 16:9 源。
    await pp.setProperty('video-aspect-override', 'no');
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
    final (trueW, trueH) = _trueSourceSize();
    if (trueW != t.rawW || trueH != t.rawH) {
      Log.d('[VSR] 尺寸已变（${trueW}x${trueH}'
          ' != ${t.rawW}x${t.rawH}）—— 不回填签名，等下个尺寸事件重算');
      return;
    }
    _lastRtxVsrSignature = t.signature;
    _tlMark('链就绪');
    // 1.08.76 几何修复（EV-464 根因）：VSR 切换不产生尺寸事件 → 面板几何（videoWidthRx/
    // videoHeightRx）滞留旧比例 → 持续黑边。写链完成（签名回填后）按**目标显示比例**刷新
    // 这对 Rx：VSR 开 = t.aspect（16:9 折算）、关 = srcW/srcH（源比，plan.aspect 恒非空
    // 回退）——开/关两方向通吃。必须放在 crop 空早退（`if (t.crop.isEmpty) return;`）**之前**：关方向 crop=''
    // 在此 return，放函数尾会漏关方向。用 t.aspect 而非 `_vsrDisplayAspect`（关时已置
    // null，且它是全局态、队列在途时可能已被后续 sync 更新）。锁内同步赋值、页面 Obx
    // 只读 Rx → 无死锁；不碰 busy/readyGate/pipeline/留痕（零外溢门禁）。
    if (Platform.isWindows && t.rawH > 0) {
      // v3.3（ISS-294）：恢复单一权威源 = t.aspect（crop 目标比例，源尺寸派生、与链输出
      // 无关）——v3.2 的「VO 实测优先」在 write-done 时刻读到的是**上一条链**的输出（时序性
      // 陈旧，真机日志 video=960/967/968 交替的源头之一），是自激闭环主犯；拆除该回灌边。
      // 关向恒 t.aspect=srcW/srcH（与 v3.1 一致，Y2 表 W2 关向本就禁读缓存）。
      // VO→Rx 的唯一入口改为校正器 `_maybeApplyVsrCorrector`（四门一次性，见其注释）。
      videoWidthRx.value = (t.rawH * t.aspect).round();
      videoHeightRx.value = t.rawH;
    }
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
        ' aspectOverride=no（复位 PAR=1:1；面板比例 ${t.aspect.toStringAsFixed(6)}）'
        ' renderSize=${t.renderSize?.$1}x${t.renderSize?.$2}'
        '（源 ${player.state.width}x${player.state.height}）',
      );
    } else {
      Log.w(
        '[VSR] video-crop 未生效：期望 ${t.crop}，回读 "$readback"'
        '（源 ${player.state.width}x${player.state.height}）—— 可能 libmpv 不支持该属性'
        '；应用级修因将在新 scale 落定后重放（C1）',
      );
      // v3.5 C1：应用级修因（_maybeRepairVsrCrop）会在「新 scale 帧落定但仍未应用」时统一重放，
      // 覆盖回读失败场景；此处不再排固定延时重写（旧 250/600/1200ms 猜时机已废除）。
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

  /// 武装「起播门控」（Windows + VSR 开启时，由 initializePlayer 末尾调用；
  /// v3.5i 起 toggle-on 亦复用）。
  void _armVsrDeferPlay() {
    _vsrDeferPlayTimer?.cancel();
    _vsrDeferPlaySettleTimer?.cancel();
    _vsrDeferPlaySettleTimer = null;
    _vsrGateEpoch++;
    _vsrDeferPlayTarget = null;
    _vsrDeferPlayArmedAt = DateTime.now();
    _vsrDeferPlay = true;
    // v3.5i：重置 toggle 相关态（防「toggle-on 后换线路重武装」时旧标志泄漏 → release 误跳 play）。
    _vsrGatePlayOnRelease = true;
    _vsrToggleMaskOn = false;
    _vsrToggleMaskTimer?.cancel();
    _vsrToggleMaskTimer = null;
    _vsrGateIsToggle = false;
    Log.d('[VSR] 门控: 武装 timeout=${vsrDeferPlayTimeout.inMilliseconds}ms');
    _vsrDeferPlayTimer = Timer(vsrDeferPlayTimeout, () {
      // 兜底：拿不到源分辨率（异常流）时不卡住，直接起播（此时可能仍有一次重启，属降级）。
      _releaseVsrDeferPlay('timeout');
    });
  }

  /// v3.5i：toggle 专用遮罩（成对显式开关 + 3s 兜底；不动声音门/就绪门状态机）。
  void _armVsrToggleMask() {
    if (_readyPending) {
      return; // 就绪门遮罩本就在 → 不抢所有权（否则 finish('restart') 会提前掀掉）
    }
    _vsrToggleMaskOn = true;
    showReadyMaskRx.value = true;
    _vsrToggleMaskTimer?.cancel();
    _vsrToggleMaskTimer = Timer(vsrDeferPlayTimeout, () {
      _vsrToggleMaskTimer = null;
      if (_vsrToggleMaskOn) {
        _vsrToggleMaskOn = false;
        showReadyMaskRx.value = false;
      }
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
    // v3.5i：遮罩兜底 timer 同步撤销（不改 `_vsrToggleMaskOn`——release 需据其收遮罩）。
    _vsrToggleMaskTimer?.cancel();
    _vsrToggleMaskTimer = null;
  }

  /// 放开起播门控（② B1 重设计 v3，2026-11-12）：**先 play()（非暂停态）再写链**。
  ///
  /// 原因：写链（vf / video-crop / video-aspect-override）若在**暂停态**下发，mpv 的
  /// `mp_force_video_refresh`（其 seek 条件含 `pause`）会对每笔写各触发一次 refresh seek →
  /// `mp_filter_reset` 把音频链（dynaudnorm+loudnorm）**整个释放重建**，且硬解下强制等 96 帧
  /// 关键帧 —— 这是进房慢的主因。移到 play() 之后（pause=false、time_frame<0.5）即不再 seek。
  /// vsr-off 兜底摘链仍保持「先摘链后放行」（先 play 会使摘链落播放态 → 可见 restart）。
  Future<void> _releaseVsrDeferPlay(String reason) async {
    if (!_vsrDeferPlay) {
      return;
    }
    final epoch = _vsrGateEpoch;
    final armedAt = _vsrDeferPlayArmedAt;
    // 先取出暂存目标（_disarmVsrDeferPlay 会清空它），play 之后单次写链。
    final target = _vsrDeferPlayTarget;
    // v3.5i：与 epoch/armedAt/target **同处快照**（disarm 后无法再读）。
    final playOnRelease = _vsrGatePlayOnRelease;
    final toggleMaskOwned = _vsrToggleMaskOn;
    final isToggle = _vsrGateIsToggle;
    _disarmVsrDeferPlay();
    if (_playerDisposed) {
      return;
    }
    // 门控武装期间的错误抑制窗必与「首次起播」重合，窗口内真错误（403/超时/流下线）会被直接
    // 吞掉。起播这一刻解除抑制，让真错误走正常 mediaError 路径（写链自身会给短窗抑制）。
    // v3.5i：仅**进房语义**解除；toggle 代际不动（防提前解除 toggle 前一笔写链的抑制窗）。
    if (!isToggle) {
      _suppressErrorRetry = false;
    }
    // 守卫①（await 之前）：挡掉「已被 disarm、又被新换源取代」的过期 release。
    if (epoch != _vsrGateEpoch) {
      Log.d('[VSR] 起播门控 release 作废（已有新换源）: $reason');
      return;
    }
    // vsr-off 兜底摘链：保持「先摘链后放行」——先 play 会让摘链落在播放态、画面可见 restart。
    if (reason == 'vsr-off' &&
        _lastRtxVsrScale != null &&
        !_rtxVsrChainApplied) {
      try {
        await _withWriteMutex(() async {
          final pp = player.platform;
          if (pp is NativePlayer) {
            await pp.setProperty('vf', '');
            _lastRtxVsrScale = null;
            _lastVsrChainWriteAt = DateTime.now(); // v3.3：校正器静默门计时点（兜底摘链也计）
            // 1.08.76 几何修复（次点）：此路径不经 `_applyVsrTargetUnlocked`、摘链不产
            // 尺寸事件（日志「无尺寸事件，sync 未写」）→ 门控期热关（T6-③）摘链后同样
            // 刷新面板几何回**源比例**（VSR 已关；经 `_panelAspectSize`，此时
            // `_vsrDisplayAspect`=null → 原样返回源尺寸）。state 未知（0/null）时跳过，
            // 首个尺寸事件自愈（落地门禁②守卫）。
            final (geomW, geomH) =
                _panelAspectSize(player.state.width, player.state.height);
            if (Platform.isWindows && geomW > 0 && geomH > 0) {
              videoWidthRx.value = geomW;
              videoHeightRx.value = geomH;
            }
            Log.d('[VSR] 门控 vsr-off 兜底摘链 #${++_vsrChainWriteCount}（无尺寸事件，sync 未写）');
          }
        });
      } catch (e) {
        Log.d('[VSR] 门控 vsr-off 兜底摘链失败: $e');
      }
    }
    // 守卫②（摘链 await 之后）：期间可能被重武装取代。
    if (_playerDisposed || epoch != _vsrGateEpoch) {
      Log.d('[VSR] 门控 release 作废（摘链期间已被新换源取代）: $reason');
      return;
    }
    // **先 play（非暂停态）再写链**——写链必须在暂停态之外，否则触发 refresh seek。
    // 整个「play + 写链」计入就绪门 busy（② 整改2）；`busy++` 必须在 play() **之前**：
    // 否则 playing 事件（置 _playIssued）可能先到，叠加已记的 restart → 就绪门在写链前就揭。
    _pipelineBusy++;
    try {
      _tlMark('play()');
      Log.d('[VSR] 门控放开（$reason）等待=${armedAt == null ? "?" : "${DateTime.now().difference(armedAt).inMilliseconds}ms"}'
          ' → ${playOnRelease ? "play()" : "跳过 play（武装时停）"}（先播后写链）');
      if (playOnRelease) {
        try {
          await player.play();
        } catch (e) {
          Log.d('[VSR] 起播门控 play() 失败: $e');
        }
      }
      if (!_playerDisposed && epoch == _vsrGateEpoch) {
        if (target != null) {
          // play 后单次写链（P1-1）：门控期吞掉的中间写在放行点一次性写入终值；此时非暂停态，
          // mp_force_video_refresh 不 seek。
          Log.d('[VSR] 门控: play 后单次写链(原因=$reason) scale=${target.scale?.toStringAsFixed(2) ?? '-'}'
              ' crop="${target.crop}" 链=${target.enable}');
          await _applyVsrTarget(target);
        } else if (reason == 'timeout') {
          // 预挂只在超时路径（P1-1）：拿不到源分辨率 → play 后预挂 2.0 兜底链（降级）。
          await _preHangFallbackChain();
        }
      }
    } catch (e) {
      Log.d('[VSR] 门控写链失败: $e');
    } finally {
      _pipelineBusy--;
      _maybeFinishReadyGate();
      // v3.5i：toggle 自有遮罩到此才撤（盖住「play + 单次写链」的过渡）。
      // 实现复核 6c8bc6e C-R2：await 期间若已被换线路重武装（epoch 变）→ 新门控/就绪门接管
      // 遮罩，不得用旧快照提前掀掉（否则一次可见闪烁）。
      if (toggleMaskOwned && !_playerDisposed && epoch == _vsrGateEpoch) {
        _vsrToggleMaskTimer?.cancel();
        _vsrToggleMaskTimer = null;
        _vsrToggleMaskOn = false;
        showReadyMaskRx.value = false;
        Log.d('[VSR] toggle 遮罩撤下');
      }
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
      // 同主写链分支（实现复核 R8 P1）：链从无到有 → 重臂校正器（门控超时兜底等价 off→on）。
      if (_lastRtxVsrScale == null) {
        _vsrCorrectorFired = false;
        // v3.5 C1（A-3 复核项）：预挂兜底是 R8 等价重臂点，预算/兜底标记/冷却锚点同步重置。
        // v3.5g：不清 `_vsrRepairPairs`（由 sync 同源维护，见主写链同处注释）。
        _vsrRepairBudget = 3;
        _clearVsrCorrectorFallback();
        _vsrLastRepairAt = null;
      }
      _lastRtxVsrScale = rtxVsrScale;
      _lastVsrChainWriteAt = DateTime.now(); // v3.3：校正器静默门计时点（预挂兜底也计）
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
            // ⚠️ 优先级（P1-3，阶段4 复核）：VSR 依赖硬解（d3d11vpp 需 D3D11 硬件帧），
            // 故「Windows + VSR 开启」时**强制** d3d11va，忽略「硬解」开关
            // （否则 create 给 'auto'、起流后又强写 d3d11va，两笔异值写序不定 → 矛盾）。
            // 其余情况传 null，走 media_kit 默认（由 enableHardwareAcceleration 决定）。
            hwdec: (Platform.isWindows &&
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
      // ② P4/D0（复验-b）：state.width/height 是 dw/dh（会被 aspect 撑宽）。D0 起
      // mpv 侧 aspect 复位 "no" → dw/dh=1.7647（带补边源）≠ 纹理 16:9 → 用户切
      // 「画面尺寸→适应」按错误比例夹框会出现 ~0.7% 左右细条。改用面板折算比例：
      // _panelAspectSize 在非 Windows / 缓存空时原样返回（行为不变），VSR 生效时
      // 返回与面板一致的 (h*a, h) → 夹框比例与面板宽同源、细条消除。
      final ps = _panelAspectSize(player.state.width, player.state.height);
      aspectRatio = ps.$1 / ps.$2;
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
    final (w, h) = _panelAspectSize(player.state.width, player.state.height);
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
        applyPipelineChange('toggle-norm', vsr: false);
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
      applyPipelineChange('toggle-norm', vsr: false);
    });
    // VSR：直播间接开关即生效（复用音量均衡的热切换范式：worker + 串行队列 + 错误抑制）
    _rtxVsrWorker = ever(AppSettingsController.instance.enableRtxVsr, (bool on) {
      if (_playerDisposed || !Platform.isWindows) {
        return;
      }
      Log.d('[DIAG] 操作: VSR → $on');
      // C3·R2：VSR 热切换的**写链**已委派中枢（`_applyRtxVsrSetting` 内部调
      // `applyPipelineChange('toggle-vsr', …)`）；编排（预置链状态 / 签名清零 /
      // 门控期「先摘链、后放行」）仍由 `_applyRtxVsrSetting` 承担——故本 worker
      // 仍经它进入，不换成纯委派调用。
      // [APPLY] 留痕随 R2 收口进中枢（原散点 `source=toggle-vsr on=$on` 移除；
      // on= 语义由中枢期望行 `VSR=<值>` 覆盖，见实施卡 §四 R2 验收·日志对照豁免声明）。
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
          applyPipelineChange('resume-pending', vsr: false);
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
        // 就绪门：**门控窗口内任何时刻的 restart 完成都记**（② 改序后：VSR 开的路径没有 seek
        // → 管线在暂停期就绪 → restart 完成会落在 play() **之前**，原「仅认 play 之后」会拿不到
        // 信号、只能干等 6s 超时）。「play 已发 + 无在途写入」仍由 readyGateCanFinish 强制，
        // 防「进房期热拨 VSR/seek 被误判就绪」的那道闸还在。
        _readyRestartSeen = true;
        _maybeFinishReadyGate();
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
    // v3 诊断（1.08.75 · 行为零改动）：订阅 VO 侧输出尺寸 + 启动 5s 几何轮询。
    if (!_geomObserving && player.platform is NativePlayer) {
      _geomObserving = true;
      final np = player.platform as NativePlayer;
      unawaited(np
          .observeProperty('video-out-params', (v) async {
            Log.d('[GEOM] event video-out-params=$v');
            _updateLastVoutDwh(v);
          })
          .catchError((e) => Log.d('[GEOM] observeProperty(video-out-params) 失败: $e')));
    }
    _startGeomPoller();
    _widthSubscription = player.stream.width.listen((event) {
      // v3 诊断：尺寸事件是「稳态黑边」定位的关键时点。
      unawaited(_logGeom('size-event w=$event'));
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
        final (pw, ph) =
            _panelAspectSize(player.state.width, player.state.height);
        videoWidthRx.value = pw;
        videoHeightRx.value = ph;
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
        final (pw, ph) =
            _panelAspectSize(player.state.width, player.state.height);
        videoWidthRx.value = pw;
        videoHeightRx.value = ph;
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
    _vsrDisplayAspect = null;
    // v3.2 g1：代际重置 VO 尺寸缓存 + 取消去抖 timer（防 dispose 后写入，g3）。
    _resetLastVoutDwh();
    _vsrCropRetryToken++;
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

  /// 统一「管线应用」入口（P2-2 / 方案 §三 C3）：把**外部**变化（拨开关等）收敛到一个入口，
  /// R1（C3·纯增量）：聚合已应用态——**即时聚合视图**（每次从现字段构造、不复制存储，实施卡 §三/FV3-4）。
  /// 只读、无副作用；字段与 §二 状态字段一一对应（PARITY 锚点见实施卡 §五.2 映射表）。
  PipelineApplied _aggregateApplied() => PipelineApplied(
        volumeNormApplied: _volumeNormApplied,
        rtxVsrChainApplied: _rtxVsrChainApplied,
        lastRtxVsrScale: _lastRtxVsrScale,
        vsrDesiredCrop: _vsrDesiredCrop,
        vsrDisplayAspect: _vsrDisplayAspect,
        lastRtxVsrSignature: _lastRtxVsrSignature,
        gateArmed: _vsrDeferPlay,
      );

  /// R1（C3·纯增量）：构造期望态——只读开关/能力/播放器事实，与 pc.dart 决策路径同源
  /// （镜像层，非独立期望源）。`_trueSourceSize` 取自 player.state（中枢入口已有
  /// `_playerDisposed` 早退）；area 门控同 `_syncRtxVsrCrop`（仅链已应用时取），
  /// `_playerAreaPhysicalSize` 自带 try-catch 安全网（队列外调用有 `_diagSnapshot` 先例）。
  PipelineDesired _buildDesired() {
    final (srcW, srcH) = _trueSourceSize();
    final chainApplied = _rtxVsrChainApplied;
    final area = chainApplied ? _playerAreaPhysicalSize() : null;
    return PipelineDesired(
      volumeNormUserOn: AppSettingsController.instance.volumeNorm.value,
      vsrUserOn: AppSettingsController.instance.enableRtxVsr.value,
      isWindows: Platform.isWindows,
      srcW: srcW,
      srcH: srcH,
      areaW: area?.$1,
      areaH: area?.$2,
      afLoudnormSupported: PlayerMixin.afLoudnormSupported,
      vsrGateApplicable: _vsrGateApplicable,
    );
  }

  /// 统一留痕 `[APPLY] source=`（期望态 vs 已应用态）。
  ///
  /// 设计取舍（守既有语义，不重写已验证逻辑）：
  /// - 两条队列**保持分离**（C3 硬约束），本入口只做「留痕 + 委派」到 _syncVolumeNorm / _syncRtxVsrCrop；
  /// - **队列内**调用点（首帧钩子 / 探测终裁）仍直接调无队版（ISS-281 修复要求，见各自注释），
  ///   不入本入口——这是**有意的例外**，不是漏。
  /// - ⚠️ 默认 `norm && vsr` 会**顺序 await 两条队列**；仅在确需同时应用时给双 true，
  ///   否则按需传 `vsr: false` / `norm: false`（避免 af 长操作挡住 vf，违背 §8.2 硬约束）。
  Future<void> applyPipelineChange(String source,
      {bool norm = true, bool vsr = true}) async {
    if (_playerDisposed) {
      return;
    }
    Log.d('[APPLY] source=$source 期望: 均衡=${AppSettingsController.instance.volumeNorm.value}'
        '（已挂=$_volumeNormApplied 能力=${PlayerMixin.afLoudnormSupported}）'
        ' VSR=${Platform.isWindows && AppSettingsController.instance.enableRtxVsr.value}'
        '（链=$_rtxVsrChainApplied scale=${_lastRtxVsrScale?.toStringAsFixed(2) ?? "-"}）');
    // R1（C3·纯增量）：期望/已应用聚合 → 纯 diff 留痕。
    // [APPLY-diff] 为新增行，不影响现有 [APPLY] 行格式；**仅描述不驱动**——
    // 不做任何短路/跳过，委派保持无条件（实施卡 §三 三条例证）。
    final r1Desired = _buildDesired();
    final r1Applied = _aggregateApplied();
    final r1Change = pipelineDiff(r1Desired, r1Applied);
    final r1ChangeNote = r1Change.normEnable == null
        ? '${r1Change.normAction.name}'
        : '${r1Change.normAction.name}(enable=${r1Change.normEnable})';
    Log.d('[APPLY-diff] source=$source diff: norm=$r1ChangeNote'
        ' vsr=${r1Change.vsrIntent?.action ?? "-"}'
        '${r1Change.vsrIntent?.deferred ?? false ? ' (deferred)' : ''}'
        ' gateApplicable=${r1Desired.vsrGateApplicable}'
        ' | ${serializeApplied(r1Desired, r1Applied)}');
    if (norm) {
      await _syncVolumeNorm();
    }
    if (vsr && Platform.isWindows) {
      await _syncRtxVsrCrop(trigger: source);
    }
    if (!_playerDisposed) {
      Log.d('[APPLY] source=$source 结果: 均衡已挂=$_volumeNormApplied'
          ' 链=$_rtxVsrChainApplied scale=${_lastRtxVsrScale?.toStringAsFixed(2) ?? "-"}');
    }
  }

  /// ① 批次 B（1.08.84 / C3 R3）：`PlayerMixin._tracePipelinePreApply` 的实现——
  /// 将进房预挂的留痕委派给统一中枢，**固定 `norm: false, vsr: false`**（留痕 only）：
  /// 下方两个委派条件均不成立 ⇒ 体内**零播放器 I/O、零真 await**（不碰 probe / 不碰抑制窗 /
  /// 不碰 `set af`，M1/N3）；预挂写点仍由 `initializePlayer` 原位执行（一字不动）。
  @override
  Future<void> _tracePipelinePreApply(String source) =>
      applyPipelineChange(source, norm: false, vsr: false);

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
        await _withWriteMutex(() => pp.setProperty('af', volumeNormFilter));
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
        await _withWriteMutex(() => pp.setProperty('af', ''));
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
  ///
  /// C3·R2：**写链**委派统一入口 `applyPipelineChange`（中枢留痕 + 无条件委派）；
  /// 本函数的编排职责与判据（链状态预置 / 签名清零 / 门控期先摘链后放行）一字不变。
  Future<void> _applyRtxVsrSetting() async {
    if (_playerDisposed || !Platform.isWindows) return;
    final pp = player.platform;
    if (pp is! NativePlayer) return;
    final enabled = AppSettingsController.instance.enableRtxVsr.value;
    unawaited(_logGeom('toggle-vsr-entry user=$enabled'));
    _rtxVsrChainApplied = enabled;
    // 强制重算（开关变化必须重挂/摘链）。
    _lastRtxVsrSignature = null;
    // v3.5i（1.08.81 A⁗）：toggle-on 复用起播门控吞写 → 面板重排后单笔写链（消「双重建」）。
    // 三动作：(a) Rx 预写（面板一步到位）(b) 短 defer 门控 (c) 自有遮罩。
    // 前置 `!_vsrDeferPlay`（轮3 必修）：进房门控在途时不重武装（否则进房 release 被 epoch 作废 +
    // 下方 play 守卫被误跳 → 起播死锁）；门控本已吞写存目标，进房 release 照常 play + 补写。
    // 守 `enabled`（轮4 必修）：本函数是开关共用入口，漏 enabled 会让 toggle-**off** 也武装门控。
    final armToggleGate = enabled && Platform.isWindows && !_vsrDeferPlay;
    if (armToggleGate) {
      // (a) Rx 预写：终态显示比纯源尺寸派生（与播放区无关）；尊重校正器守卫（同写链处）。
      if (!(_vsrCorrectorFired && _rtxVsrChainApplied)) {
        final (srcW, srcH) = _trueSourceSize();
        final aspect = rtxVsrDisplayAspect(srcW, srcH);
        if (aspect != null) {
          _vsrDisplayAspect = aspect;
          final (pw, ph) =
              _panelAspectSize(player.state.width, player.state.height);
          if (pw > 0 && ph > 0) {
            videoWidthRx.value = pw;
            videoHeightRx.value = ph;
            Log.d('[VSR] toggle 预写面板几何: Rx=${pw}x$ph'
                ' aspect=${aspect.toStringAsFixed(6)}');
          }
        } else {
          Log.d('[VSR] toggle 预写跳过（无终态比）');
        }
      } else {
        Log.d('[VSR] toggle 预写跳过（校正器已按实测比写过）');
      }
    }
    // 复核（复验 P3）：门控正武装着（等尺寸事件挂链）时热关 VSR → 没有链可等，别白等超时兜底
    // （最长 3s 黑屏）；但必须**先摘链、后放行**——media_kit 的 play/setProperty 同走一把锁 FIFO，
    // 若先 play()，摘链就落在播放态 → mpv 又一次 playback restart（正是门控要避免的「出画面又重载」）。
    // 此刻还在暂停态，先摘链不可见；摘完再放行，顺带消掉「放行到摘链之间」的错误抑制空窗。
    final releaseGateAfterSync = !enabled && _vsrDeferPlay;
    // 注：**不清 `_lastRtxVsrScale`**——它是「mpv 实际已挂链」的唯一记录，摘链判断依赖它非空；
    // 在决定动作前清空会导致关闭时永不摘链→绿条复现（阶段4 复核 P0）。
    // hwdec 与错误抑制由 `_syncRtxVsrCrop` 内部统一处理。
    if (armToggleGate) {
      _armVsrDeferPlay(); // 重置 _vsrGatePlayOnRelease=true / _vsrGateIsToggle=false
      // 仅「武装时在播」才恢复 play()（防强制恢复暂停）；但**进房/换源在途**（就绪门武装中，
      // 宿主可能正以 open(play:false) 待起播）必须 play，否则无人起播（实现复核 6c8bc6e B-R1）。
      _vsrGatePlayOnRelease = player.state.playing || _readyPending;
      _vsrGateIsToggle = true;
      _armVsrToggleMask(); // (c) 遮罩（_readyPending 时自动跳过）
      Log.d('[VSR] toggle 武装短门控（武装时在播=$_vsrGatePlayOnRelease）');
    }
    try {
      // C3·R2：写链委派中枢（原直调 `_syncRtxVsrCrop(trigger: 'toggle')`）。
      // trigger 仅用于日志、无分支判定（RV-6 实证）→ source='toggle-vsr' 行为等价。
      // 中枢内为无条件委派、不短路（实施卡 §三）；norm 侧不涉及故传 false。
      // 日志注记：本路径在委派前已预置 `_rtxVsrChainApplied`（函数开头的既有预置，非本次新增），
      // 故中枢期望行的「链=」是**目标链状态**而非实际已挂状态；实际结果由中枢
      // 同步后的结果行如实输出（与 pipelineDiff 的 plan 入参同源，镜像不失真）。
      await applyPipelineChange('toggle-vsr', norm: false, vsr: true);
    } catch (e) {
      Log.d('[VSR] 热切换失败: $e');
    }
    unawaited(_logGeom('toggle-vsr-write-done user=$enabled'));
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
