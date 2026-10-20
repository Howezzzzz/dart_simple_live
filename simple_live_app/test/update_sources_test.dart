import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/requests/common_request.dart';

void main() {
  group('CommonRequest.updateSources（更新检测多源择优）', () {
    final sources = CommonRequest.updateSources();

    test('至少 3 个源，且互不重复', () {
      expect(sources.length, greaterThanOrEqualTo(3));
      expect(sources.toSet().length, sources.length);
    });

    test('都指向同一份版本清单 app_version.json', () {
      for (final u in sources) {
        expect(u, contains('Howezzzzz/dart_simple_live'));
        expect(u, endsWith('assets/app_version.json'));
      }
    });

    test('国内镜像排在前，官方 raw 直连放最后兜底', () {
      expect(sources.first, contains('gitmirror'));
      expect(sources.last, startsWith('https://raw.githubusercontent.com/'));
    });

    test('含前缀式代理源（gh-proxy / ghproxy.cc）', () {
      expect(sources.any((u) => u.startsWith('https://gh-proxy.com/https://')), isTrue);
      expect(sources.any((u) => u.startsWith('https://ghproxy.cc/https://')), isTrue);
    });
  });
}
