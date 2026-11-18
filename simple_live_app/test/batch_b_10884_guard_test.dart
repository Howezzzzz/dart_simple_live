import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 批次 B（1.08.84 / C3 R3 合批）回归守卫：C-1 / C-2 / C-3 / C-4 的**源码级**断言
/// （§11.4 R3-3 / §11.5 R4 回归面 / §11.6 S5-3、S5-4）。
///
/// 为何是静态断言：PlayerController / LiveRoomController 依赖 Flutter binding +
/// media_kit native assets，无法建运行时单测（仓内惯例：no_credential_logging_test.dart
/// 同款「静态扫描即失败」）。运行时行为（刷新真实发起、回落顺序、门控放行）=
/// 真机/日志判据，见交付说明——本文件只锁「结构在，改了就红」。
void main() {
  final lrc =
      File('lib/modules/live_room/live_room_controller.dart').readAsStringSync();
  final pctl = File('lib/modules/live_room/player/player_controls.dart')
      .readAsStringSync();
  final pc =
      File('lib/modules/live_room/player/player_controller.dart').readAsStringSync();

  /// 去掉整行注释（// 与 ///），供计数类断言用。
  String stripComments(String src) => src
      .split('\n')
      .where((l) => !l.trimLeft().startsWith('//'))
      .join('\n');

  /// 按签名取方法体（含签名；括号感知——命名参数里的 `{...}` 不是方法体开头；
  /// 字符串插值 `${}` 成对出现，不影响配平）。未找到 / 未闭合 → 抛错（测试红）。
  String body(String src, String signature) {
    final i = src.indexOf(signature);
    expect(i, greaterThanOrEqualTo(0), reason: '未找到签名: $signature');
    var parenDepth = 0;
    for (var j = i; j < src.length; j++) {
      final c = src[j];
      if (c == '(') parenDepth++;
      if (c == ')') parenDepth--;
      if (c == '{' && parenDepth == 0) {
        // 方法体开括号：从这里开始花括号配平。
        var depth = 0;
        for (var k = j; k < src.length; k++) {
          if (src[k] == '{') depth++;
          if (src[k] == '}') {
            depth--;
            if (depth == 0) return src.substring(i, k + 1);
          }
        }
        break; // 方法体未闭合 → 落到末尾抛错
      }
    }
    throw StateError('方法体未闭合或签名后无方法体: $signature');
  }

  group('C-1（②）每源预算：复位面 4 入口 + 「预算写点仅 7 处」grep 反例', () {
    test('预算字段在声明处给初值 1（§11.6 A-1）', () {
      expect(
          lrc.contains(
              'int _playUrlRefreshBudget = kPlayUrlRefreshBudgetPerSource;'),
          isTrue,
          reason: '冷启动走 getPlayQualities→getPlayUrl，不经任何复位点 ⇒ 初值必须在声明处');
      expect(lrc.contains('const int kPlayUrlRefreshBudgetPerSource = 1;'),
          isTrue);
    });

    test('预算写点（赋值）恰好 7 处：声明 1 + 消耗 2（mediaEnd/mediaError）+ 复位 4', () {
      final src = stripComments(lrc);
      final writes =
          RegExp(r'_playUrlRefreshBudget\s*(?:-=|=)').allMatches(src).length;
      expect(writes, 7,
          reason: '写点多于 7 = 有人加了自复位（无界循环风险）；少于 7 = 复位面缺失');
      expect(RegExp(r'_playUrlRefreshBudget\s*==').hasMatch(src), isFalse,
          reason: '预算不做 == 比较（消耗语义只有 >0 / -=）');
    });

    test('反例：getPlayUrl / initPlaylist 体内不得复位预算（自复位 = 无界）', () {
      final getPlayUrlBody = body(lrc, 'Future<bool> getPlayUrl() async {');
      final initPlaylistBody = body(lrc, 'void initPlaylist() async {');
      expect(getPlayUrlBody.contains('_playUrlRefreshBudget'), isFalse);
      expect(initPlaylistBody.contains('_playUrlRefreshBudget'), isFalse);
      // pc 全文不得出现预算字段（库私有，initializePlayer 结构上无法复位——钉死防挪）
      expect(pc.contains('_playUrlRefreshBudget'), isFalse);
    });

    test('复位面 4 入口：changePlayLine(userInitiated) / refreshRoom / switchQuality / onClose',
        () {
      final changeLine = body(lrc,
          'void changePlayLine(int index, {bool userInitiated = false}) {');
      expect(changeLine.contains('if (userInitiated) {'), isTrue,
          reason: 'R3-1：仅用户主动换线复位');
      expect(
          changeLine.indexOf('if (userInitiated) {') <
              changeLine.indexOf('_playUrlRefreshBudget ='),
          isTrue,
          reason: '复位必须在 userInitiated 分支内');
      expect(body(lrc, 'void refreshRoom() {').contains('_playUrlRefreshBudget ='),
          isTrue);
      expect(
          body(lrc, 'Future<void> switchQuality(int index) async {')
              .contains('_playUrlRefreshBudget ='),
          isTrue);
      expect(body(lrc, 'void onClose() {').contains('_playUrlRefreshBudget ='),
          isTrue);
    });

    test('换线路调用点：用户入口传 true（2 处）、自动换线不传（2 处）', () {
      // 自动换线（mediaEnd / mediaError 遍历线路）必须不传——复位即无界（R3-1 P0）
      expect(
          RegExp(r'changePlayLine\(currentLineIndex \+ 1\);')
              .allMatches(lrc)
              .length,
          2,
          reason: 'mediaEnd/mediaError 的自动换线各 1 处，不得带 userInitiated');
      expect(
          lrc.contains(
              'changePlayLine(currentLineIndex + 1, userInitiated: true)'),
          isFalse);
      // 用户入口
      expect(lrc.contains('changePlayLine(e ?? 0, userInitiated: true);'),
          isTrue, reason: 'lrc showPlayUrlsSheet 用户换线路');
      expect(
          pctl.contains('controller.changePlayLine(i, userInitiated: true);'),
          isTrue,
          reason: 'player_controls.showLinesInfo 用户换线路（R4-1）');
    });

    test('切清晰度两入口统一走 switchQuality（R4-1：第二入口漏了则桌面端不复位）', () {
      expect(lrc.contains('await switchQuality(e ?? 0);'), isTrue,
          reason: 'lrc showQualitySheet');
      expect(pctl.contains('controller.switchQuality(i);'), isTrue,
          reason: 'player_controls.showQualitesInfo（不经 lrc sheet 的第二入口）');
      expect(pctl.contains('controller.currentQuality = i;'), isFalse,
          reason: '旧直写路径必须已移除');
    });
  });

  group('C-2（①）进房预挂留痕 only：异常隔离 + cap==null 不开抑制窗', () {
    test('旧 [APPLY] 行保留、留痕调用在其后、写点在其前（R4-2 时序）', () {
      final oldLog =
          "Log.d('[APPLY] source=room-enter/reinit 均衡预挂（已挂=\$_volumeNormApplied'";
      final preapply =
          "await _tracePipelinePreApply('room-enter/reinit-preapply');";
      final writePoint = 'await _enqueueVolumeNorm(() => _preApplyVolumeNorm());';
      final iOld = pc.indexOf(oldLog);
      final iPre = pc.indexOf(preapply);
      final iWrite = pc.indexOf(writePoint);
      expect(iOld, greaterThanOrEqualTo(0), reason: '旧行保留不删（N3：删即丢动作词）');
      expect(iPre, greaterThan(iOld), reason: '留痕在旧 [APPLY] 行之后');
      expect(iWrite, greaterThan(iPre), reason: '写点在留痕之后（R3-2 乱序担忧）');
    });

    test('try-catch 只包留痕、不包写点（R4-2：留痕异常不得静默丢预挂）', () {
      final iPre =
          pc.indexOf("await _tracePipelinePreApply('room-enter/reinit-preapply');");
      final iWrite =
          pc.indexOf('await _enqueueVolumeNorm(() => _preApplyVolumeNorm());');
      final between = pc.substring(iPre, iWrite);
      expect(between.contains('} catch (e) {'), isTrue,
          reason: '留痕调用必须在 try-catch 内');
      expect(between.contains('_enqueueVolumeNorm'), isFalse,
          reason: '写点必须留在 try-catch 之外');
      expect(between.contains('留痕异常'), isTrue, reason: '留痕异常要留痕（不静默吞）');
    });

    test('委派固定 norm:false / vsr:false ⇒ 体内零播放器 I/O（M1/N3：不碰 probe/抑制窗/set af）',
        () {
      expect(
          RegExp(
              r'Future<void> _tracePipelinePreApply\(String source\) =>\s*applyPipelineChange\(source, norm: false, vsr: false\);')
              .hasMatch(pc),
          isTrue,
          reason: '覆写实现必须固定留痕 only 参数');
    });
  });

  group('C-3（③）chain-unchanged：放行前显式作废暂存 target', () {
    test('显式置 null 紧贴 release 之前（ISS-289）', () {
      expect(
          RegExp(
              r"_vsrDeferPlayTarget = null;\s*_releaseVsrDeferPlay\('chain-unchanged'\);")
              .hasMatch(pc),
          isTrue,
          reason: 'L1689 快照晚于 L1668 disarm 置 null ⇒ 显式置 null 是必需的');
    });

    test('release 结构未被破坏：target!=null 才写链、兜底仅 timeout（R3-4 正面证据）', () {
      final rel = body(
          pc, "Future<void> _releaseVsrDeferPlay(String reason) async {");
      expect(rel.contains('final target = _vsrDeferPlayTarget;'), isTrue);
      expect(rel.contains('if (target != null) {'), isTrue);
      expect(rel.contains("} else if (reason == 'timeout') {"), isTrue,
          reason: 'target=null 后走假分支 ⇒ chain-unchanged 不误触 _preHangFallbackChain');
      expect(rel.contains('await _applyVsrTarget(target);'), isTrue,
          reason: '同值 sync 的正常写链路径仍在（C-3 运行时面的源码锚点）');
    });

    test('禁开向重建 / 禁签名回填（N4 / R4-3）', () {
      final iNull =
          pc.indexOf("_vsrDeferPlayTarget = null;\n        _releaseVsrDeferPlay");
      expect(iNull, greaterThanOrEqualTo(0));
      final region = pc.substring(iNull, pc.indexOf('return;', iNull));
      expect(region.contains('_VsrTarget('), isFalse, reason: '禁开向重建');
      expect(region.contains('_lastRtxVsrSignature'), isFalse, reason: '禁签名回填');
    });
  });

  group('C-4（②）刷新失败回落 + 无未捕获异步异常（S5-1 / S5-2）', () {
    test('getPlayUrl 返回 Future<bool>：空址早退 false、成功 true', () {
      final b = body(lrc, 'Future<bool> getPlayUrl() async {');
      final iEmpty = b.indexOf('if (playUrl.urls.isEmpty) {');
      final iFalse = b.indexOf('return false;');
      final iTrue = b.indexOf('return true;');
      expect(iEmpty, greaterThanOrEqualTo(0));
      expect(iFalse, greaterThan(iEmpty), reason: '空址早退 → false（S5-1）');
      expect(iTrue, greaterThan(iFalse), reason: '成功 → true');
    });

    test('mediaEnd / mediaError：预算消耗在 count<2 分支之前、call-site try-catch 全覆盖',
        () {
      for (final sig
          in ['void mediaEnd() async {', 'void mediaError(String error) async {']) {
        final b = body(lrc, sig);
        final iBudget = b.indexOf('if (_playUrlRefreshBudget > 0) {');
        final iConsume = b.indexOf('_playUrlRefreshBudget -= 1;');
        final iTry = b.indexOf('try {');
        final iAwait = b.indexOf('await getPlayUrl();');
        final iCatch = b.indexOf('} catch (e) {');
        final iCount = b.indexOf('if (mediaErrorRetryCount < 2) {');
        expect(iBudget, greaterThanOrEqualTo(0), reason: '$sig 缺预算消耗点');
        expect(iConsume, greaterThan(iBudget));
        expect(iCount, greaterThan(iBudget),
            reason: '$sig：消耗点必须写死在 count<2 分支之前（R4-4，分支内 = no-op）');
        expect(iTry, greaterThan(iConsume), reason: '$sig 缺 call-site try（S5-2 强制项）');
        expect(iAwait, greaterThan(iTry));
        expect(iCatch, greaterThan(iAwait),
            reason: '$sig：getPlayUrl 内 qualities[currentQuality]/detail.value! 可抛，'
                'void…async 未捕获即未捕获异步异常');
      }
    });

    test('成功才 return、失败回落（S5-1：刷新失败不得静默死端）', () {
      for (final sig
          in ['void mediaEnd() async {', 'void mediaError(String error) async {']) {
        final b = body(lrc, sig);
        final iRefreshed = b.indexOf('if (refreshed) {');
        final iReturn = b.indexOf('return;', iRefreshed);
        final iCount = b.indexOf('if (mediaErrorRetryCount < 2) {');
        expect(iRefreshed, greaterThanOrEqualTo(0), reason: '$sig 缺成功分支');
        expect(iReturn, greaterThan(iRefreshed));
        expect(iCount, greaterThan(iReturn),
            reason: '$sig：失败必须落回既有 setPlayer 重试 + 线路遍历');
      }
    });

    test('P1（实现复核轮1）：刷新失败必须回写 index/lineInfo（getPlayUrl 置 index=-1 不恢复 ⇒ 回落会以 -1 执行 = 静默死端变体）',
        () {
      for (final sig
          in ['void mediaEnd() async {', 'void mediaError(String error) async {']) {
        final b = body(lrc, sig);
        final iConsume = b.indexOf('_playUrlRefreshBudget -= 1;');
        final iSnap = b.indexOf('final prevLineIndex = currentLineIndex;');
        final iTry = b.indexOf('try {', iConsume);
        final iRefreshed = b.indexOf('if (refreshed) {');
        final iRestore = b.indexOf('currentLineIndex = prevLineIndex;');
        final iCount = b.indexOf('if (mediaErrorRetryCount < 2) {');
        expect(iSnap, greaterThan(iConsume), reason: '$sig：快照须在消耗后、await 前');
        expect(iTry, greaterThan(iSnap));
        expect(iRestore, greaterThan(iRefreshed),
            reason: '$sig：回写须在「成功即 return」之后（**仅失败才回写**）');
        expect(iCount, greaterThan(iRestore),
            reason: '$sig：回写必须早于回落重试/末线判据（getPlayUrl 置 index=-1 不恢复）');
        expect(b.contains('currentLineInfo.value = prevLineInfo;'), isTrue,
            reason: '$sig：lineInfo 同步回写（否则 UI 停在线路字串）');
      }
    });

    test('P3（复核轮2/轮3）：回写带 `currentLineIndex < 0` 守卫（勿覆盖并发用户换线/切清晰度）',
        () {
      for (final sig
          in ['void mediaEnd() async {', 'void mediaError(String error) async {']) {
        final b = body(lrc, sig);
        final iConsume = b.indexOf('_playUrlRefreshBudget -= 1;');
        final iGuard = b.indexOf('if (currentLineIndex < 0) {', iConsume);
        final iRestore = b.indexOf('currentLineIndex = prevLineIndex;');
        expect(iGuard, greaterThanOrEqualTo(0), reason: '$sig 缺 P3 守卫（轮3 建议）');
        expect(iRestore, greaterThan(iGuard), reason: '$sig：回写必须在守卫体内');
      }
    });

    test('S5-4 diff 断言：lrc mediaError 的 super.mediaEnd() 笔误行不动（pc 方法体为空 ⇒ 零行为差）',
        () {
      final b = body(lrc, 'void mediaError(String error) async {');
      expect(b.contains('super.mediaEnd();'), isTrue,
          reason: '基线行为（含笔误）按台账理由保留，不做「顺手修复」');
    });

    test('S5-4 diff 断言：_enqueueCropWrite 未加代际校验（N5 收敛为单点）', () {
      final b = body(
          pc, 'Future<void> _enqueueCropWrite(Future<void> Function() task) {');
      expect(b.contains('_vsrCropRetryToken'), isFalse);
      expect(b.contains('_vsrRepairEpoch'), isFalse);
    });

    test('S5-4 diff 断言：simple_live_tv_app/ 零改动（TV 端同族缺陷显式不入本批）', () {
      final tv = File(
          '../simple_live_tv_app/lib/modules/live_room/live_room_controller.dart');
      expect(tv.existsSync(), isTrue, reason: 'TV 端控制器路径存在性（防目录重组后静默漏检）');
      final src = tv.readAsStringSync();
      expect(src.contains('_playUrlRefreshBudget'), isFalse);
      expect(src.contains('userInitiated'), isFalse);
      expect(src.contains('switchQuality'), isFalse);
      expect(src.contains('Future<bool> getPlayUrl'), isFalse);
    });
  });

  group('⑤ Rx 守卫抽纯函数 + ④ G10（C-5 配套源码断言）', () {
    test('合取式字面量已不复存在，两处均调用 vsrDisplayAspectWritable', () {
      expect(pc.contains('!(_vsrCorrectorFired && _rtxVsrChainApplied)'), isFalse,
          reason: '抽出后原式不得残留（防一处改一处漏）');
      expect(
          RegExp(r'vsrDisplayAspectWritable\(\s*correctorFired: _vsrCorrectorFired,')
              .allMatches(pc)
              .length,
          2,
          reason: '恰好两个调用点（_syncRtxVsrCrop 缓存路径 + _applyRtxVsrSetting toggle 预写）');
    });

    test('G10（④）：写锁闭包首行复查代际/token，且在 video-crop 清写之前', () {
      final b = body(pc, 'bool _scheduleVsrCropReplay(String crop) {');
      final iMutex = b.indexOf('await _withWriteMutex(() async {');
      final iGuard = b.indexOf('if (_playerDisposed ||', iMutex);
      final iClear = b.indexOf("await pp.setProperty('video-crop', '');", iMutex);
      expect(iMutex, greaterThanOrEqualTo(0));
      expect(iGuard, greaterThan(iMutex), reason: '守卫拷入闭包首行');
      expect(iClear, greaterThan(iGuard),
          reason: '守卫必须在清写之前（stale 连清写一并跳过）');
    });
  });
}
