import 'dart:ffi';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:ffi/ffi.dart';
import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

import '../app/log.dart';
import '../models/version_model.dart';
import '../requests/common_request.dart';

/// 应用内更新下载器：**多线路（官方直链 + 镜像）测速择优 → 下载 → 拉起系统安装器**。
///
/// 2026-10-20 Howe 定：直链与镜像链接都给，**谁快用谁**；某条线路失败自动切下一条，
/// 全挂了才回落「用浏览器打开」。
///
/// 2026-10-20 改：进度弹窗/流程编排移出本类（见 `modules/update_flow/update_flow_page.dart`），
/// 本类专注下载引擎 + 打开安装器（平台分支与权限处理）。
class UpdateDownloader {
  /// Android「允许安装未知应用」检查 / 设置页跳转通道（见 MainActivity.kt）。
  static const MethodChannel _installerChannel = MethodChannel('slive/installer');
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

  /// 清单是否声明了本平台直链：没有 = 本平台不支持自动更新（如 iOS 未签名包），
  /// 应引导用浏览器打开 Releases 页，而不是把列表页 HTML 当安装包下载。
  static bool hasPlatformDirectLink(VersionModel v) {
    final u = v.downloadUrls[platformKey()];
    return u != null && u.isNotEmpty;
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
    final norm = <String>[];
    for (final p in v.mirrorPrefixes) {
      final t = p.trim();
      if (t.isEmpty) continue;
      // 宽容一点：清单里没带结尾 '/' 也算白名单内的同一个前缀（否则会白丢一条线路）
      final withSlash = t.endsWith('/') ? t : '$t/';
      if (CommonRequest.trustedMirrorPrefixes.contains(withSlash)) {
        norm.add(withSlash);
      }
    }
    return norm.isEmpty ? CommonRequest.trustedMirrorPrefixes : norm;
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
  ///
  /// [cancelToken]：用户取消（点「取消」/侧键关页）时透传给探测请求，令在飞的测速
  /// 立即中断而不必等满 timeout（ISS-161/168；取消后各请求抛 cancel → 被下方 catch 记 -1，
  /// 函数照常返回，调用方的 `isCancelled` 检查会阻止后续下载）。
  static Future<List<String>> rankBySpeed(
    List<String> urls, {
    int probeBytes = UpdateDownloader.probeBytes,
    Duration timeout = UpdateDownloader.probeTimeout,
    CancelToken? cancelToken,
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
          cancelToken: cancelToken,
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

  /// 下载更新包到临时目录。支持 **HTTP Range 断点续传**（ISS-162）：
  ///
  /// - **断点按内容隔离**：`expectedSha256` 非空时，落盘到 `slive_dl_<sha前8位>/` 子目录。
  ///   不同版本 → 不同 sha → 不同目录，**旧版本残留的半截包不可能拼进新版本**（关键：
  ///   Android 资产名 `app-arm64-v8a-release.apk` 不带版本号，不能以文件名为断点键）。
  /// - **无 sha 不续传**：`expectedSha256 == null` 时保持旧行为（整包重下）——没有校验值就
  ///   无法判定拼接结果，绝不允许盲拼。
  /// - **服务器不支持 Range**（回 200 全量）→ 自动退化为从头重下。
  /// - 收尾沿用 [verifySha256]（不匹配 → 删文件 + 抛 [UpdateDownloadException]）。
  static Future<String> download(
    String url, {
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
    String? expectedSha256,
  }) async {
    final dir = await getTemporaryDirectory();
    var name = Uri.parse(url).pathSegments.isNotEmpty ? Uri.parse(url).pathSegments.last : 'slive_update';
    if (!name.contains('.')) name = '$name.bin';

    // 断点以「内容 sha」为键，跨版本结构隔离；无 sha 则不建断点目录、不续传。
    final shaKey = (expectedSha256 ?? '').trim().toLowerCase();
    final resumableBySha = shaKey.isNotEmpty;
    final folder = resumableBySha ? '${dir.path}/slive_dl_${shaKey.substring(0, 8)}' : dir.path;
    final path = '$folder/$name';
    final f = File(path);
    if (!await f.parent.exists()) {
      await f.parent.create(recursive: true);
    }
    final existing = resumableBySha && await f.exists() ? await f.length() : 0;

    // 有断点就带 Range 请求续传
    final resp = await Dio().get<ResponseBody>(
      url,
      cancelToken: cancelToken,
      options: Options(
        responseType: ResponseType.stream,
        followRedirects: true,
        receiveTimeout: const Duration(minutes: 30),
        headers: existing > 0 ? {'Range': 'bytes=$existing-'} : null,
        validateStatus: (c) => c != null && (c == 200 || c == 206),
      ),
    );

    // 仅当「有断点 且 服务器真的给了 206」才追加；否则（200 全量）从头覆盖，绝不盲拼。
    final append = existing > 0 && resp.statusCode == 206;
    final offset = append ? existing : 0;
    // 总大小：206 → Content-Range 的 TOTAL；其余 → offset + Content-Length。
    int total = -1;
    final cr = resp.headers.value('content-range');
    if (append && cr != null) {
      final m = RegExp(r'bytes\s+\d+-\d+/(\d+|\*)').firstMatch(cr);
      total = m == null ? -1 : (int.tryParse(m.group(1)!) ?? -1);
    }
    if (total < 0) {
      final n = int.tryParse(resp.headers.value('content-length') ?? '');
      if (n != null) total = offset + n;
    }

    final sink = f.openWrite(mode: append ? FileMode.append : FileMode.write);
    var received = offset;
    try {
      onProgress?.call(received, total);
      await for (final chunk in resp.data!.stream) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }
    } finally {
      try {
        await sink.close();
      } catch (_) {
        // 关闭失败（取消/断流）不应掩盖原始异常；成功路径的落盘问题由下方 sha 校验兜底
      }
    }

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

  static Future<void> _logEventSafe(String name, Map<String, Object> params) async {
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
      throw const UpdateDownloadException("安装包校验失败（sha256 不匹配），已丢弃，请重试或改用浏览器下载");
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
  ///
  /// - **Windows**：直接调 `ShellExecuteW`（前台进程发起 = 安装程序正常抢前台，且兼容需 UAC
  ///   提升的安装包）。原 open_filex 走 `cmd /c start` 中转导致安装程序后台弹出不聚焦
  ///   （2026-10-20 Howe 反馈）；Dart 原生 `Process.start` 是 CreateProcess，对
  ///   requireAdministrator 的安装包会 740 失败——都不能用。
  /// - **Android**：先查「允许安装未知应用」，未开则抛 [UpdateInstallPermissionException]
  ///   （调用方引导去系统设置，用户返回后自动续装）。已开则经 open_filex 拉起 PackageInstaller。
  /// - **macOS / Linux**：走 open_filex（`open` / `xdg-open`）。
  /// - 全程检查返回结果，失败抛 [UpdateDownloadException]，绝不静默当作成功。
  static Future<void> openInstaller(String path) async {
    if (Platform.isWindows) {
      await _shellExecuteOpen(path);
      return;
    }
    if (Platform.isAndroid) {
      final can = await canRequestPackageInstalls();
      if (!can) {
        throw const UpdateInstallPermissionException();
      }
    }
    final r = await OpenFilex.open(path);
    if (r.type != ResultType.done) {
      throw UpdateDownloadException('无法打开安装包（${r.message}）');
    }
  }

  /// Android：是否已允许安装未知来源应用（API 26+ 查询）。
  /// 非 Android 恒 true；查询失败不拦（由打开结果兜底）。
  static Future<bool> canRequestPackageInstalls() async {
    if (!Platform.isAndroid) return true;
    try {
      final r = await _installerChannel.invokeMethod<bool>('canRequestPackageInstalls');
      // fail-open：通道正常返回 null（理论不可达）也按「不拦」处理，与 catch 分支语义一致
      return r ?? true;
    } catch (_) {
      return true;
    }
  }

  /// Android：跳转系统「允许安装未知应用」设置页；**await 返回即用户已从设置页回来**
  /// （MainActivity 用 startActivityForResult 挂起 result，见 MainActivity.kt）。
  static Future<void> openUnknownAppSourcesSetting() async {
    if (!Platform.isAndroid) return;
    try {
      await _installerChannel.invokeMethod<bool>('openUnknownAppSourcesSetting');
    } catch (_) {
      // 跳转失败不抛：下一次打开安装器会给出明确错误提示
    }
  }

  /// Windows：ShellExecuteW 打开安装包（前台 + UAC 兼容）。
  static Future<void> _shellExecuteOpen(String path) async {
    final shell32 = DynamicLibrary.open('shell32.dll');
    final shellExecuteW = shell32.lookupFunction<
        IntPtr Function(IntPtr hwnd, Pointer<Utf16> operation, Pointer<Utf16> file, Pointer<Utf16> parameters,
            Pointer<Utf16> directory, Int32 showCmd),
        int Function(int hwnd, Pointer<Utf16> operation, Pointer<Utf16> file, Pointer<Utf16> parameters,
            Pointer<Utf16> directory, int showCmd)>('ShellExecuteW');
    final operation = 'open'.toNativeUtf16();
    final file = path.toNativeUtf16();
    try {
      // nShowCmd = SW_SHOWNORMAL(1)：安装程序前台显示
      final result = shellExecuteW(0, operation, file, nullptr, nullptr, 1);
      // 返回值 > 32 表示成功；<= 32 为 SE_ERR_* 错误码
      if (result <= 32) {
        throw UpdateDownloadException('启动安装程序失败（错误码 $result）');
      }
    } finally {
      malloc.free(operation);
      malloc.free(file);
    }
  }
}

/// Android 未开启「允许安装未知应用」：由调用方引导去系统设置开启后自动续装。
class UpdateInstallPermissionException implements Exception {
  const UpdateInstallPermissionException();
  @override
  String toString() => '未开启“允许安装未知应用”';
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
