import 'package:simple_live_app/app/utils/extensions/duration_2_str_utils.dart';

/// 关注条目「状态行」文案（**纯函数、无 Flutter 依赖**，因此可在本地与 CI 直接测试）。
///
/// 设计约束（Howe 2026-10-16）：直播中与未开播**只占同一行** → 条目天然等高，
/// 不再需要额外占位行。
///
/// - 直播中（开播时长模式且有开播时间戳）→ 「开播了X小时Y分钟」
///   （`toLiveStartedString()` 自带「开播了」前缀，**不要再叠加**，否则文案重复）
/// - 直播中（观看时长模式 / 无开播时间戳）→ 「直播中」
/// - 未开播 → 「未开播」；状态未知（尚未刷新）→ 「读取中」
///
/// 保证：任一状态都返回**单行非空**文案（等高不变式）。
String followStatusText({
  required int liveStatus,
  int? liveStartTime,
  required bool watchDurationMode,
  DateTime? now,
}) {
  if (liveStatus == 0) {
    return "读取中";
  }
  if (liveStatus != 2) {
    return "未开播";
  }
  if (watchDurationMode || liveStartTime == null) {
    return "直播中";
  }
  final liveDuration = (now ?? DateTime.now())
      .difference(DateTime.fromMillisecondsSinceEpoch(liveStartTime * 1000));
  return liveDuration.toLiveStartedString();
}
