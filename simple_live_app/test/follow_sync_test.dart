import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/services/follow_sync_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

class _FakeSite extends LiveSite {
  _FakeSite(this.pages);
  final List<List<LiveAnchorItem>> pages;
  int calls = 0;
  @override
  Future<List<LiveAnchorItem>> getFollowedAnchors({int page = 1}) async {
    calls++;
    if (page <= pages.length) {
      return pages[page - 1];
    }
    return <LiveAnchorItem>[];
  }
}

LiveAnchorItem _a(String room, {String name = '', bool live = false}) =>
    LiveAnchorItem(roomId: room, avatar: '', userName: name, liveStatus: live);

void main() {
  test('分页拉取直到空页，并按 siteId_roomId 去重', () async {
    final site = _FakeSite([
      [_a('1', name: 'A', live: true), _a('2', name: 'B')],
      [_a('1', name: 'A'), _a('3', name: 'C')],
      <LiveAnchorItem>[],
    ]);
    final list = await FollowSyncService.fetch(
      siteId: 'bilibili',
      site: site,
      localIds: <String>{},
    );
    expect(list.map((c) => c.id).toList(), ['bilibili_1', 'bilibili_2', 'bilibili_3']);
    expect(list.first.live, isTrue);
    expect(list.every((c) => !c.existing), isTrue);
    // 拉到空页才停：page1、page2、page3
    expect(site.calls, 3);
  });

  test('与本地比对：已关注的候选标记 existing', () async {
    final site = _FakeSite([
      [_a('1'), _a('2')],
      <LiveAnchorItem>[],
    ]);
    final list = await FollowSyncService.fetch(
      siteId: 'bilibili',
      site: site,
      localIds: {'bilibili_2'},
    );
    expect(list.firstWhere((c) => c.roomId == '2').existing, isTrue);
    expect(list.firstWhere((c) => c.roomId == '1').existing, isFalse);
  });

  test('空关注返回空列表（不抛异常）', () async {
    final site = _FakeSite([<LiveAnchorItem>[]]);
    final list = await FollowSyncService.fetch(
      siteId: 'bilibili',
      site: site,
      localIds: <String>{},
    );
    expect(list, isEmpty);
  });

  test('未知站点抛异常（不能当成「没有关注」）', () {
    expect(
      () => FollowSyncService.fetch(siteId: '__nope__', localIds: <String>{}),
      throwsA(isA<Exception>()),
    );
  });
}
