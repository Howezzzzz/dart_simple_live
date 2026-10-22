import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/utils/font_file_check.dart';

/// 造一个「结构自洽」的字体头（magic + sfnt 表目录），用于「通过 / 截断」两类用例。
Uint8List _fontHead({
  List<int> magic = const [0x00, 0x01, 0x00, 0x00],
  int fileLength = 4096,
  int numTables = 1,
  int tableOffset = 28,
  int tableLength = 4000,
  bool writeTableDir = true,
}) {
  final size = fileLength < FontFileCheck.headBytes ? fileLength : FontFileCheck.headBytes;
  final b = Uint8List(size);
  for (var i = 0; i < 4 && i < size; i++) {
    b[i] = magic[i];
  }
  if (writeTableDir && size >= 12) {
    b[4] = (numTables >> 8) & 0xFF;
    b[5] = numTables & 0xFF;
    for (var i = 0; i < numTables; i++) {
      final base = 12 + i * 16;
      if (base + 16 > size) break;
      b[base] = 0x74; // tag 'test'
      b[base + 1] = 0x65;
      b[base + 2] = 0x73;
      b[base + 3] = 0x74;
      _w32(b, base + 8, tableOffset);
      _w32(b, base + 12, tableLength);
    }
  }
  return b;
}

void _w32(Uint8List b, int i, int v) {
  b[i] = (v >> 24) & 0xFF;
  b[i + 1] = (v >> 16) & 0xFF;
  b[i + 2] = (v >> 8) & 0xFF;
  b[i + 3] = v & 0xFF;
}

/// 取文本前若干字节填进定长数组（模拟错误页响应体）
Uint8List _bytesFrom(List<int> raw, int size) {
  final b = Uint8List(size);
  for (var i = 0; i < raw.length && i < size; i++) {
    b[i] = raw[i] & 0xFF;
  }
  return b;
}

void main() {
  group('FontFileCheck.problem（2026-10-22 ISS-175 内容级校验）', () {
    test('合法 sfnt（表目录在文件内）→ 通过', () {
      expect(FontFileCheck.problem(_fontHead(), 4096), isNull);
    });

    test('合法 OTTO / ttcf / true / typ1 → 通过', () {
      expect(FontFileCheck.problem(_fontHead(magic: 'OTTO'.codeUnits), 4096), isNull);
      expect(FontFileCheck.problem(_fontHead(magic: 'ttcf'.codeUnits, writeTableDir: false), 4096), isNull);
      expect(FontFileCheck.problem(_fontHead(magic: 'true'.codeUnits, writeTableDir: false), 4096), isNull);
      expect(FontFileCheck.problem(_fontHead(magic: 'typ1'.codeUnits, writeTableDir: false), 4096), isNull);
    });

    test('大文件截断（表数据越界）→ 判为问题（复核必改 C 的漏检场景）', () {
      final reason = FontFileCheck.problem(
        _fontHead(fileLength: 200000, tableOffset: 20000, tableLength: 500000),
        200000,
      );
      expect(reason, isNotNull);
      expect(reason, contains('越界'));
    });

    test('文件过小（截断）→ 判为问题', () {
      final reason = FontFileCheck.problem(_fontHead(fileLength: 512), 512);
      expect(reason, isNotNull);
      expect(reason, contains('过小'));
    });

    test('纯文本错误体「404: Not Found」→ 判为问题（不靠 "<" 开头）', () {
      final reason = FontFileCheck.problem(_bytesFrom('404: Not Found'.codeUnits, 14), 14);
      expect(reason, isNotNull);
      expect(reason, contains('错误页'));
    });

    test('HTML 错误页 → 判为问题', () {
      final body = '<!DOCTYPE html><html><body>404</body></html>'.codeUnits;
      expect(FontFileCheck.problem(_bytesFrom(body, 5000), 5000), contains('错误页'));
    });

    test('带 UTF-8 BOM 的 HTML → 也能识别（真 BOM 字节 EF BB BF）', () {
      final raw = <int>[0xEF, 0xBB, 0xBF, ...'<html>denied</html>'.codeUnits];
      expect(FontFileCheck.problem(_bytesFrom(raw, 2000), 2000), contains('错误页'));
    });

    test('非法字体头 → 判为问题', () {
      final reason = FontFileCheck.problem(_fontHead(magic: [0xDE, 0xAD, 0xBE, 0xEF], writeTableDir: false), 5000);
      expect(reason, isNotNull);
      expect(reason, contains('非法'));
    });

    test('头部不足 4 字节 → 判为问题（不越界）', () {
      expect(FontFileCheck.problem(Uint8List.fromList([0x00, 0x01]), 9999), contains('不完整'));
    });
  });

  group('FontFileCheck.isFontFileName（.ttf/.otf）', () {
    test('.ttf / .otf 判为字体文件（含大写）', () {
      expect(FontFileCheck.isFontFileName('/a/b/JudouSansUiHans-Bold.ttf'), isTrue);
      expect(FontFileCheck.isFontFileName('/a/b/IBMPlexSansSC-Bold.otf'), isTrue);
      expect(FontFileCheck.isFontFileName(r'C:\x\Font.TTF'), isTrue);
    });

    test('其余判为非字体文件（.part 临时文件不能被当成字体）', () {
      expect(FontFileCheck.isFontFileName('/a/b/font.txt'), isFalse);
      expect(FontFileCheck.isFontFileName('/a/b/x.ttf.part'), isFalse);
      expect(FontFileCheck.isFontFileName('/a/b/ttf'), isFalse);
    });
  });
}
