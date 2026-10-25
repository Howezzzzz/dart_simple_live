import 'dart:convert';

import 'package:simple_live_tv_app/models/version_model.dart';
import 'package:simple_live_tv_app/requests/http_client.dart';

/// 通用的请求
class CommonRequest {
  Future<VersionModel> checkUpdate() async {
    try {
      return await checkUpdateGhProxyNet();
    } catch (e) {
      return await checkUpdateJsDelivr();
    }
  }

  /// 检查更新（国内前缀镜像 ghproxy.net → xiaoyaocz 上游 raw）
  ///
  /// 2026-10-25（ISS-230）：原第一源 `raw.gitmirror.com` **域名已全网失效**
  /// （Google / 阿里 / 114 三家公共解析器一致 NXDOMAIN）→ 换为前缀式镜像 ghproxy.net
  /// （同一份上游 raw 内容，可直连/带国内提速）。
  Future<VersionModel> checkUpdateGhProxyNet() async {
    var result = await HttpClient.instance.getJson(
      "https://ghproxy.net/https://raw.githubusercontent.com/xiaoyaocz/dart_simple_live/master/assets/tv_app_version.json",
      queryParameters: {
        "ts": DateTime.now().millisecondsSinceEpoch,
      },
    );
    if (result is Map) {
      return VersionModel.fromJson(result as Map<String, dynamic>);
    }
    return VersionModel.fromJson(json.decode(result));
  }

  /// 检查更新
  Future<VersionModel> checkUpdateJsDelivr() async {
    var result = await HttpClient.instance.getJson(
      "https://cdn.jsdelivr.net/gh/xiaoyaocz/dart_simple_live@master/assets/tv_app_version.json",
      queryParameters: {
        "ts": DateTime.now().millisecondsSinceEpoch,
      },
    );
    if (result is Map) {
      return VersionModel.fromJson(result as Map<String, dynamic>);
    }
    return VersionModel.fromJson(json.decode(result));
  }
}
