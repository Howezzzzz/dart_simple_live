import 'dart:convert';
import 'common/common_asT.dart';

class VersionModel {
  VersionModel({
    required this.version,
    required this.versionNum,
    required this.versionDesc,
    required this.downloadUrl,
    this.downloadUrls = const {},
    this.mirrorPrefixes = const [],
    this.downloadSha256 = const {},
  });

  factory VersionModel.fromJson(Map<String, dynamic> json) => VersionModel(
        version: asT<String>(json['version'])!,
        versionNum: asT<int>(json['version_num'])!,
        versionDesc: asT<String>(json['version_desc'])!,
        downloadUrl: asT<String>(json['download_url'])!,
        downloadUrls: _asStringMap(json['download_urls']),
        mirrorPrefixes: _asStringList(json['mirror_prefixes']),
        downloadSha256: _asStringMap(json['download_sha256']),
      );

  String version;
  int versionNum;
  String versionDesc;
  String downloadUrl;

  /// 分平台直链（可选）：{android/windows/macos/linux/ios → url}；缺失则回落 [downloadUrl]
  Map<String, String> downloadUrls;

  /// 镜像前缀（前缀式镜像站，如 `https://gh-proxy.com/`）：与直链拼接成候选下载线路。
  List<String> mirrorPrefixes;

  /// 各平台安装包的 sha256（键同 [downloadUrls]，如 android/windows/...）；
  /// 用于下载后**完整性校验**，防第三方镜像换包。缺失则该平台跳过校验。
  Map<String, String> downloadSha256;

  static Map<String, String> _asStringMap(dynamic v) {
    if (v is Map) {
      final out = <String, String>{};
      v.forEach((k, val) {
        if (val is String && val.isNotEmpty) out['$k'] = val;
      });
      return out;
    }
    return const {};
  }

  static List<String> _asStringList(dynamic v) {
    if (v is List) {
      return v
          .whereType<String>()
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
    }
    return const [];
  }

  @override
  String toString() {
    return jsonEncode(this);
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'version': version,
        'version_num': versionNum,
        'version_desc': versionDesc,
        'download_url': downloadUrl,
        'download_urls': downloadUrls,
        'mirror_prefixes': mirrorPrefixes,
        'download_sha256': downloadSha256,
      };
}
