T? asT<T>(dynamic value) {
  if (value is T) {
    return value;
  }
  return null;
}

/// 解析开播时间戳（秒级）。
/// 支持 int 或数字字符串；非正数 / 解析失败返回 null（未开播或不可得）。
int? parseStartTime(dynamic value) {
  int? ts;
  if (value is int) {
    ts = value;
  } else if (value is String) {
    ts = int.tryParse(value);
  } else {
    return null;
  }
  return (ts != null && ts > 0) ? ts : null;
}
