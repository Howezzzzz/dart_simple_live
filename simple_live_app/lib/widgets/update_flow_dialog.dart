import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:url_launcher/url_launcher_string.dart';

import '../app/app_style.dart';
import '../models/version_model.dart';
import '../services/update_downloader.dart';

/// 更新流程对话框：**单个 route 内**走完「发现新版本 → 下载进度 → 安装 → 完成/失败」。
///
/// 2026-10-20 修复（Howe 反馈「点更新 → 全屏灰屏 → 回窗口」）：原实现是点「更新」时
/// `Get.back()` 关闭确认弹窗，再 `Future.microtask(() => UpdateDownloader.start())`
/// `Get.dialog()` 弹新窗——pop 动画未结束就 push，新弹窗内容渲染不出来，只剩全屏遮罩
/// （视觉灰屏）。这里改为**同一个对话框内状态切换**，从结构上消除路由竞争。
class UpdateFlowDialog extends StatefulWidget {
  const UpdateFlowDialog({super.key, required this.version});

  final VersionModel version;

  @override
  State<UpdateFlowDialog> createState() => _UpdateFlowDialogState();
}

enum _Stage { confirm, downloading, permission, success, failed }

class _UpdateFlowDialogState extends State<UpdateFlowDialog> {
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
    _stage.dispose();
    _status.dispose();
    _progress.dispose();
    _lineName.dispose();
    super.dispose();
  }

  // ---------- 流程 ----------

  Future<void> _startDownload() async {
    _stage.value = _Stage.downloading;
    _status.value = '正在挑选最快线路…';
    _progress.value = -1;
    _lineName.value = '';
    _cancelToken = CancelToken();
    final cancelToken = _cancelToken!;

    // 清单声明了哈希、却没给我们平台的 → 视为异常，拒装（不静默跳过校验）
    final expect = UpdateDownloader.expectedSha256(_v);
    if (expect == null && _v.downloadSha256.isNotEmpty) {
      UpdateDownloader.reportVerifyFailure('missing_platform_hash');
      _status.value = '清单缺少本平台安装包校验值，已拒绝安装';
      _stage.value = _Stage.failed;
      return;
    }

    try {
      final candidates = UpdateDownloader.buildCandidates(_v);
      final ranked = await UpdateDownloader.rankBySpeed(candidates);
      var lastError = '未知错误';
      for (var i = 0; i < ranked.length; i++) {
        if (cancelToken.isCancelled) return;
        final url = ranked[i];
        final isDirect = url == candidates.first;
        _lineName.value = '线路 ${i + 1}/${ranked.length}'
            '${isDirect ? '（官方直链）' : '（镜像）'}';
        _status.value = '正在下载…';
        _progress.value = 0;
        try {
          final path = await UpdateDownloader.download(
            url,
            cancelToken: cancelToken,
            expectedSha256: expect,
            onProgress: (got, total) {
              if (total > 0) _progress.value = got / total;
            },
          );
          if (cancelToken.isCancelled) return;
          _progress.value = 1;
          _status.value = '下载完成，正在打开安装器…';
          await _launchInstaller(path);
          return;
        } on DioException catch (e) {
          if (CancelToken.isCancel(e)) {
            // 对话框已在 _cancel() 里关闭，这里只需停止循环
            return;
          }
          lastError = e.message ?? '网络错误';
        } catch (e) {
          lastError = e.toString();
        }
      }
      if (!mounted) return;
      _status.value = '下载失败：$lastError';
      _stage.value = _Stage.failed;
    } catch (e) {
      if (!mounted) return;
      _status.value = '下载失败：$e';
      _stage.value = _Stage.failed;
    }
  }

  /// 打开安装器；Android 未开「允许安装未知应用」→ 转权限引导阶段。
  Future<void> _launchInstaller(String path) async {
    try {
      await UpdateDownloader.openInstaller(path);
      if (!mounted) return;
      _stage.value = _Stage.success;
    } on UpdateInstallPermissionException {
      _downloadedPath = path;
      if (!mounted) return;
      _status.value = '安装前需要开启“允许安装未知应用”';
      _stage.value = _Stage.permission;
    } catch (e) {
      if (!mounted) return;
      _status.value = '打开安装包失败：$e';
      _stage.value = _Stage.failed;
    }
  }

  /// 去系统设置开启权限；用户返回后自动续装。
  Future<void> _openSettingAndContinue() async {
    if (_settingsPending) return; // 防双击重入：await 挂起期间按钮禁用
    _settingsPending = true;
    try {
      await UpdateDownloader.openUnknownAppSourcesSetting();
      if (!mounted) return;
      final can = await UpdateDownloader.canRequestPackageInstalls();
      if (!mounted) return;
      if (can) {
        final path = _downloadedPath;
        if (path != null) {
          await _launchInstaller(path);
        } else {
          // 理论不可达：无已下载包 → 退回重下
          _startDownload();
        }
      } else {
        _status.value = '还未开启“允许安装未知应用”，开启后请再点一次「去开启」';
      }
    } finally {
      _settingsPending = false;
    }
  }

  /// 关闭对话框（防抖：弹窗退出动画期间按钮仍可点，二次调用会误关底层页面路由）。
  void _close() {
    if (_closing) return;
    _closing = true;
    Get.back();
  }

  void _cancel() {
    _cancelToken?.cancel();
    _close();
  }

  // ---------- UI ----------

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<_Stage>(
      valueListenable: _stage,
      builder: (context, stage, _) {
        return PopScope(
          // 下载/权限引导中禁止返回键/点外关闭；其余阶段可关
          canPop: stage != _Stage.downloading && stage != _Stage.permission,
          child: AlertDialog(
            title: Text(
              _title(stage),
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 18),
            ),
            content: _content(stage),
            actionsPadding: AppStyle.edgeInsetsH12,
            actions: _actions(stage),
          ),
        );
      },
    );
  }

  String _title(_Stage stage) {
    switch (stage) {
      case _Stage.confirm:
        return '发现新版本 ${_v.version}';
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
        return Text(
          _v.versionDesc,
          style: const TextStyle(fontSize: 14, height: 1.4),
        );
      case _Stage.downloading:
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ValueListenableBuilder<String>(
              valueListenable: _status,
              builder: (context, msg, _) => Text(msg, style: const TextStyle(fontSize: 14)),
            ),
            const SizedBox(height: 12),
            ValueListenableBuilder<double>(
              valueListenable: _progress,
              builder: (context, p, _) => LinearProgressIndicator(
                value: p < 0 ? null : p,
              ),
            ),
            const SizedBox(height: 8),
            ValueListenableBuilder<String>(
              valueListenable: _lineName,
              builder: (context, n, _) => Text(
                n,
                style: const TextStyle(fontSize: 12, height: 1.4),
              ),
            ),
          ],
        );
      case _Stage.permission:
        return ValueListenableBuilder<String>(
          valueListenable: _status,
          builder: (context, msg, _) => Text(
            '$msg\n\n请到系统设置中允许本应用「安装未知应用」，\n开启后会自动继续安装。',
            style: const TextStyle(fontSize: 14, height: 1.5),
          ),
        );
      case _Stage.success:
        return Text(
          _successText,
          style: const TextStyle(fontSize: 14, height: 1.5),
        );
      case _Stage.failed:
        return SingleChildScrollView(
          child: ValueListenableBuilder<String>(
            valueListenable: _status,
            builder: (context, msg, _) => Text(msg, style: const TextStyle(fontSize: 14, height: 1.4)),
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

  List<Widget> _actions(_Stage stage) {
    switch (stage) {
      case _Stage.confirm:
        return [
          Row(
            children: [
              Expanded(
                child: TextButton(
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
          ),
        ];
      case _Stage.downloading:
        return [
          Row(
            children: [
              Expanded(
                child: TextButton(
                  onPressed: _cancel,
                  child: const Text('取消'),
                ),
              ),
            ],
          ),
        ];
      case _Stage.permission:
        return [
          Row(
            children: [
              Expanded(
                child: TextButton(
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
          ),
        ];
      case _Stage.success:
        return [
          Row(
            children: [
              Expanded(
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(elevation: 0),
                  onPressed: _close,
                  child: const Text('完成'),
                ),
              ),
            ],
          ),
        ];
      case _Stage.failed:
        return [
          Row(
            children: [
              Expanded(
                child: TextButton(
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
          ),
        ];
    }
  }
}
