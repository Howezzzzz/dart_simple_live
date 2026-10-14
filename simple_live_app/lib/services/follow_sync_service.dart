import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/services/follow_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

/// 待导入的候选主播（从平台关注列表拉回、尚未并入本地）。
class FollowSyncCandidate {
  FollowSyncCandidate({
    required this.siteId,
    required this.roomId,
    required this.userName,
    required this.face,
    required this.live,
    required this.existing,
  });

  final String siteId;
  final String roomId;
  final String userName;
  final String face;

  /// 平台返回的当前是否在播
  final bool live;

  /// 本地是否已关注
  final bool existing;

  String get id => '${siteId}_$roomId';
}

/// 「从账号同步关注的主播」核心逻辑。
///
/// 只做增量导入：并入去重，不删除本地任何数据；失败抛异常（调用方区分三态）。
class FollowSyncService {
  FollowSyncService._();

  /// 单次同步最多拉取的页数（安全上限，防接口异常导致死循环）
  static const int maxPages = 60;

  /// 拉取指定站点「当前登录账号关注的主播」，并与本地关注比对。
  ///
  /// - 成功：返回候选列表（可能是空列表 = 确实没有关注）
  /// - 失败：抛异常（调用方应提示「接口不可用」，而不是「你没有关注」）
  static Future<List<FollowSyncCandidate>> fetch({
    required String siteId,
    LiveSite? site,
    Set<String>? localIds,
    void Function(int count)? onProgress,
  }) async {
    final liveSite = site ?? Sites.allSites[siteId]?.liveSite;
    if (liveSite == null) {
      throw Exception('未知站点：$siteId');
    }
    final local = localIds ??
        <String>{
          for (final f in FollowService.instance.followList) f.id,
        };
    final result = <FollowSyncCandidate>[];
    final seen = <String>{};
    for (var page = 1; page <= maxPages; page++) {
      final items = await liveSite.getFollowedAnchors(page: page);
      if (items.isEmpty) {
        break;
      }
      for (final it in items) {
        final id = '${siteId}_${it.roomId}';
        if (!seen.add(id)) {
          continue;
        }
        result.add(FollowSyncCandidate(
          siteId: siteId,
          roomId: it.roomId,
          userName: it.userName,
          face: it.avatar,
          live: it.liveStatus,
          existing: local.contains(id),
        ));
      }
      onProgress?.call(result.length);
      // 分页节流，降低触发风控的概率
      await Future.delayed(Duration(milliseconds: 120 + (page % 3) * 100));
    }
    return result;
  }

  /// 把选中的候选**并入**本地关注列表（去重，已有则更新，不删本地数据）。
  /// 返回本次新增数量。
  static Future<int> import(List<FollowSyncCandidate> selected) async {
    var added = 0;
    for (final c in selected) {
      final exist =
          FollowService.instance.followList.any((f) => f.id == c.id);
      final follow = FollowUser(
        id: c.id,
        roomId: c.roomId,
        siteId: c.siteId,
        userName: c.userName.isEmpty ? c.roomId : c.userName,
        face: c.face,
        addTime: DateTime.now(),
        tag: '全部',
      );
      await FollowService.instance.addFollow(follow);
      if (!exist) {
        added++;
      }
    }
    return added;
  }
}
