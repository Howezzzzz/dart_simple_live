import 'dart:convert';
import 'common/common_asT.dart';

class VersionModel {
  VersionModel({
    required this.version,
    required this.versionNum,
    required this.versionDesc,
    required this.downloadUrl,
    this.downloadUrls = const {},
  });

  factory VersionModel.fromJson(Map<String, dynamic> json) => VersionModel(
        version: asT<String>(json['version'])!,
        versionNum: asT<int>(json['version_num'])!,
        versionDesc: asT<String>(json['version_desc'])!,
        downloadUrl: asT<String>(json['download_url'])!,
        downloadUrls: _asStringMap(json['download_urls']),
      );

  String version;
  int versionNum;
  String versionDesc;
  String downloadUrl;

  /// 分平台直链（可选）：{android/windows/macos/linux/ios → url}；缺失则回落 [downloadUrl]
  Map<String, String> downloadUrls;

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
      };
}
