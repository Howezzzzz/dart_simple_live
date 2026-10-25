import 'dart:io';

import 'package:dio/dio.dart';
import 'package:material_ui/material_ui.dart';
import 'package:get/get.dart';
import 'package:url_launcher/url_launcher_string.dart';

import '../../app/app_style.dart';
import '../../app/log.dart';
import '../../app/utils.dart';
import '../../models/version_model.dart';
import '../../services/update_downloader.dart';

/// 更新流程页面：**普通页面 route** 走完「发现新版本 → 下载进度 → 安装 → 完成/失败」。
///
/// 2026-10-20 两轮修复背景：
/// - v1.8.24 前：点「更新」在弹窗间 Get.back()+Get.dialog 切换，路由竞争 → 弹窗内容不渲染，
///   用户只看到全屏遮罩（灰屏）；v1.8.24 改为单弹窗状态机（UpdateFlowDialog）；
/// - Howe 实测 v1.08.25 **仍是灰屏** → 判定弹窗（dialog route + barrier）在该 App 存在
///   系统性渲染兼容问题（SmartDialog.observer 等叠加）。**最终方案：弃用弹窗，改全屏页面**
///   （页面 route 与 App 普通页面同一渲染路径，无 barrier/遮罩问题），下载全程可见。
/// - 流程每步写 Log（Log.d），异常可在 App 内 Debug 日志页定位。
class UpdateFlowPage extends StatefulWidget {
  const UpdateFlowPage({super.key, required this.version});

  final VersionModel version;

  @override
  State<UpdateFlowPage> createState() => _UpdateFlowPageState();
}

enum _Stage { confirm, downloading, permission, success, failed }

class _UpdateFlowPageState extends State<UpdateFlowPage> {
  final _stage = ValueNotifier<_Stage>(_Stage.confirm);
  final _status = ValueNotifier<String>('正在挑选最快线路…');
  final _progress = ValueNotifier<double>(-1);
  final _lineName = ValueNotifier<String>('');
  CancelToken? _cancelToken;
  var _closing = false;
  var _settingsPending = false;

  /// 已下载的安装包路径（Android 权限引导后自动续装用）。
  String? _downloadedPath;

  VersionModel get _v => widget.version;

  @override
  void dispose() {
    // 侧键/任何绕过 PopScope 的路径关页时，终止未完成下载（防孤儿下载 + dispose 后写 notifier）
    _cancelToken?.cancel();
    _stage.dispose();
    _status.dispose();
    _progress.dispose();
    _lineName.dispose();
    super.dispose();
  }

  // ---------- 流程 ----------

  Future<void> _startDownload() async {
    if (_stage.value == _Stage.downloading) return; // 防双击「更新/重试」起两条并发下载流
    _stage.value = _Stage.downloading;
    _status.value = '正在挑选最快线路…';
    _progress.value = -1;
    _lineName.value = '';
    _cancelToken = CancelToken();
    final cancelToken = _cancelToken!;
    Log.d('[更新] 开始下载流程 v${_v.version}（version_num=${_v.versionNum}）');

    // 清单没有本平台直链（如 iOS 未签名包）→ 本平台不支持自动更新：引导用浏览器打开 Releases 页
    if (!UpdateDownloader.hasPlatformDirectLink(_v)) {
      _status.value = '本平台暂不支持自动更新，请用浏览器打开下载页';
      _stage.value = _Stage.failed;
      Log.d('[更新] 本平台无直链（${UpdateDownloader.platformKey()}），引导浏览器');
      return;
    }

    // 清单声明了哈希、却没给我们平台的 → 视为异常，拒装（不静默跳过校验）
    final expect = UpdateDownloader.expectedSha256(_v);
    if (expect == null && _v.downloadSha256.isNotEmpty) {
      UpdateDownloader.reportVerifyFailure('missing_platform_hash');
      _status.value = '清单缺少本平台安装包校验值，已拒绝安装';
      _stage.value = _Stage.failed;
      Log.w('[更新] 拒装：清单缺少本平台 sha256');
      return;
    }

    try {
      final candidates = UpdateDownloader.buildCandidates(_v);
      Log.d('[更新] 候选线路 ${candidates.length} 条');
      final ranked = await UpdateDownloader.rankBySpeed(candidates, cancelToken: cancelToken);
      Log.d('[更新] 测速完成，线路顺序：${ranked.length} 条');
      var lastError = '未知错误';
      for (var i = 0; i < ranked.length; i++) {
        if (cancelToken.isCancelled) return;
        final url = ranked[i];
        final isDirect = url == candidates.first;
        _lineName.value = '线路 ${i + 1}/${ranked.length}'
            '${isDirect ? '（官方直链）' : '（镜像）'}';
        _status.value = '正在下载…';
        _progress.value = 0;
        Log.d('[更新] 开始下载 线路${i + 1}/${ranked.length}：$url');
        try {
          final path = await UpdateDownloader.download(
            url,
            cancelToken: cancelToken,
            expectedSha256: expect,
            onProgress: (got, total) {
              if (!mounted) return; // 页面已被关（侧键等）→ 不再写已 dispose 的 notifier
              if (total > 0) _progress.value = got / total;
            },
          );
          if (cancelToken.isCancelled) return;
          _progress.value = 1;
          _status.value = '下载完成，正在打开安装器…';
          Log.d('[更新] 下载完成：$path');
          await _launchInstaller(path);
          return;
        } on DioException catch (e) {
          if (CancelToken.isCancel(e)) {
            Log.d('[更新] 下载已取消');
            // 页面已在 _cancel() 里关闭，这里只需停止循环
            return;
          }
          lastError = e.message ?? '网络错误';
          Log.w('[更新] 线路${i + 1} 失败：${e.message}（type=${e.type}）');
        } catch (e) {
          lastError = e.toString();
          Log.w('[更新] 线路${i + 1} 异常：$e');
        }
      }
      if (!mounted) return;
      _status.value = '下载失败：$lastError';
      _stage.value = _Stage.failed;
    } catch (e) {
      if (!mounted) return;
      _status.value = '下载失败：$e';
      _stage.value = _Stage.failed;
      Log.w('[更新] 流程异常：$e');
    }
  }

  /// 打开安装器；Android 未开「允许安装未知应用」→ 转权限引导阶段。
  Future<void> _launchInstaller(String path) async {
    try {
      await UpdateDownloader.openInstaller(path);
      if (!mounted) return;
      _stage.value = _Stage.success;
      Log.d('[更新] 安装器已启动');
    } on UpdateInstallPermissionException {
      _downloadedPath = path;
      if (!mounted) return;
      _status.value = '安装前需要开启“允许安装未知应用”';
      _stage.value = _Stage.permission;
      Log.d('[更新] 需要开启「允许安装未知应用」');
    } catch (e) {
      if (!mounted) return;
      _status.value = '打开安装包失败：$e';
      _stage.value = _Stage.failed;
      Log.w('[更新] 打开安装器失败：$e');
    }
  }

  /// 去系统设置开启权限；用户返回后自动续装。
  Future<void> _openSettingAndContinue() async {
    if (_settingsPending) return; // 防 await 挂起期间重复点击（标志位早退，非禁用按钮）
    _settingsPending = true;
    try {
      Log.d('[更新] 跳转系统设置开启安装权限');
      await UpdateDownloader.openUnknownAppSourcesSetting();
      if (!mounted) return;
      final can = await UpdateDownloader.canRequestPackageInstalls();
      if (!mounted) return;
      if (can) {
        Log.d('[更新] 权限已开启，自动续装');
        final path = _downloadedPath;
        if (path != null) {
          await _launchInstaller(path);
        } else {
          // 理论不可达：无已下载包 → 退回重下
          _startDownload();
        }
      } else {
        _status.value = '还未开启“允许安装未知应用”，开启后请再点一次「去开启」';
        Log.d('[更新] 返回后权限仍未开启');
      }
    } finally {
      _settingsPending = false;
    }
  }

  void _cancel() {
    _cancelToken?.cancel();
    _close();
  }

  /// 关闭页面（防抖：退出动画期间按钮仍可点，二次调用会误关底层页面）。
  /// 另兜底「系统返回先发生、pop 过渡中再点按钮」的双重 pop：route 已非 current 时直接忽略。
  void _close() {
    if (_closing) return;
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return;
    _closing = true;
    Get.back();
  }

  // ---------- UI ----------

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<_Stage>(
      valueListenable: _stage,
      builder: (context, stage, _) {
        final canClose = stage != _Stage.downloading && stage != _Stage.permission;
        return PopScope(
          canPop: canClose,
          child: Scaffold(
            appBar: AppBar(
              title: Text(_title(stage)),
              centerTitle: true,
              automaticallyImplyLeading: false,
              leading: canClose
                  ? IconButton(
                      icon: const Icon(Icons.arrow_back),
                      onPressed: _close,
                    )
                  : null,
            ),
            body: SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 8),
                    _versionCard(),
                    const SizedBox(height: 24),
                    Expanded(child: _content(stage)),
                    _actions(stage),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// 版本信息卡片：当前版本 → 新版本。
  Widget _versionCard() {
    return Card(
      elevation: 0,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('当前版本', style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
                  const SizedBox(height: 2),
                  Text(Utils.formatVersion(Utils.packageInfo.version),
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                ],
              ),
            ),
            Icon(Icons.arrow_forward, color: Theme.of(context).colorScheme.onSurfaceVariant),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text('新版本', style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
                  const SizedBox(height: 2),
                  Text(Utils.formatVersion(_v.version),
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _title(_Stage stage) {
    switch (stage) {
      case _Stage.confirm:
        return '发现新版本';
      case _Stage.downloading:
        return '正在更新';
      case _Stage.permission:
        return '需要安装权限';
      case _Stage.success:
        return '更新完成';
      case _Stage.failed:
        return '更新失败';
    }
  }

  Widget _content(_Stage stage) {
    switch (stage) {
      case _Stage.confirm:
        return SingleChildScrollView(
          child: Text(
            _v.versionDesc,
            style: const TextStyle(fontSize: 14, height: 1.6),
          ),
        );
      case _Stage.downloading:
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ValueListenableBuilder<String>(
              valueListenable: _status,
              builder: (context, msg, _) => Text(msg, style: const TextStyle(fontSize: 15)),
            ),
            const SizedBox(height: 16),
            ValueListenableBuilder<double>(
              valueListenable: _progress,
              builder: (context, p, _) => LinearProgressIndicator(
                value: p < 0 ? null : p,
                minHeight: 6,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
            const SizedBox(height: 12),
            ValueListenableBuilder<String>(
              valueListenable: _lineName,
              builder: (context, n, _) => Text(
                n,
                style: TextStyle(fontSize: 12, height: 1.4, color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ),
          ],
        );
      case _Stage.permission:
        return ValueListenableBuilder<String>(
          valueListenable: _status,
          builder: (context, msg, _) => Text(
            '$msg\n\n请到系统设置中允许本应用「安装未知应用」，\n开启后会自动继续安装。',
            style: const TextStyle(fontSize: 14, height: 1.6),
          ),
        );
      case _Stage.success:
        return Text(
          _successText,
          style: const TextStyle(fontSize: 14, height: 1.6),
        );
      case _Stage.failed:
        return SingleChildScrollView(
          child: ValueListenableBuilder<String>(
            valueListenable: _status,
            builder: (context, msg, _) => Text(msg, style: const TextStyle(fontSize: 14, height: 1.5)),
          ),
        );
    }
  }

  String get _successText {
    if (Platform.isWindows) {
      return '安装程序已启动，请在安装向导中继续完成更新。\n\n安装完成后重新打开本应用即可使用新版本。';
    }
    if (Platform.isAndroid) {
      return '安装程序已启动，请在系统安装界面点击「安装」完成更新。';
    }
    return '安装程序已打开，请按提示完成更新。';
  }

  Widget _actions(_Stage stage) {
    switch (stage) {
      case _Stage.confirm:
        return Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _close,
                child: const Text('取消'),
              ),
            ),
            AppStyle.hGap12,
            Expanded(
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(elevation: 0),
                onPressed: _startDownload,
                child: const Text('更新'),
              ),
            ),
          ],
        );
      case _Stage.downloading:
        return Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _cancel,
                child: const Text('取消下载'),
              ),
            ),
          ],
        );
      case _Stage.permission:
        return Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _close,
                child: const Text('稍后再说'),
              ),
            ),
            AppStyle.hGap12,
            Expanded(
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(elevation: 0),
                onPressed: _openSettingAndContinue,
                child: const Text('去开启'),
              ),
            ),
          ],
        );
      case _Stage.success:
        return Row(
          children: [
            Expanded(
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(elevation: 0),
                onPressed: _close,
                child: const Text('完成'),
              ),
            ),
          ],
        );
      case _Stage.failed:
        return Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _startDownload,
                child: const Text('重试'),
              ),
            ),
            AppStyle.hGap12,
            Expanded(
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(elevation: 0),
                onPressed: () => launchUrlString(
                  UpdateDownloader.resolveDownloadUrl(_v),
                  mode: LaunchMode.externalApplication,
                ),
                child: const Text('用浏览器下载'),
              ),
            ),
          ],
        );
    }
  }
}
