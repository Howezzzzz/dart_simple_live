import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher_string.dart';

import '../models/version_model.dart';

/// 应用内更新下载器：**多线路（官方直链 + 镜像）测速择优 → 下载 → 拉起系统安装器**。
///
/// 2026-10-20 Howe 定：直链与镜像链接都给，**谁快用谁**；某条线路失败自动切下一条，
/// 全挂了才回落「用浏览器打开」。
class UpdateDownloader {
  UpdateDownloader._();

  /// 测速时每条线路试探的字节数（够判断速度，又不浪费流量）。
  static const int probeBytes = 128 * 1024;

  /// 单条线路测速超时。
  static const Duration probeTimeout = Duration(seconds: 8);

  /// 选出该平台要下载的文件直链：优先分平台直链，缺失则回落 `download_url`（releases 页）。
  static String resolveDownloadUrl(VersionModel v) {
    final m = v.downloadUrls;
    if (m.isNotEmpty) {
      String? pick(bool ok, String key) =>
          ok && (m[key]?.isNotEmpty ?? false) ? m[key] : null;
      final platform = pick(Platform.isAndroid, 'android') ??
          pick(Platform.isWindows, 'windows') ??
          pick(Platform.isMacOS, 'macos') ??
          pick(Platform.isLinux, 'linux') ??
          pick(Platform.isIOS, 'ios');
      if (platform != null) return platform;
    }
    return v.downloadUrl;
  }

  /// 构造候选线路：**直链在前，镜像按前缀依次拼接**；去重、过滤空值。
  ///
  /// 镜像为「前缀式」（如 `https://gh-proxy.com/https://github.com/...`）。
  static List<String> buildCandidates(VersionModel v) {
    final direct = resolveDownloadUrl(v);
    final out = <String>[];
    void add(String u) {
      if (u.isNotEmpty && !out.contains(u)) out.add(u);
    }

    add(direct);
    for (final p in v.mirrorPrefixes) {
      final prefix = p.trim();
      if (prefix.isEmpty) continue;
      add(prefix.endsWith('/') ? '$prefix$direct' : '$prefix/$direct');
    }
    return out;
  }

  /// 并发探测各线路，按**实测速度降序**返回；探测失败的排在最后（仍作为兜底尝试）。
  static Future<List<String>> rankBySpeed(
    List<String> urls, {
    int probeBytes = UpdateDownloader.probeBytes,
    Duration timeout = UpdateDownloader.probeTimeout,
  }) async {
    if (urls.length <= 1) return List<String>.of(urls);
    final dio = Dio(BaseOptions(
      connectTimeout: timeout,
      receiveTimeout: timeout,
      followRedirects: true,
      validateStatus: (c) => c != null && c >= 200 && c < 400,
    ));
    final speed = <String, double>{};

    await Future.wait(urls.map((u) async {
      final sw = Stopwatch()..start();
      try {
        // 不支持 Range 的站点会返回 200 全量：靠 receiveTimeout 兜住，别把大文件全拉下来。
        final r = await dio.get<List<int>>(
          u,
          options: Options(
            responseType: ResponseType.bytes,
            headers: {'Range': 'bytes=0-${probeBytes - 1}'},
          ),
        );
        sw.stop();
        final bytes = r.data?.length ?? 0;
        final sec = sw.elapsedMicroseconds / 1000000.0;
        speed[u] = bytes > 0 ? bytes / (sec <= 0 ? 0.001 : sec) : -1;
      } catch (_) {
        speed[u] = -1;
      }
    }));

    final usable = urls.where((u) => (speed[u] ?? -1) > 0).toList()
      ..sort((a, b) => (speed[b] ?? 0).compareTo(speed[a] ?? 0));
    final unusable = urls.where((u) => (speed[u] ?? -1) <= 0).toList();
    return <String>[...usable, ...unusable];
  }

  /// 下载到临时目录，返回本地文件路径。
  static Future<String> download(
    String url, {
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final dir = await getTemporaryDirectory();
    var name = Uri.parse(url).pathSegments.isNotEmpty
        ? Uri.parse(url).pathSegments.last
        : 'slive_update';
    if (!name.contains('.')) name = '$name.bin';
    final path = '${dir.path}/$name';
    final f = File(path);
    if (await f.exists()) {
      await f.delete().catchError((_) => f);
    }
    await Dio().download(
      url,
      path,
      cancelToken: cancelToken,
      onReceiveProgress: onProgress,
      options: Options(
        followRedirects: true,
        receiveTimeout: const Duration(minutes: 30),
      ),
    );
    return path;
  }

  /// 拉起系统安装器打开已下载的安装包（Android .apk / Windows .exe / macOS .dmg / Linux 包）。
  static Future<void> openInstaller(String path) async {
    await OpenFilex.open(path);
  }

  /// 全流程 + 进度弹窗：测速 → 下载 → 打开安装器；失败回落浏览器。
  static Future<void> start(VersionModel v) async {
    final candidates = buildCandidates(v);
    final status = ValueNotifier<String>('正在挑选最快线路…');
    final progress = ValueNotifier<double>(-1);
    final lineName = ValueNotifier<String>('');
    final failed = ValueNotifier<bool>(false);
    final cancelToken = CancelToken();
    var closed = false;

    void safeClose() {
      if (closed) return;
      closed = true;
      Get.back();
    }

    Get.dialog<void>(
      barrierDismissible: false,
      PopScope(
        canPop: false,
        child: AlertDialog(
          title: const Text('正在更新', textAlign: TextAlign.center),
          content: ValueListenableBuilder<String>(
            valueListenable: status,
            builder: (context, msg, _) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(msg, style: const TextStyle(fontSize: 14)),
                  const SizedBox(height: 12),
                  ValueListenableBuilder<double>(
                    valueListenable: progress,
                    builder: (context, p, _) => LinearProgressIndicator(
                      value: p < 0 ? null : p,
                    ),
                  ),
                  const SizedBox(height: 8),
                  ValueListenableBuilder<String>(
                    valueListenable: lineName,
                    builder: (context, n, _) => Text(
                      n,
                      style: const TextStyle(fontSize: 12, height: 1.4),
                    ),
                  ),
                  ValueListenableBuilder<bool>(
                    valueListenable: failed,
                    builder: (context, isFail, _) => isFail
                        ? const Padding(
                            padding: EdgeInsets.only(top: 8),
                            child: Text('可改用浏览器下载',
                                style: TextStyle(fontSize: 12)),
                          )
                        : const SizedBox.shrink(),
                  ),
                ],
              );
            },
          ),
          actionsPadding: const EdgeInsets.symmetric(horizontal: 12),
          actions: [
            Row(
              children: [
                Expanded(
                  child: TextButton(
                    onPressed: () {
                      if (!cancelToken.isCancelled) cancelToken.cancel();
                      safeClose();
                    },
                    child: const Text('取消'),
                  ),
                ),
                ValueListenableBuilder<bool>(
                  valueListenable: failed,
                  builder: (context, isFail, _) => isFail
                      ? Expanded(
                          child: TextButton(
                            onPressed: () => launchUrlString(
                              resolveDownloadUrl(v),
                              mode: LaunchMode.externalApplication,
                            ),
                            child: const Text('用浏览器下载'),
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
              ],
            ),
          ],
        ),
      ),
    );

    try {
      final ranked = await rankBySpeed(candidates);
      for (var i = 0; i < ranked.length; i++) {
        final url = ranked[i];
        final isDirect = url == candidates.first;
        lineName.value = '线路 ${i + 1}/${ranked.length}'
            '${isDirect ? '（官方直链）' : '（镜像）'}';
        status.value = '正在下载…';
        progress.value = 0;
        try {
          final path = await download(
            url,
            cancelToken: cancelToken,
            onProgress: (got, total) {
              if (total > 0) progress.value = got / total;
            },
          );
          progress.value = 1;
          status.value = '下载完成，正在打开安装器…';
          await openInstaller(path);
          safeClose();
          return;
        } on DioException catch (e) {
          if (CancelToken.isCancel(e)) {
            safeClose();
            return;
          }
          // 该线路失败 → 试下一条
        } catch (_) {
          // 非 Dio 异常（如落盘失败）→ 也当作该线路失败，试下一条
        }
      }
      status.value = '下载失败';
      failed.value = true;
    } catch (_) {
      status.value = '下载失败';
      failed.value = true;
    }
  }
}
