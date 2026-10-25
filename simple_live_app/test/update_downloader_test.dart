import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
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
  // flutter_test 绑定会把 HttpClient 换成「一律回 400」的假客户端；本文件的下载用例
  // 要打**真实本地服务器**（验续传/206/断流），先解除该 HTTP 覆盖。
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

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

    test('取消 token → 中断在飞的测速探测（ISS-161/168）', () async {
      // 起一个「只收不回」的本地服务器：探测会一直挂到超时；只有取消真的透传到探测请求，
      // 才能在取消后迅速返回（否则要挂满 timeout）。
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((_) {/* 接受连接但永不响应 */});
      final base = 'http://127.0.0.1:${server.port}/x';
      final token = CancelToken();
      final fut = UpdateDownloader.rankBySpeed(
        [base, '$base?b'],
        timeout: const Duration(seconds: 30),
        cancelToken: token,
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final sw = Stopwatch()..start();
      token.cancel();
      final r = await fut;
      sw.stop();
      expect(sw.elapsed.inSeconds, lessThan(3), reason: '取消后应迅速返回，而非挂满 30s');
      expect(r, hasLength(2), reason: '全部失败 → 保序返回全部候选（兜底）');
      await server.close(force: true);
    });
  });

  group('UpdateDownloader.download（断点续传 / 内容隔离，ISS-162）', () {
    late Directory root;
    HttpServer? httpServer;
    ServerSocket? rawServer;

    List<int> pkg(int n, int seed) => List<int>.generate(n, (i) => (i * 7 + seed * 31 + 13) & 0xff);
    String shaHex(List<int> b) => sha256.convert(b).toString();
    const asset = 'app-arm64-v8a-release.apk';

    setUp(() async {
      root = await Directory.systemTemp.createTemp('slive_dl_t');
      // 测试环境没有 path_provider 实现 → mock 其平台通道，把临时目录指到本用例沙盒
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => call.method == 'getTemporaryDirectory' ? root.path : null,
      );
    });

    tearDown(() async {
      await httpServer?.close(force: true);
      await rawServer?.close();
      if (await root.exists()) await root.delete(recursive: true);
    });

    Future<String> serve(Future<void> Function(HttpRequest) handle) async {
      final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      s.listen((req) async {
        try {
          await handle(req);
        } catch (_) {}
      });
      httpServer = s;
      return 'http://127.0.0.1:${s.port}/pkg/$asset';
    }

    test('预置半截 + 服务器 206 补齐 → 字节完整、断点按内容隔离', () async {
      final p = pkg(200000, 1);
      final sha = shaHex(p);
      final folder = Directory('${root.path}/slive_dl_${sha.substring(0, 8)}')..createSync(recursive: true);
      File('${folder.path}/$asset').writeAsBytesSync(p.sublist(0, p.length ~/ 2));
      var sawRange = false;
      final url = await serve((req) async {
        final r0 = req.headers.value('range');
        final n = r0 == null ? 0 : (int.tryParse(r0.split('=').last.split('-').first) ?? 0);
        if (n > 0) sawRange = true;
        final r = req.response
          ..statusCode = n > 0 ? 206 : 200
          ..contentLength = p.length - n;
        if (n > 0) r.headers.set('content-range', 'bytes $n-${p.length - 1}/${p.length}');
        r.add(p.sublist(n));
        await r.close();
      });
      final path = await UpdateDownloader.download(url, expectedSha256: sha);
      expect(sawRange, isTrue, reason: '存在残留断点时应带 Range 续传');
      expect(File(path).readAsBytesSync(), orderedEquals(p));
      expect(path, contains('slive_dl_${sha.substring(0, 8)}'), reason: '断点目录应以内容 sha 为键');
    });

    test('服务器不支持 Range（恒 200 全量）+ 已有残留 → 从头覆盖，绝不拼接', () async {
      final p = pkg(120000, 2);
      final sha = shaHex(p);
      final folder = Directory('${root.path}/slive_dl_${sha.substring(0, 8)}')..createSync(recursive: true);
      File('${folder.path}/$asset').writeAsBytesSync(List<int>.filled(p.length ~/ 2, 0x41));
      var sawRange = false;
      final url = await serve((req) async {
        if (req.headers.value('range') != null) sawRange = true;
        final r = req.response
          ..statusCode = 200
          ..contentLength = p.length;
        r.add(p);
        await r.close();
      });
      final path = await UpdateDownloader.download(url, expectedSha256: sha);
      expect(sawRange, isTrue, reason: '有残留就该先试着带 Range');
      expect(File(path).readAsBytesSync(), orderedEquals(p), reason: '服务器回 200 时必须从头覆盖，不能追加');
    });

    test('无 expectedSha256 → 不续传、不建断点目录、整包覆盖', () async {
      final p = pkg(90000, 3);
      File('${root.path}/$asset').writeAsBytesSync(List<int>.filled(p.length ~/ 3, 0x42));
      var sawRange = false;
      final url = await serve((req) async {
        if (req.headers.value('range') != null) sawRange = true;
        final r = req.response
          ..statusCode = 200
          ..contentLength = p.length;
        r.add(p);
        await r.close();
      });
      final path = await UpdateDownloader.download(url);
      expect(sawRange, isFalse, reason: '没有 sha 就不该续传（无法校验拼接结果）');
      expect(path, '${root.path}/$asset');
      expect(File(path).readAsBytesSync(), orderedEquals(p));
      expect(root.listSync().where((e) => e.path.startsWith('${root.path}/slive_dl_')), isEmpty);
    });

    test('跨版本隔离：不同 sha → 不同断点目录，同名安卓资产不串用', () async {
      final pa = pkg(50000, 4);
      final pb = pkg(70000, 5);
      var cur = pa;
      final url = await serve((req) async {
        final r = req.response
          ..statusCode = 200
          ..contentLength = cur.length;
        r.add(cur);
        await r.close();
      });
      final fa = await UpdateDownloader.download(url, expectedSha256: shaHex(pa));
      cur = pb;
      final fb = await UpdateDownloader.download(url, expectedSha256: shaHex(pb));
      expect(fa, isNot(fb), reason: '不同版本的断点必须落在不同目录');
      expect(File(fa).readAsBytesSync(), orderedEquals(pa));
      expect(File(fb).readAsBytesSync(), orderedEquals(pb));
    });

    test('中途断流 → 抛错且已下部分保留 → 再次调用可续传补齐', () async {
      final p = pkg(200000, 6);
      final sha = shaHex(p);
      var first = false;
      final ss = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      rawServer = ss;
      ss.listen((sock) {
        final buf = <int>[];
        late StreamSubscription<Uint8List> sub;
        sub = sock.listen((data) async {
          buf.addAll(data);
          final head = String.fromCharCodes(buf);
          if (!head.contains('\r\n\r\n')) return;
          await sub.cancel();
          final m = RegExp(r'[Rr]ange:\s*bytes=(\d+)-').firstMatch(head);
          if (m == null && !first) {
            first = true;
            sock.write('HTTP/1.1 200 OK\r\nContent-Length: ${p.length}\r\n\r\n');
            sock.add(p.sublist(0, p.length ~/ 2));
            await sock.flush();
            sock.destroy(); // 强行断流（模拟网络中断）
            return;
          }
          final n = m == null ? 0 : int.parse(m.group(1)!);
          if (n > 0) {
            sock.write('HTTP/1.1 206 Partial Content\r\n'
                'Content-Range: bytes $n-${p.length - 1}/${p.length}\r\n'
                'Content-Length: ${p.length - n}\r\n\r\n');
            sock.add(p.sublist(n));
          } else {
            sock.write('HTTP/1.1 200 OK\r\nContent-Length: ${p.length}\r\n\r\n');
            sock.add(p);
          }
          await sock.flush();
          await sock.close();
        });
      });
      final url = 'http://127.0.0.1:${ss.port}/pkg/$asset';
      final partialPath = '${root.path}/slive_dl_${sha.substring(0, 8)}/$asset';
      await expectLater(UpdateDownloader.download(url, expectedSha256: sha), throwsA(anything));
      final kept = File(partialPath).existsSync() ? File(partialPath).lengthSync() : -1;
      expect(kept, greaterThan(0), reason: '中断后应保留已下部分，供下次续传');
      expect(kept, lessThan(p.length));
      final path = await UpdateDownloader.download(url, expectedSha256: sha);
      expect(File(path).readAsBytesSync(), orderedEquals(p), reason: '下次调用应续传补齐');
    });

    test('sha256 不匹配 → 删文件 + 抛 UpdateDownloadException（防拼接错误的兜底）', () async {
      final p = pkg(30000, 7);
      final bad = shaHex(pkg(30000, 99));
      final url = await serve((req) async {
        final r = req.response
          ..statusCode = 200
          ..contentLength = p.length;
        r.add(p);
        await r.close();
      });
      await expectLater(
        UpdateDownloader.download(url, expectedSha256: bad),
        throwsA(isA<UpdateDownloadException>()),
      );
      final f = File('${root.path}/slive_dl_${bad.substring(0, 8)}/$asset');
      expect(await f.exists(), isFalse, reason: '校验失败应删掉坏文件');
    });
  });
}