import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/models/version_model.dart';
import 'package:simple_live_app/services/update_downloader.dart';

VersionModel _model({
  String downloadUrl = 'https://github.com/Howezzzzz/dart_simple_live/releases/download/v1/x.apk',
  Map<String, String> downloadUrls = const {},
  List<String> mirrorPrefixes = const [],
}) =>
    VersionModel(
      version: '1.0.0',
      versionNum: 10000,
      versionDesc: 'd',
      downloadUrl: downloadUrl,
      downloadUrls: downloadUrls,
      mirrorPrefixes: mirrorPrefixes,
    );

void main() {
  group('UpdateDownloader.buildCandidates（直链 + 镜像候选）', () {
    test('清单未给镜像前缀时，回落我们自己的白名单（直链仍在首位）', () {
      // 2026-10-20 修订：effectiveMirrorPrefixes() 在清单未给前缀（或给了白名单外的）时
      // 回落硬编码白名单 → 候选 = 直链 + 三个白名单镜像，而不是只有直链。
      expect(UpdateDownloader.buildCandidates(_model()), [
        'https://github.com/Howezzzzz/dart_simple_live/releases/download/v1/x.apk',
        'https://gh-proxy.com/https://github.com/Howezzzzz/dart_simple_live/releases/download/v1/x.apk',
        'https://ghproxy.net/https://github.com/Howezzzzz/dart_simple_live/releases/download/v1/x.apk',
        'https://ghproxy.cc/https://github.com/Howezzzzz/dart_simple_live/releases/download/v1/x.apk',
      ]);
    });

    test('镜像前缀拼接（带 / 与不带 / 都能拼对）', () {
      final c = UpdateDownloader.buildCandidates(_model(mirrorPrefixes: [
        'https://gh-proxy.com/',
        'https://ghproxy.net',
      ]));
      expect(c, [
        'https://github.com/Howezzzzz/dart_simple_live/releases/download/v1/x.apk',
        'https://gh-proxy.com/https://github.com/Howezzzzz/dart_simple_live/releases/download/v1/x.apk',
        'https://ghproxy.net/https://github.com/Howezzzzz/dart_simple_live/releases/download/v1/x.apk',
      ]);
    });

    test('去重 + 过滤空/空白前缀', () {
      final c = UpdateDownloader.buildCandidates(_model(mirrorPrefixes: [
        '',
        '   ',
        'https://gh-proxy.com/',
        'https://gh-proxy.com/',
      ]));
      expect(c.length, 2);
      expect(c.first, 'https://github.com/Howezzzzz/dart_simple_live/releases/download/v1/x.apk');
    });

    test('直链永远排第一位（测速失败兜底顺序也保持）', () {
      final c = UpdateDownloader.buildCandidates(_model(mirrorPrefixes: [
        'https://m1/',
        'https://m2/',
      ]));
      expect(c.first, 'https://github.com/Howezzzzz/dart_simple_live/releases/download/v1/x.apk');
    });
  });

  group('VersionModel.mirror_prefixes 解析', () {
    test('正常解析 + 去空 + toJson 往返', () {
      final m = VersionModel.fromJson(<String, dynamic>{
        'version': '1.8.19',
        'version_num': 10819,
        'version_desc': '- x',
        'download_url': 'https://github.com/Howezzzzz/dart_simple_live/releases/latest',
        'download_urls': <String, dynamic>{'linux': 'L'},
        'mirror_prefixes': <dynamic>['https://gh-proxy.com/', '', 42, '  '],
      });
      expect(m.mirrorPrefixes, ['https://gh-proxy.com/']);
      expect(m.toJson()['mirror_prefixes'], ['https://gh-proxy.com/']);
    });

    test('缺失字段 → 空表（老 manifest 兼容）', () {
      final m = VersionModel.fromJson(<String, dynamic>{
        'version': '1.8.18',
        'version_num': 10818,
        'version_desc': '- x',
        'download_url': 'https://github.com/Howezzzzz/dart_simple_live/releases/latest',
      });
      expect(m.mirrorPrefixes, isEmpty);
    });
  });

  group('UpdateDownloader.rankBySpeed', () {
    test('单条候选直接返回（不做无谓探测）', () async {
      final r = await UpdateDownloader.rankBySpeed(['https://only/']);
      expect(r, ['https://only/']);
    });

    test('空列表返回空', () async {
      expect(await UpdateDownloader.rankBySpeed([]), isEmpty);
    });
  });
}