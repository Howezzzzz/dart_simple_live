import 'dart:async';
import 'dart:convert';

import 'package:simple_live_app/models/version_model.dart';
import 'package:simple_live_app/requests/http_client.dart';

/// 通用的请求
class CommonRequest {
  /// 检查更新：**多源并发择优**（谁先成功返回用谁，其余自然作废）。
  ///
  /// 2026-10-20 Howe 定：检测也上多源择优，避免单一镜像挂掉/变慢拖住整条链路。
  Future<VersionModel> checkUpdate() async {
    final sources = updateSources();
    final completer = Completer<VersionModel>();
    var pending = sources.length;
    for (final url in sources) {
      _fetchVersion(url).then((v) {
        if (!completer.isCompleted) completer.complete(v);
      }).catchError((Object e) {
        pending--;
        if (pending == 0 && !completer.isCompleted) {
          completer.completeError(e);
        }
      });
    }
    return completer.future;
  }

  /// 更新清单候选源（纯函数，便于单测）：国内镜像在前，官方直连兜底。
  static List<String> updateSources() => const [
        // 1) 国内 GitHub 镜像（raw 内容）
        "https://raw.gitmirror.com/Howezzzzz/dart_simple_live/master/assets/app_version.json",
        // 2) jsDelivr CDN
        "https://cdn.jsdelivr.net/gh/Howezzzzz/dart_simple_live@master/assets/app_version.json",
        // 3) 前缀式代理 → raw
        "https://gh-proxy.com/https://raw.githubusercontent.com/Howezzzzz/dart_simple_live/master/assets/app_version.json",
        "https://ghproxy.cc/https://raw.githubusercontent.com/Howezzzzz/dart_simple_live/master/assets/app_version.json",
        // 4) 官方直连（部分地区需代理，但作最后兑底）
        "https://raw.githubusercontent.com/Howezzzzz/dart_simple_live/master/assets/app_version.json",
      ];

  /// 从单个源拉清单（带时间戳防缓存）。
  Future<VersionModel> _fetchVersion(String url) async {
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

  /// 检查更新（单源：国内镜像 raw.gitmirror）——保留供单独调用/回退。
  Future<VersionModel> checkUpdateGitMirror() =>
      _fetchVersion(updateSources()[0]);

  /// 检查更新（单源：jsDelivr）——保留供单独调用/回退。
  Future<VersionModel> checkUpdateJsDelivr() =>
      _fetchVersion(updateSources()[1]);

  /// 拉取虎牙配置
  Future<Map<String, dynamic>> fetchHuyaConfig() async {
    try {
      return await _fetchHuyaConfigGitMirror();
    } catch (e) {
      return await _fetchHuyaConfigJsDelivr();
    }
  }

  Future<Map<String, dynamic>> _fetchHuyaConfigGitMirror() async {
    var result = await HttpClient.instance.getJson(
      "https://raw.gitmirror.com/slotsun/dart_simple_live/master/assets/huya_config.json",
      queryParameters: {
        "ts": DateTime.now().millisecondsSinceEpoch,
      },
    );
    if (result is Map) {
      return result as Map<String, dynamic>;
    }
    return json.decode(result) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> _fetchHuyaConfigJsDelivr() async {
    var result = await HttpClient.instance.getJson(
      "https://cdn.jsdelivr.net/gh/slotsun/dart_simple_live@master/assets/huya_config.json",
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
