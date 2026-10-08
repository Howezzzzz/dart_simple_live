import 'package:simple_live_core/src/common/convert_helper.dart';
import 'package:test/test.dart';

void main() {
  group('parseStartTime', () {
    test('int 秒级时间戳', () {
      expect(parseStartTime(1791394615), 1791394615);
    });

    test('数字字符串', () {
      expect(parseStartTime('1791394615'), 1791394615);
    });

    test('0（未开播）返回 null', () {
      expect(parseStartTime(0), isNull);
      expect(parseStartTime('0'), isNull);
    });

    test('负数返回 null', () {
      expect(parseStartTime(-1), isNull);
    });

    test('非法字符串返回 null', () {
      expect(parseStartTime('abc'), isNull);
      expect(parseStartTime('0000-00-00 00:00:00'), isNull);
    });

    test('null 返回 null', () {
      expect(parseStartTime(null), isNull);
    });
  });
}
