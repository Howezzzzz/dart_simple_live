import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/models/version_model.dart';

/// RT-109：检查更新版本模型解析（Howe 2026-10-19「检查更新对接自有构建」）。
void main() {
  group('VersionModel 解析（RT-109）', () {
    test('解析 download_urls：保留有效项、剔空值', () {
      final m = VersionModel.fromJson({
        'version': '1.8.15',
        'version_num': 10815,
        'version_desc': 'x',
        'download_url': 'https://example.com/releases/latest',
        'download_urls': {
          'android': 'https://e/a.apk',
          'windows': 'https://e/w.exe',
          'empty': '',
        },
      });
      expect(m.version, '1.8.15');
      expect(m.versionNum, 10815);
      expect(m.downloadUrls['android'], 'https://e/a.apk');
      expect(m.downloadUrls['windows'], 'https://e/w.exe');
      expect(m.downloadUrls.containsKey('empty'), isFalse);
      expect(m.toJson()['download_urls'], m.downloadUrls);
    });

    test('download_urls 缺失 → 空 map（下载链接回落 download_url，由 Utils 处理）', () {
      final m = VersionModel.fromJson({
        'version': '1.8.15',
        'version_num': 10815,
        'version_desc': 'x',
        'download_url': 'https://example.com/releases/latest',
      });
      expect(m.downloadUrls, isEmpty);
      expect(m.downloadUrl, 'https://example.com/releases/latest');
    });

    test('download_urls 为非法类型（非 Map）→ 空 map，不抛异常', () {
      final m = VersionModel.fromJson({
        'version': '1.8.15',
        'version_num': 10815,
        'version_desc': 'x',
        'download_url': 'https://e',
        'download_urls': 'oops',
      });
      expect(m.downloadUrls, isEmpty);
    });
  });
}
