import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/utils/follow_status_text.dart';

/// 回归守卫（RT-106，L1 自查发现项）：
/// 关注条目状态行文案——直播中显示开播时长、未开播显示「未开播」，**同一行 → 天然等高**。
///
/// 两个已修问题：
/// 1) `toLiveStartedString()` 自带「开播了」前缀，曾被再叠加一层 → 显示重复；
/// 2) 各状态必须都只产生**一行**（不等高就是因为行数不同）。
void main() {
  final now = DateTime.fromMillisecondsSinceEpoch(1760000000000);
  final startedAt = now.subtract(const Duration(hours: 2, minutes: 30)).millisecondsSinceEpoch ~/ 1000;

  test('未开播 → 「未开播」', () {
    expect(
      followStatusText(liveStatus: 1, watchDurationMode: false, now: now),
      '未开播',
    );
  });

  test('状态未知 → 「读取中」', () {
    expect(
      followStatusText(liveStatus: 0, watchDurationMode: false, now: now),
      '读取中',
    );
  });

  test('直播中（开播时长模式）→ 开播了2小时30分钟（且不重复前缀）', () {
    final text = followStatusText(
      liveStatus: 2,
      liveStartTime: startedAt,
      watchDurationMode: false,
      now: now,
    );
    expect(text, '开播了2小时30分钟');
    expect('开播了'.allMatches(text).length, 1, reason: '前缀只能出现一次');
  });

  test('直播中但无开播时间戳 → 回退「直播中」', () {
    expect(
      followStatusText(liveStatus: 2, watchDurationMode: false, now: now),
      '直播中',
    );
  });

  test('直播中但观看时长模式 → 「直播中」（时长在另一行显示）', () {
    expect(
      followStatusText(liveStatus: 2, liveStartTime: startedAt, watchDurationMode: true, now: now),
      '直播中',
    );
  });

  test('等高不变式：四种状态都只产出一行（无换行、非空）', () {
    final texts = [
      followStatusText(liveStatus: 0, watchDurationMode: false, now: now),
      followStatusText(liveStatus: 1, watchDurationMode: false, now: now),
      followStatusText(liveStatus: 2, liveStartTime: startedAt, watchDurationMode: false, now: now),
      followStatusText(liveStatus: 2, watchDurationMode: true, now: now),
    ];
    for (final t in texts) {
      expect(t.isNotEmpty, isTrue);
      expect(t.contains('\n'), isFalse, reason: '状态行必须单行，否则条目不等高');
    }
  });
}
