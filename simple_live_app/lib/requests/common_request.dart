import 'dart:async';
import 'dart:convert';

import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/models/version_model.dart';
import 'package:simple_live_app/requests/http_client.dart';

/// 检查更新失败（自定义类型，便于上层区分文案与网络错误）。
class UpdateCheckException implements Exception {
  const UpdateCheckException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 通用的请求
class CommonRequest {
  /// 检查更新。
  ///
  /// 2026-10-20 Howe 定（修 CDN 缓存滞后）+ 阶段 4 多轮复核修复：
  /// ① **全源一次并发**（新鲜源 + CDN 源同时打）；
  /// ② 宽限窗规则（防「快但旧」抢先截断）：**直连 raw 结果**可直接开窗；其余需**至少 2 个源在同一 version_num 上一致（quorum）**才开窗；CDN 结果不参与开窗；
  /// ③ 结果过 [isTrustedManifest] 可信校验，再用 [pickNewest] 取 version_num 最大者。
  Future<VersionModel> checkUpdate({
    Future<VersionModel> Function(String url)? fetcher,
    List<String>? sources,
    Duration perSourceTimeout = const Duration(seconds: 8),
    Duration graceWindow = const Duration(milliseconds: 1500),
  }) async {
    final urls = sources ?? updateSources();
    if (urls.isEmpty) {
      throw const UpdateCheckException("检查更新失败：未配置任何更新源");
    }
    final freshSet = freshSources().toSet();
    final f = fetcher ?? _fetchVersion;
    final byUrl = <String, VersionModel>{};
    var failed = 0;
    final done = Completer<void>();
    Timer? grace;
    var pending = urls.length;

    void maybeOpenWindow() {
      if (grace != null || done.isCompleted) return;
      final entries = byUrl.entries.where((e) => isTrustedManifest(e.value)).toList();
      if (entries.isEmpty) return;
      // 真个直连 raw 结果 → 可直接开窗（最可信）
      final directOk = entries.any((e) => e.key == rawDirectUrl);
      // 否则要求多数一致：≥2 个**新鲜源**报同一个 version_num
      // （CDN 结果不参与计票：它们可能命中 12h 旧缓存，两张旧票一致也会开窗 → 原故障复现）
      final counts = <int, int>{};
      for (final e in entries) {
        if (!freshSet.contains(e.key)) continue;
        counts[e.value.versionNum] = (counts[e.value.versionNum] ?? 0) + 1;
      }
      final quorumOk = counts.values.any((c) => c >= 2);
      if (directOk || quorumOk) {
        grace = Timer(graceWindow, () {
          if (!done.isCompleted) done.complete();
        });
      }
    }

    for (final u in urls) {
      f(u).timeout(perSourceTimeout).then((v) {
        byUrl[u] = v;
        // CDN 结果不开窗（可能命中 12h 旧缓存）
        if (freshSet.contains(u)) maybeOpenWindow();
      }).catchError((Object _) {
        failed++;
      }).whenComplete(() {
        pending--;
        if (pending == 0 && !done.isCompleted) done.complete();
      });
    }

    await done.future;
    grace?.cancel();

    final trusted = byUrl.values.where(isTrustedManifest).toList();
    if (trusted.isEmpty) {
      throw UpdateCheckException(
        "检查更新失败：所有源均不可用或内容不可信（失败 $failed/${urls.length}）",
      );
    }
    return pickNewest(trusted);
  }

  /// 可信性校验（纯函数，便于单测）：防第三方代理注入伪造清单。
  ///
  /// 规则：`download_url` 与所有 `download_urls` 必须通过 [isTrustedUrl]（我们自己的仓库路径），
  /// 且 `version_num` 为正、不超方案上界。
  static bool isTrustedManifest(VersionModel v) {
    // 上界 = 版本号方案最大值（major≤99、minor/patch<1000：99*1000000+999*1000+999），
    // 与 parseVersion / CI 同一方案（见 ISS-163）；仅作「荒谬值」兜底，真可信锚是下方 isTrustedUrl。
    if (v.versionNum <= 0 || v.versionNum > 99999999) return false;
    if (!isTrustedUrl(v.downloadUrl)) return false;
    for (final u in v.downloadUrls.values) {
      if (!isTrustedUrl(u)) return false;
    }
    return true;
  }

  /// 单条 URL 是否可信（公开，供**下载侧**复用）。
  ///
  /// ① 允许被我们可控的镜像前缀包裹；
  /// ② 剥掉前缀后 host 必须是 `github.com` 或 `raw.githubusercontent.com`；
  /// ③ 路径必须落在 `/Howezzzzz/dart_simple_live/` 下；
  /// ④ **拒绝含 `.` / `..` 段的路径**（Uri.parse 不做归一化，防 `.../releases/download/../../evil/x.apk` 这类降格逃逸）。
  static bool isTrustedUrl(String? raw) {
    if (raw == null) return false;
    var s = raw.trim();
    if (s.isEmpty) return false;
    for (final p in trustedMirrorPrefixes) {
      if (s.startsWith(p)) {
        s = s.substring(p.length);
        break;
      }
    }
    final uri = Uri.tryParse(s);
    if (uri == null || uri.host.isEmpty) return false;
    if (uri.host != "github.com" && uri.host != "raw.githubusercontent.com") {
      return false;
    }
    // 拒绝百分号编码的 '.' / '/'（%2e / %2f）：代理/服务端解码后可能降格逃逸
    final low = s.toLowerCase();
    if (low.contains('%2e') || low.contains('%2f')) return false;
    // 更彻底：路径里出现任何百分号编码或反斜杠一律拒（我们真实 URL 不含这些），
    // 堵住 %252e 双编码、%5c、反斜杠分隔符等一类逃逸（第四轮复核建议）
    if (uri.path.contains('%') || s.contains('\\') || uri.path.contains('\\')) {
      return false;
    }
    // 原文里的 '.' / '..' 段一律拒（Dart 的 Uri.parse 会归一化，但代理/服务器可能按字面解析）
    if (s.split('/').any((x) => x == '.' || x == '..')) return false;
    // 显式（或已解码）的 '.' / '..' 段也拒
    if (uri.pathSegments.any((x) => x == '.' || x == '..')) return false;
    final segs = uri.path.split('/');
    if (segs.any((x) => x == '.' || x == '..')) return false;
    return uri.path.startsWith("/Howezzzzz/dart_simple_live/");
  }

  /// 可信镜像前缀（硬编码、不采信清单自报值）：下载/候选 URL 只允许用它拼。
  static const List<String> trustedMirrorPrefixes = [
    "https://gh-proxy.com/",
    "https://ghproxy.net/",
    "https://ghproxy.cc/",
  ];

  /// 取版本号最大者（纯函数，便于单测）：防旧缓存盖新版本。
  /// 空表抛 [ArgumentError]（公开纯函数不做隐式前提）。
  static VersionModel pickNewest(List<VersionModel> list) {
    if (list.isEmpty) {
      throw ArgumentError("pickNewest: list is empty");
    }
    var best = list.first;
    for (final v in list) {
      if (v.versionNum > best.versionNum) best = v;
    }
    return best;
  }

  /// **新鲜源**（几乎不缓存，优先）：前缀式代理 → raw.githubusercontent.com。
  static const String rawDirectUrl =
      "https://raw.githubusercontent.com/Howezzzzz/dart_simple_live/master/assets/app_version.json";

  static List<String> freshSources() => const [
        "https://gh-proxy.com/$rawDirectUrl",
        _ghProxyNetUrl,
        "https://ghproxy.cc/$rawDirectUrl",
        rawDirectUrl,
      ];

  /// ghproxy.net 上的清单地址（与下载镜像白名单 [trustedMirrorPrefixes] 同一批）——
  /// 供 [freshSources] 与 [checkUpdateGhProxyNet] 复用。
  static const String _ghProxyNetUrl = "https://ghproxy.net/$rawDirectUrl";

  /// **CDN 源**（可能滞后数小时，与新鲜源同时打、只作为补充）：jsDelivr。
  ///
  /// 2026-10-25（ISS-229）：原 gitmirror 源 `raw.gitmirror.com` **域名已失效**
  /// （Google / 阿里 / 114 三家公共解析器一致 NXDOMAIN，服务疑似停运）→ 已移除；
  /// 改以**前缀式镜像 ghproxy.net**（不缓存、可正常参与 quorum）作补充，放在
  /// [freshSources]；CDN 侧现仅剩 jsDelivr（CI 发版后已自动 purge）。
  static const String _jsdelivrUrl =
      "https://cdn.jsdelivr.net/gh/Howezzzzz/dart_simple_live@master/assets/app_version.json";

  static List<String> cdnSources() => const [_jsdelivrUrl];

  /// 全部候选源（新鲜在前、CDN 兜底）——供测试与外部引用。
  static List<String> updateSources() => [...freshSources(), ...cdnSources()];

  /// 从单个源拉清单（带时间戳防缓存）。静态，供 `_fetchAll` 直接引用 + 单测注入。
  static Future<VersionModel> _fetchVersion(String url) async {
    var result = await HttpClient.instance.getJson(
      url,
      queryParameters: {
        "ts": DateTime.now().millisecondsSinceEpoch,
      },
    );
    if (result is Map) {
      return VersionModel.fromJson(result as Map<String, dynamic>);
    }
    return VersionModel.fromJson(json.decode(result));
  }

  /// 单源拉取 + **可信校验**（保留给单独调用/回退；同样过校验，不给伪造清单留后门）。
  Future<VersionModel> _fetchValidated(String url, {Future<VersionModel> Function(String url)? fetcher}) async {
    final v = await (fetcher ?? _fetchVersion)(url);
    if (!isTrustedManifest(v)) {
      throw const UpdateCheckException("该源返回的更新清单不可信");
    }
    return v;
  }

  /// 检查更新（单源：国内镜像 ghproxy.net）——保留供单独调用/回退（已过可信校验）。
  /// （2026-10-25 ISS-229：原 gitmirror 单源已随失效域名下线，换为 ghproxy.net。）
  Future<VersionModel> checkUpdateGhProxyNet() => _fetchValidated(_ghProxyNetUrl);

  /// 检查更新（单源：jsDelivr）——保留供单独调用/回退（已过可信校验）。
  Future<VersionModel> checkUpdateJsDelivr() => _fetchValidated(_jsdelivrUrl);

  /// ===== 虎牙 SDK UA 配置 =====
  ///
  /// 2026-10-21 Howe 定：加**我们自己的兜底源**（放在上游源之后）+ 内容校验，
  /// 摆脱对上游仓库/第三方代理的硬依赖。该文件随「每日上游同步」自动进入我们仓库
  /// （fork 自带 + 上游更新即同步），故我们的源既可控又新鲜，但按语义作**兜底**（最后）。
  static const String _huyaConfigSelfUrl =
      "https://gh-proxy.com/https://raw.githubusercontent.com/Howezzzzz/dart_simple_live/master/assets/huya_config.json";
  static const String _huyaConfigSelfRawUrl =
      "https://raw.githubusercontent.com/Howezzzzz/dart_simple_live/master/assets/huya_config.json";
  /// 2026-10-25（ISS-229）：原第一源 gitmirror 域名已失效 → 换为前缀式镜像 ghproxy.net
  /// （同一份上游 raw 内容，仍作「上游源优先」的第一源）。
  static const String _huyaConfigUpstreamGhProxyUrl =
      "https://ghproxy.net/https://raw.githubusercontent.com/slotsun/dart_simple_live/master/assets/huya_config.json";
  static const String _huyaConfigJsDelivrUrl =
      "https://cdn.jsdelivr.net/gh/slotsun/dart_simple_live@master/assets/huya_config.json";

  /// 拉取虎牙配置：**上游源优先**（权威/最新），**我们自己的源兜底**（上游不可达时仍可用）。
  /// （Howe 2026-10-21 定：既然是兜底，就放最后。）
  /// 返回的 hysdk_ua 做**内容校验**（防第三方代理注入任意 UA，与清单可信校验同源哲学）。
  Future<Map<String, dynamic>> fetchHuyaConfig() async {
    final urls = <String>[
      _huyaConfigUpstreamGhProxyUrl, // ① 上游（ghproxy.net 镜像）
      _huyaConfigJsDelivrUrl, // ② 上游
      _huyaConfigSelfUrl, // ③ 我们自己的（兜底，gh-proxy）
      _huyaConfigSelfRawUrl, // ④ 我们自己的（兜底，raw 直连）
    ];
    Object? lastError;
    for (final url in urls) {
      try {
        final cfg = await _fetchHuyaConfigFrom(url);
        final ua = cfg['hysdk_ua'];
        if (ua is! String || !ua.startsWith("HYSDK(") || ua.length > 512) {
          lastError = "返回的 hysdk_ua 不合法（来源：$url）";
          Log.w("虎牙配置内容不可信：$url");
          continue; // 换下一源
        }
        return cfg;
      } catch (e) {
        lastError = e;
        Log.w("拉取虎牙配置失败（$url）：$e");
      }
    }
    Log.e("拉取虎牙配置失败（所有源均不可用）：$lastError", StackTrace.current);
    throw Exception("拉取虎牙配置失败，请稍后重试");
  }

  Future<Map<String, dynamic>> _fetchHuyaConfigFrom(String url) async {
    var result = await HttpClient.instance.getJson(
      url,
      queryParameters: {
        "ts": DateTime.now().millisecondsSinceEpoch,
      },
    );
    if (result is Map) {
      return result as Map<String, dynamic>;
    }
    return json.decode(result) as Map<String, dynamic>;
  }
}
