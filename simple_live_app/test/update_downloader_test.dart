import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/models/version_model.dart';
import 'package:simple_live_app/services/update_downloader.dart';

VersionModel _model({
  String downloadUrl = 'https://github.com/o/r/releases/download/v1/x.apk',
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
    test('无镜像时只有直链', () {
      expect(UpdateDownloader.buildCandidates(_model()), [
        'https://github.com/o/r/releases/download/v1/x.apk',
      ]);
    });

    test('镜像前缀拼接（带 / 与不带 / 都能拼对）', () {
      final c = UpdateDownloader.buildCandidates(_model(mirrorPrefixes: [
        'https://gh-proxy.com/',
        'https://ghproxy.net',
      ]));
      expect(c, [
        'https://github.com/o/r/releases/download/v1/x.apk',
        'https://gh-proxy.com/https://github.com/o/r/releases/download/v1/x.apk',
        'https://ghproxy.net/https://github.com/o/r/releases/download/v1/x.apk',
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
      expect(c.first, 'https://github.com/o/r/releases/download/v1/x.apk');
    });

    test('直链永远排第一位（测速失败兜底顺序也保持）', () {
      final c = UpdateDownloader.buildCandidates(_model(mirrorPrefixes: [
        'https://m1/',
        'https://m2/',
      ]));
      expect(c.first, 'https://github.com/o/r/releases/download/v1/x.apk');
    });
  });

  group('VersionModel.mirror_prefixes 解析', () {
    test('正常解析 + 去空 + toJson 往返', () {
      final m = VersionModel.fromJson(<String, dynamic>{
        'version': '1.8.19',
        'version_num': 10819,
        'version_desc': '- x',
        'download_url': 'https://github.com/o/r/releases/latest',
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
        'download_url': 'https://github.com/o/r/releases/latest',
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