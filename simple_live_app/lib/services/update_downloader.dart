import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher_string.dart';

import '../app/log.dart';
import '../models/version_model.dart';
import '../requests/common_request.dart';

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

  /// 当前平台在清单里的键（android/windows/macos/linux/ios）。
  static String platformKey() {
    if (Platform.isAndroid) return 'android';
    if (Platform.isWindows) return 'windows';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isLinux) return 'linux';
    if (Platform.isIOS) return 'ios';
    return '';
  }

  /// 选出该平台要下载的文件直链：优先分平台直链，缺失则回落 `download_url`（releases 页）。
  static String resolveDownloadUrl(VersionModel v) {
    final u = v.downloadUrls[platformKey()];
    if (u != null && u.isNotEmpty) return u;
    return v.downloadUrl;
  }

  /// 该平台安装包的预期 sha256（缺失/为空则返回 null → 跳过校验）。
  static String? expectedSha256(VersionModel v) {
    final h = v.downloadSha256[platformKey()];
    return (h != null && h.isNotEmpty) ? h.toLowerCase() : null;
  }

  /// 实际生效的镜像前缀：**清单自报值与硬编码白名单求交**；交集为空则用白名单。
  ///
  /// 阶段 4 复核 P0 修复：清单里的 `mirror_prefixes` 是**自报字段**，只校验 download_url 而放行它，
  /// 等于给「可信 download_url + 伪造 mirror_prefixes」留了绕过后门——故一律不采信白名单之外的前缀。
  static List<String> effectiveMirrorPrefixes(VersionModel v) {
    final fromManifest = v.mirrorPrefixes
        .where(CommonRequest.trustedMirrorPrefixes.contains)
        .toList();
    return fromManifest.isEmpty
        ? CommonRequest.trustedMirrorPrefixes
        : fromManifest;
  }

  /// 构造候选线路：**直链在前，镜像按前缀依次拼接**；去重、过滤空值。
  ///
  /// 镜像为「前缀式」（如 `https://gh-proxy.com/https://github.com/...`），且只允许白名单内前缀。
  static List<String> buildCandidates(VersionModel v) {
    final direct = resolveDownloadUrl(v);
    final out = <String>[];
    void add(String u) {
      if (u.isEmpty || out.contains(u)) return;
      // 下载侧也复检：只有通过可信校验的 URL 才会进候选（防清单来自旁路/缓存时失守）
      if (!CommonRequest.isTrustedUrl(u)) return;
      out.add(u);
    }

    add(direct);
    for (final prefix in effectiveMirrorPrefixes(v)) {
      final p = prefix.trim();
      if (p.isEmpty) continue;
      add(p.endsWith('/') ? '$p$direct' : '$p/$direct');
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

  /// 下载到临时目录；可选 sha256 校验（不匹配则删文件并抛错）。返回本地文件路径。
  static Future<String> download(
    String url, {
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
    String? expectedSha256,
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
    if (expectedSha256 != null) {
      await verifySha256(path, expectedSha256);
    }
    return path;
  }

  /// 校验失败上报（本地日志 + Analytics 计数）：便于发现真实的「换包/投毒」事件。
  ///（第四轮复核建议：没有这个计数，被换包了也只能看到用户「更新失败」。）
  static void reportVerifyFailure(String reason) {
    try {
      Log.w("更新校验失败：$reason", false);
    } catch (_) {}
    // 注意：logEvent 返回 Future，异步错误不会被 try/catch 捕获 → 单独包一层
    _logEventSafe("update_verify_failed", {"reason": reason});
  }

  static Future<void> _logEventSafe(
      String name, Map<String, Object> params) async {
    try {
      await FirebaseAnalytics.instance.logEvent(name: name, parameters: params);
    } catch (_) {
      // 上报失败不影响升级主流程
    }
  }

  /// 校验已下载文件的 sha256；不匹配则**删文件并抛错**（调用方不会拿到 path → 不会拉起安装器）。
  /// [expected] 为 null 时跳过校验（兼容无该字段的旧清单）。
  static Future<void> verifySha256(String path, String? expected) async {
    if (expected == null) return;
    final actual = await sha256OfFile(path);
    if (actual.toLowerCase() != expected.toLowerCase()) {
      reportVerifyFailure("sha256_mismatch");
      await File(path).delete().catchError((_) => File(path));
      throw const UpdateDownloadException(
          "安装包校验失败（sha256 不匹配），已丢弃，请重试或改用浏览器下载");
    }
  }

  /// 流式算文件 sha256（不把整包读进内存）。
  static Future<String> sha256OfFile(String path) async {
    final sink = _DigestSink();
    final conv = sha256.startChunkedConversion(sink);
    await for (final chunk in File(path).openRead()) {
      conv.add(chunk);
    }
    conv.close();
    final d = sink.value;
    if (d == null) throw const UpdateDownloadException("无法计算安装包校验值");
    return d.toString();
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
      // 清单声明了哈希、却没给我们平台的 → 视为异常，拒装（不静默跳过校验）
      final hashes = v.downloadSha256;
      final expect = expectedSha256(v);
      if (expect == null && hashes.isNotEmpty) {
        reportVerifyFailure("missing_platform_hash");
        throw const UpdateDownloadException(
            "清单缺少本平台安装包校验值，已拒绝安装（请改用浏览器下载）");
      }
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
            expectedSha256: expect,
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

/// 下载/校验相关异常（与 CancelToken 取消区分开）。
class UpdateDownloadException implements Exception {
  const UpdateDownloadException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 只收单个 Digest 的 Sink（配合 sha256.startChunkedConversion 流式算哈希）。
class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}
