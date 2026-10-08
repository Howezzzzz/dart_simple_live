extension DurationStringExtensions on String {
  /// 将 "HH:MM:SS" 格式的字符串转换为 Duration
  Duration toDuration() {
    final parts = split(':');
    if (parts.length != 3) {
      throw FormatException('Invalid duration format: $this');
    }

    final hours = int.tryParse(parts[0]) ?? 0;
    final minutes = int.tryParse(parts[1]) ?? 0;
    final seconds = int.tryParse(parts[2]) ?? 0;

    return Duration(hours: hours, minutes: minutes, seconds: seconds);
  }
}

extension DurationExtensions on Duration {
  /// 将 Duration 转换为紧凑格式的字符串（如 "2h30m15s"）
  String toHMSString() {
    final hours = inHours; // 计算总小时数
    final minutes = inMinutes.remainder(60); // 计算剩余分钟数
    final seconds = inSeconds.remainder(60); // 计算剩余秒数

    // 格式化分钟和秒为两位数
    final minutesStr = minutes.toString().padLeft(2, '0');
    final secondsStr = seconds.toString().padLeft(2, '0');

    return '$hours:$minutesStr:$secondsStr';
  }

  /// 将 Duration 转换为「开播了X小时Y分钟」中文格式（关注列表用）
  String toLiveStartedString() {
    final hours = inHours;
    final minutes = inMinutes.remainder(60);
    if (hours > 0) {
      return '开播了$hours小时$minutes分钟';
    }
    return '开播了$minutes分钟';
  }

  /// 将 Duration 转换为 HH:mm:ss（小时可为总小时数，支持跨天）
  String toHHMMSS() {
    final h = inHours.toString().padLeft(2, '0');
    final m = inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }
}
