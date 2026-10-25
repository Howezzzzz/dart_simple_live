import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/models/version_model.dart';
import 'package:simple_live_app/requests/common_request.dart';
import 'package:simple_live_app/services/update_downloader.dart';

const String _ownUrl = 'https://github.com/Howezzzzz/dart_simple_live/releases/latest';

VersionModel _v(
  int num, {
  String? downloadUrl,
  Map<String, String> urls = const {},
  List<String> mirrors = const [],
  Map<String, String> sha = const {},
}) =>
    VersionModel(
      version: '1.0.0',
      versionNum: num,
      versionDesc: 'd',
      downloadUrl: downloadUrl ?? _ownUrl,
      downloadUrls: urls,
      mirrorPrefixes: mirrors,
      downloadSha256: sha,
    );

void main() {
  group('CommonRequest 检测源分组', () {
    final fresh = CommonRequest.freshSources();
    final cdn = CommonRequest.cdnSources();
    final all = CommonRequest.updateSources();

    test('updateSources = 新鲜源 + CDN 源，且两组不相交', () {
      expect(all, [...fresh, ...cdn]);
      expect(fresh.toSet().intersection(cdn.toSet()), isEmpty);
    });

    test('新鲜源含 gh-proxy / ghproxy.net / ghproxy.cc 前缀与 raw 直连', () {
      expect(fresh.any((u) => u.startsWith('https://gh-proxy.com/https://')), isTrue);
      expect(fresh.any((u) => u.startsWith('https://ghproxy.net/https://')), isTrue);
      expect(fresh.any((u) => u.startsWith('https://ghproxy.cc/https://')), isTrue);
      expect(fresh.any((u) => u.startsWith('https://raw.githubusercontent.com/')), isTrue);
    });

    test('已不再包含已失效的 gitmirror 源（ISS-229，域名全网 NXDOMAIN）', () {
      expect(all.any((u) => u.contains('gitmirror')), isFalse);
    });

    test('CDN 源仅 jsDelivr（gitmirror 已失效移除，2026-10-25）', () {
      expect(cdn.length, 1);
      expect(cdn.single, contains('jsdelivr'));
    });

    test('全部指向同一份 app_version.json 且互不重复', () {
      for (final u in all) {
        expect(u, contains('Howezzzzz/dart_simple_live'));
        expect(u, endsWith('assets/app_version.json'));
      }
      expect(all.toSet().length, all.length);
    });
  });

  group('pickNewest（取版本号最大，防 CDN 旧缓存盖新版本）', () {
    test('新旧混合 → 取最大', () {
      expect(CommonRequest.pickNewest([_v(10818), _v(10821), _v(10819)]).versionNum, 10821);
    });
    test('单个 → 原样返回', () {
      expect(CommonRequest.pickNewest([_v(10818)]).versionNum, 10818);
    });
    test('同版本 → 不报错', () {
      expect(CommonRequest.pickNewest([_v(10821), _v(10821)]).versionNum, 10821);
    });
    test('顺序无关', () {
      expect(CommonRequest.pickNewest([_v(10821), _v(10818)]).versionNum, 10821);
      expect(CommonRequest.pickNewest([_v(10818), _v(10821)]).versionNum, 10821);
    });
    test('空表 → 抛 ArgumentError（不做隐式前提）', () {
      expect(() => CommonRequest.pickNewest([]), throwsArgumentError);
    });
  });

  group('isTrustedManifest（防第三方代理注入伪造清单）', () {
    test('自家 Release 链接 → 可信', () {
      expect(CommonRequest.isTrustedManifest(_v(10821)), isTrue);
    });
    test('自家 releases 列表页链接（发版即测试版，故不用 /latest）→ 可信', () {
      expect(
        CommonRequest.isTrustedManifest(
            _v(10821, downloadUrl: 'https://github.com/Howezzzzz/dart_simple_live/releases')),
        isTrue,
      );
    });
    test('带我们镜像前缀的自家链接 → 可信', () {
      expect(
        CommonRequest.isTrustedManifest(_v(
          10821,
          downloadUrl: 'https://gh-proxy.com/$_ownUrl',
          urls: {
            'android': 'https://ghproxy.cc/https://github.com/Howezzzzz/dart_simple_live/releases/download/v1/app.apk'
          },
        )),
        isTrue,
      );
    });
    test('非自家域名 → 不可信', () {
      expect(CommonRequest.isTrustedManifest(_v(10821, downloadUrl: 'https://evil.com/x.apk')), isFalse);
    });
    test('download_urls 混入一个非自家 → 整体不可信', () {
      expect(
        CommonRequest.isTrustedManifest(_v(10821, urls: {
          'android': 'https://github.com/Howezzzzz/dart_simple_live/releases/download/v1/a.apk',
          'windows': 'https://evil.com/w.exe',
        })),
        isFalse,
      );
    });
    test('空链接 / 版本号非法 → 不可信', () {
      expect(CommonRequest.isTrustedManifest(_v(0)), isFalse);
      expect(CommonRequest.isTrustedManifest(_v(100000000)), isFalse); // 超新上界 99,999,999（ISS-163）
      expect(CommonRequest.isTrustedManifest(_v(10821, downloadUrl: '')), isFalse);
    });
  });

  group('checkUpdate 核心路径（注入 fetcher，无需真实网络）', () {
    test('多源含旧缓存（10818）→ 取新版本 10821', () async {
      final r = await CommonRequest().checkUpdate(
        sources: const ['old', 'fresh', 'mid'],
        fetcher: (u) async => switch (u) {
          'old' => _v(10818, downloadUrl: 'https://gh-proxy.com/$_ownUrl'),
          'mid' => _v(10819, downloadUrl: 'https://gh-proxy.com/$_ownUrl'),
          _ => _v(10821, downloadUrl: 'https://gh-proxy.com/$_ownUrl'),
        },
      );
      expect(r.versionNum, 10821);
    });

    test('部分源失败/抛错 → 忽略，仍返回成功结果', () async {
      final r = await CommonRequest().checkUpdate(
        sources: const ['bad', 'good'],
        fetcher: (u) async {
          if (u == 'bad') throw Exception('boom');
          return _v(10821, downloadUrl: 'https://gh-proxy.com/$_ownUrl');
        },
      );
      expect(r.versionNum, 10821);
    });

    test('慢源超过窗口 → 被忽略，不阻塞（也不把慢源当失败整体报错）', () async {
      final r = await CommonRequest().checkUpdate(
        sources: const ['slow', 'fast'],
        perSourceTimeout: const Duration(milliseconds: 150),
        fetcher: (u) async {
          if (u == 'slow') {
            await Future<void>.delayed(const Duration(seconds: 2));
          }
          return _v(u == 'slow' ? 10821 : 10820, downloadUrl: 'https://gh-proxy.com/$_ownUrl');
        },
      );
      expect(r.versionNum, 10820);
    });

    test('全部源失败 → 抛 UpdateCheckException', () async {
      expect(
        () => CommonRequest().checkUpdate(
          sources: const ['a', 'b'],
          fetcher: (u) async => throw Exception('net down'),
        ),
        throwsA(isA<UpdateCheckException>()),
      );
    });

    test('只剩不可信内容 → 抛 UpdateCheckException（伪造清单进不来）', () async {
      expect(
        () => CommonRequest().checkUpdate(
          sources: const ['evil'],
          fetcher: (u) async => _v(99998, downloadUrl: 'https://evil.com/x.apk'),
        ),
        throwsA(isA<UpdateCheckException>()),
      );
    });

    test('超时异常（TimeoutException）路径同样被忽略', () async {
      final r = await CommonRequest().checkUpdate(
        sources: const ['timeout', 'good'],
        fetcher: (u) async {
          if (u == 'timeout') throw TimeoutException('t');
          return _v(10821, downloadUrl: 'https://gh-proxy.com/$_ownUrl');
        },
      );
      expect(r.versionNum, 10821);
    });
  });

  group('真实清单夹具（防「白名单把真清单判死」）', () {
    // 取自线上 assets/app_version.json（v1.8.21）
    const realManifest = '''
    {
      "version": "1.8.21",
      "version_num": 10821,
      "version_desc": "- sync(upstream): 同步上游 dev 2 提交",
      "prerelease": false,
      "download_url": "https://github.com/Howezzzzz/dart_simple_live/releases/latest",
      "download_urls": {
        "android": "https://github.com/Howezzzzz/dart_simple_live/releases/download/v1.8.21/app-arm64-v8a-release.apk",
        "windows": "https://github.com/Howezzzzz/dart_simple_live/releases/download/v1.8.21/Slive-1.8.21+10821-windows-setup.exe",
        "macos": "https://github.com/Howezzzzz/dart_simple_live/releases/download/v1.8.21/simple_live_app-1.8.21+10821-macos.dmg",
        "linux": "https://github.com/Howezzzzz/dart_simple_live/releases/download/v1.8.21/Slive-x86_64-linux.deb",
        "linux_flatpak": "https://github.com/Howezzzzz/dart_simple_live/releases/download/v1.8.21/Slive-x86_64.flatpak"
      },
      "mirror_prefixes": ["https://gh-proxy.com/", "https://ghproxy.net/", "https://ghproxy.cc/"]
    }''';

    test('线上真实清单 → 可信（否则 checkUpdate 会恒失败）', () {
      final v = VersionModel.fromJson(jsonDecode(realManifest) as Map<String, dynamic>);
      expect(CommonRequest.isTrustedManifest(v), isTrue);
      expect(CommonRequest.pickNewest([v]).versionNum, 10821);
    });

    test('用真清单跑 checkUpdate（注入 fetcher）→ 正常拿到 10821', () async {
      final real = VersionModel.fromJson(jsonDecode(realManifest) as Map<String, dynamic>);
      final r = await CommonRequest().checkUpdate(
        sources: const ['real', 'stale'],
        fetcher: (u) async => u == 'real' ? real : _v(10818),
      );
      expect(r.versionNum, 10821);
    });
  });

  group('并发与早退（不为慢源/死源死等）', () {
    test('每个源都被调用一次（真并发发起）', () async {
      final calls = <String>[];
      await CommonRequest().checkUpdate(
        sources: const ['a', 'b', 'c'],
        fetcher: (u) async {
          calls.add(u);
          return _v(10821, downloadUrl: 'https://gh-proxy.com/$_ownUrl');
        },
      );
      expect(calls.length, 3);
      expect(calls.toSet(), {'a', 'b', 'c'});
    });

    test('两个新鲜源一致（quorum）→ 宽限窗内即返回，远小于 perSourceTimeout', () async {
      final p1 = CommonRequest.freshSources()[0];
      final p2 = CommonRequest.freshSources()[1];
      final sw = Stopwatch()..start();
      final r = await CommonRequest().checkUpdate(
        sources: [p1, p2, 'dead'],
        perSourceTimeout: const Duration(seconds: 2),
        graceWindow: const Duration(milliseconds: 300),
        fetcher: (u) async {
          if (u == 'dead') return Completer<VersionModel>().future; // 永不完成
          return _v(10821, downloadUrl: 'https://gh-proxy.com/$_ownUrl');
        },
      );
      sw.stop();
      expect(r.versionNum, 10821);
      expect(sw.elapsedMilliseconds < 1500, isTrue, reason: '不应死等慢源/死源，实测 ${sw.elapsedMilliseconds}ms');
    });

    test('单个代理源（无 quorum）不早退——等到多数一致/全部返回（第五轮加固）', () async {
      final p1 = CommonRequest.freshSources()[0];
      final p2 = CommonRequest.freshSources()[1];
      final sw = Stopwatch()..start();
      final r = await CommonRequest().checkUpdate(
        sources: [p1, p2],
        perSourceTimeout: const Duration(seconds: 3),
        graceWindow: const Duration(milliseconds: 200),
        fetcher: (u) async {
          if (u == p1) {
            return _v(10821, downloadUrl: 'https://gh-proxy.com/$_ownUrl');
          }
          await Future<void>.delayed(const Duration(milliseconds: 900));
          return _v(10821, downloadUrl: 'https://gh-proxy.com/$_ownUrl');
        },
      );
      sw.stop();
      expect(r.versionNum, 10821);
      expect(sw.elapsedMilliseconds >= 800, isTrue, reason: '无 quorum 之前不应早退，实测 ${sw.elapsedMilliseconds}ms');
    });
  });

  group('镜像前缀防绕过（阶段 4 P0）', () {
    test('清单自报的**白名单内**前缀 → 采用', () {
      final v = _v(10821, mirrors: const ['https://gh-proxy.com/']);
      expect(UpdateDownloader.effectiveMirrorPrefixes(v), ['https://gh-proxy.com/']);
    });

    test('清单自报的**恶意**前缀 → 丢弃，回落我们自己的白名单', () {
      final v = _v(10821, mirrors: const ['https://evil.com/']);
      expect(UpdateDownloader.effectiveMirrorPrefixes(v), CommonRequest.trustedMirrorPrefixes);
    });

    test('buildCandidates 不会拼出恶意域名（可信 download_url + 伪造前缀也无效）', () {
      final v = _v(10821, mirrors: const ['https://evil.com/']);
      for (final u in UpdateDownloader.buildCandidates(v)) {
        expect(u.contains('evil.com'), isFalse);
        expect(u.contains('github.com/Howezzzzz/dart_simple_live'), isTrue);
      }
    });
  });

  group('isTrustedUrl（下载侧复检 + 路径逃逸）', () {
    test('自家 Release / latest 链接 → 可信', () {
      expect(CommonRequest.isTrustedUrl(_ownUrl), isTrue);
      expect(CommonRequest.isTrustedUrl('https://github.com/Howezzzzz/dart_simple_live/releases/download/v1/a.apk'),
          isTrue);
    });

    test('镜像前缀包裹的自家链接 → 可信', () {
      expect(CommonRequest.isTrustedUrl('https://gh-proxy.com/$_ownUrl'), isTrue);
    });

    test('`..` / `.` 路径逃逸 → 拒绝', () {
      expect(
          CommonRequest.isTrustedUrl(
              'https://github.com/Howezzzzz/dart_simple_live/releases/download/../../evil/x.apk'),
          isFalse);
      expect(CommonRequest.isTrustedUrl('https://github.com/Howezzzzz/dart_simple_live/../../../evil/x.apk'), isFalse);
    });

    test('百分号编码的 `..` / `/` → 拒绝（防代理解码后逃逸）', () {
      expect(
          CommonRequest.isTrustedUrl(
              'https://github.com/Howezzzzz/dart_simple_live/releases/download/%2e%2e/%2e%2e/evil/x.apk'),
          isFalse);
      expect(
          CommonRequest.isTrustedUrl('https://github.com/Howezzzzz/dart_simple_live/releases%2f..%2f..%2fevil/x.apk'),
          isFalse);
      expect(
          CommonRequest.isTrustedUrl(
              'https://gh-proxy.com/https://github.com/Howezzzzz/dart_simple_live/%2E%2E/evil/x.apk'),
          isFalse);
    });

    test('双编码 / 反斜杠 → 拒绝（第五轮加固）', () {
      expect(
          CommonRequest.isTrustedUrl('https://github.com/Howezzzzz/dart_simple_live/%252e%252e/evil/x.apk'), isFalse);
      expect(
          CommonRequest.isTrustedUrl('https://github.com/Howezzzzz/dart_simple_live/a%5cb%5c..%5cevil.apk'), isFalse);
      expect(CommonRequest.isTrustedUrl('https://github.com/Howezzzzz/dart_simple_live\\..\\evil.apk'), isFalse);
    });

    test('别家仓库 / 别家 host → 拒绝', () {
      expect(CommonRequest.isTrustedUrl('https://github.com/other/repo/x.apk'), isFalse);
      expect(CommonRequest.isTrustedUrl('https://evil.com/Howezzzzz/dart_simple_live/x'), isFalse);
      expect(CommonRequest.isTrustedUrl(''), isFalse);
      expect(CommonRequest.isTrustedUrl(null), isFalse);
    });
  });

  group('空源 / 陈旧 CDN 不截断（回归用例）', () {
    test('未配置任何源 → 抛 UpdateCheckException（不永久挂起）', () {
      expect(
        () => CommonRequest().checkUpdate(sources: const []),
        throwsA(isA<UpdateCheckException>()),
      );
    });

    test('先到的“可信但陈旧”CDN 结果不能提前结束（否则原症状复现）', () async {
      final cdn = CommonRequest.cdnSources().first;
      final fresh = CommonRequest.freshSources().first;
      final r = await CommonRequest().checkUpdate(
        sources: [cdn, fresh],
        perSourceTimeout: const Duration(seconds: 2),
        graceWindow: const Duration(milliseconds: 200),
        fetcher: (u) async {
          if (u == cdn) return _v(10818); // 旧缓存，先返回
          await Future<void>.delayed(const Duration(milliseconds: 600));
          return _v(10821); // 新鲜源，后到
        },
      );
      expect(r.versionNum, 10821, reason: '不能被先到的旧 CDN 结果截断');
    });
  });

  group('安装包 sha256 校验', () {
    test('sha256OfFile 与 crypto 直接计算结果一致', () async {
      final dir = await Directory.systemTemp.createTemp('slive_sha_test');
      final f = File('${dir.path}/x.bin');
      await f.writeAsBytes(List<int>.generate(300000, (i) => i % 251));
      final got = await UpdateDownloader.sha256OfFile(f.path);
      final want = sha256.convert(await f.readAsBytes()).toString();
      expect(got, want);
      await dir.delete(recursive: true);
    });

    test('expectedSha256 按平台取并小写归一（测试机为 linux）', () {
      final v = _v(10821, sha: {'linux': 'ABC123DEF'});
      expect(UpdateDownloader.expectedSha256(v), 'abc123def');
    });

    test('清单无哈希 → 返回 null（跳过校验，不报错）', () {
      expect(UpdateDownloader.expectedSha256(_v(10821)), isNull);
    });

    test('verifySha256 不匹配 → 删包并抛错（不返回 path → 不会拉起安装器）', () async {
      final dir = await Directory.systemTemp.createTemp('slive_sha_mismatch');
      final f = File('${dir.path}/bad.apk');
      await f.writeAsString('not-the-real-apk');
      await expectLater(
        () => UpdateDownloader.verifySha256(f.path, '0000000000000000000000000000000000000000000000000000000000000000'),
        throwsA(isA<UpdateDownloadException>()),
      );
      expect(await f.exists(), isFalse, reason: '校验失败必须删包');
      await dir.delete(recursive: true);
    });

    test('verifySha256 匹配 → 通过且保留文件', () async {
      final dir = await Directory.systemTemp.createTemp('slive_sha_ok');
      final f = File('${dir.path}/good.apk');
      await f.writeAsBytes(List<int>.generate(1000, (i) => i % 256));
      final h = sha256.convert(await f.readAsBytes()).toString();
      await UpdateDownloader.verifySha256(f.path, h);
      expect(await f.exists(), isTrue);
      await dir.delete(recursive: true);
    });

    test('verifySha256 expected 为 null → 跳过（兼容旧清单）', () async {
      final dir = await Directory.systemTemp.createTemp('slive_sha_skip');
      final f = File('${dir.path}/x.apk');
      await f.writeAsString('whatever');
      await UpdateDownloader.verifySha256(f.path, null);
      expect(await f.exists(), isTrue);
      await dir.delete(recursive: true);
    });
  });

  group('UpdateDownloader 平台直链判定（无直链 = 不支持自动更新）', () {
    test('清单无本平台直链 → 不支持（iOS 未签名包场景）', () {
      final v = _v(10828,
          urls: {'other-platform': 'https://github.com/Howezzzzz/dart_simple_live/releases/download/v1.0.0/a.apk'});
      expect(UpdateDownloader.hasPlatformDirectLink(v), isFalse);
    });

    test('清单含本平台直链 → 支持', () {
      final v = _v(10828, urls: {
        UpdateDownloader.platformKey(): 'https://github.com/Howezzzzz/dart_simple_live/releases/download/v1.0.0/x.deb'
      });
      expect(UpdateDownloader.hasPlatformDirectLink(v), isTrue);
    });

    test('无本平台直链时 resolveDownloadUrl 回落 download_url（列表页）', () {
      final v = _v(10828,
          urls: {'other-platform': 'https://github.com/Howezzzzz/dart_simple_live/releases/download/v1.0.0/a.apk'});
      expect(UpdateDownloader.resolveDownloadUrl(v), _ownUrl);
    });
  });
}
