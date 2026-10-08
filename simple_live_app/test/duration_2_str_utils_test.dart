import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/utils/extensions/duration_2_str_utils.dart';

void main() {
  group('DurationExtensions.toLiveStartedString', () {
    test('小时+分钟', () {
      expect(
        const Duration(hours: 3, minutes: 24).toLiveStartedString(),
        '开播了3小时24分钟',
      );
    });

    test('仅分钟', () {
      expect(
        const Duration(minutes: 45).toLiveStartedString(),
        '开播了45分钟',
      );
    });

    test('整小时', () {
      expect(
        const Duration(hours: 2).toLiveStartedString(),
        '开播了2小时0分钟',
      );
    });
  });

  group('DurationExtensions.toHHMMSS', () {
    test('标准格式', () {
      expect(
        const Duration(hours: 3, minutes: 24, seconds: 5).toHHMMSS(),
        '03:24:05',
      );
    });

    test('补零', () {
      expect(
        const Duration(minutes: 5, seconds: 3).toHHMMSS(),
        '00:05:03',
      );
    });

    test('跨天（总小时数）', () {
      expect(
        const Duration(hours: 26, minutes: 1, seconds: 59).toHHMMSS(),
        '26:01:59',
      );
    });
  });
}
