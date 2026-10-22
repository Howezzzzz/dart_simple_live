import 'dart:typed_data';

/// sfnt 魔数分类（顶层声明：Dart 不允许 enum 嵌套在类内）
enum _Magic { sfnt, otto, ttcf, trueType, typ1 }

/// 字体文件「内容级」轻量校验（2026-10-22，台账 ISS-175；同日按独立复核加固）
///
/// 背景：字体来自第三方仓库 `SlotSun/fonts` + 多个镜像/中转，现实故障有两类：
///   ① **传输截断**（连接中途断开；`dio.download` 不比对 content-length，可能"干净地"结束
///      → 留下截断文件）；
///   ② **镜像错误页**（HTML 或 `404: Not Found` 之类纯文本）被当成字体存下。
/// 旧逻辑只数「文件个数」（ISS-174 修复），内容断了的文件只要个数够仍被判定「已下载」并加载 → 乱码。
///
/// 刻意**不钉 sha256**：清单 56 家族/180 文件，源仓库随时可能换文件；钉哈希会像 flatpak 的
/// rustup-init sha 那样因上游更新集体失效（ISS-198 同类坑）。改用四层轻量判定：
///   ① 字体头魔数（sfnt / OTTO / ttcf / true / typ1）；
///   ② sfnt 表目录越界检查（任一表 offset+length 超过文件长度 = 铁证截断，与文件大小无关）；
///   ③ 纯文本/HTML 错误页嗅探（仅用于给出更准确的失败描述）；
///   ④ 最小体积兜底。
/// **解析不出来时不判失败**——只做能确证的判定，避免误杀合法字体。
class FontFileCheck {
  /// 最小可信体积（兜底）。实测清单内最小字体约 63KB，正常字体远大于此，错误页多在几 KB 内。
  /// （初版取 4096；复核指出将来若收录子集化小字体可能误杀，故降到 1024。）
  static const int minBytes = 1024;

  /// 建议读取的文件头长度：sfnt 表目录最长约 12 + 16×30 ≈ 500 字节，取 2048 留余量。
  static const int headBytes = 2048;

  /// 字体文件扩展名判定（与本仓库字体清单一致：`.ttf` / `.otf`）。
  ///
  /// ⚠️ 2026-10-22 修复：此前代码三处（`loadFont` / `fontDownloadCheck` / 校验循环）都**只认 `.ttf`**，
  /// 而清单 56 个家族里有 **6 个家族全部是 `.otf`**（32 个文件）→ 这些字体「选了不生效」
  /// （加载时被过滤掉）且被永远判为「未下载」。统一改用本判定。
  static bool isFontFileName(String path) {
    final p = path.toLowerCase();
    return p.endsWith('.ttf') || p.endsWith('.otf');
  }

  /// 校验结果：null = 通过；否则返回中文问题描述（用于日志与提示）。
  ///
  /// [head]：文件头若干字节（建议 [headBytes] 字节，用 `read(headBytes)` 取）；
  /// [fileLength]：文件总长度。
  static String? problem(Uint8List head, int fileLength) {
    if (head.length < 4) {
      return "文件头不完整（仅 ${head.length} 字节）";
    }
    final magic = _matchMagic(head);
    if (magic == null) {
      // ① 魔数不匹配：先看是不是错误页（能给出更准确的描述），再看体积
      if (looksLikeText(head)) {
        return "内容疑似错误页（非字体文件）";
      }
      if (fileLength < minBytes) {
        return "文件过小（$fileLength 字节，疑为截断或错误页）";
      }
      return "字体头非法（非 sfnt/OTTO/ttcf/true/typ1）";
    }
    if (fileLength < minBytes) {
      return "文件过小（$fileLength 字节，疑为截断）";
    }
    // ② sfnt / OTTO：表目录越界检查（ttcf 结构不同，跳过）
    if (magic == _Magic.sfnt || magic == _Magic.otto) {
      final bad = _sfntTableOutOfRange(head, fileLength);
      if (bad != null) return bad;
    }
    return null;
  }

  /// 是否疑似文本错误页（HTML / 纯文本）。判定：头 64 字节内**不含 NUL**（字体头必含 NUL）
  /// 且出现 HTML 或常见错误文案特征。
  static bool looksLikeText(Uint8List head) {
    final n = head.length < 64 ? head.length : 64;
    if (n == 0) return false;
    for (var i = 0; i < n; i++) {
      if (head[i] == 0x00) return false; // 含 NUL → 二进制，非文本错误页
    }
    final text = String.fromCharCodes(head.sublist(0, n)).toLowerCase().trim();
    return text.startsWith('<') ||
        text.contains('html') ||
        text.contains('not found') ||
        text.contains('error') ||
        text.contains('denied');
  }

  static _Magic? _matchMagic(Uint8List h) {
    if (_eq4(h, 0x00, 0x01, 0x00, 0x00)) return _Magic.sfnt;
    if (_eq4(h, 0x4F, 0x54, 0x54, 0x4F)) return _Magic.otto; // OTTO
    if (_eq4(h, 0x74, 0x74, 0x63, 0x66)) return _Magic.ttcf; // ttcf
    if (_eq4(h, 0x74, 0x72, 0x75, 0x65)) return _Magic.trueType; // true
    if (_eq4(h, 0x74, 0x79, 0x70, 0x31)) return _Magic.typ1; // typ1
    return null;
  }

  static bool _eq4(Uint8List h, int a, int b, int c, int d) =>
      h.length >= 4 && h[0] == a && h[1] == b && h[2] == c && h[3] == d;

  /// sfnt 表目录越界检查：任一表 `offset + length` 超过文件长度 → 明确截断/损坏。
  /// 头里看不到完整目录（表数过多）时返回 null（**不判定**，避免误杀）。
  static String? _sfntTableOutOfRange(Uint8List head, int fileLength) {
    if (head.length < 12) return null;
    final numTables = (head[4] << 8) | head[5];
    if (numTables == 0) return "字体表目录为空（损坏）";
    final need = 12 + 16 * numTables;
    if (fileLength < need) {
      return "字体表目录越界（文件长 $fileLength < 目录所需 $need，疑似截断）";
    }
    if (head.length < need) return null; // 头里看不全 → 不判定
    var maxEnd = 0;
    for (var i = 0; i < numTables; i++) {
      final base = 12 + i * 16;
      final offset = _u32(head, base + 8);
      final length = _u32(head, base + 12);
      final end = offset + length;
      if (end > maxEnd) maxEnd = end;
    }
    if (maxEnd > fileLength) {
      return "字体表数据越界（最大末端 $maxEnd > 文件长 $fileLength，疑似截断）";
    }
    return null;
  }

  static int _u32(Uint8List b, int i) => (b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3];
}
