import 'package:material_ui/material_ui.dart';
import 'package:remixicon/remixicon.dart';

class Constant {
  static const String kUpdateFollow = "UpdateFollow";
  static const String kUpdateHistory = "UpdateHistory";
  static const String kUpdateDanmaku = "UpdateDanmaku";

  static final Map<String, HomePageItem> allHomePages = {
    "recommend": HomePageItem(
      iconData: Remix.home_smile_line,
      title: "首页",
      index: 0,
    ),
    "follow": HomePageItem(
      iconData: Remix.heart_line,
      title: "关注",
      index: 1,
    ),
    "category": HomePageItem(
      iconData: Remix.apps_line,
      title: "分类",
      index: 2,
    ),
    "user": HomePageItem(
      iconData: Remix.user_smile_line,
      title: "我的",
      index: 3,
    ),
  };

  static const String kBiliBili = "bilibili";
  static const String kDouyu = "douyu";
  static const String kHuya = "huya";
  static const String kDouyin = "douyin";
  static const String kTwitch = "twitch";
}

class HomePageItem {
  final IconData iconData;
  final String title;
  final int index;
  HomePageItem({
    required this.iconData,
    required this.title,
    required this.index,
  });
}

enum DownloadState {
  notDownloaded,
  downloading,
  downloaded,
}

// 排序方法
enum SortMethod {
  watchDuration,
  siteId,
  recently,
  userNameASC,
  userNameDESC,
  tag,
}

// 关注列表时长显示模式
enum FollowTimeMode {
  /// 显示主播开播时长（直播中才显示）
  liveStartTime,

  /// 显示本地累计观看时长（原行为）
  watchDuration,
}

extension FollowTimeModeStore on FollowTimeMode {
  String get storeValue => name;
  static FollowTimeMode fromStore(String? v) {
    if (v == null) return FollowTimeMode.liveStartTime;
    return FollowTimeMode.values.firstWhere(
      (e) => e.name == v,
      orElse: () => FollowTimeMode.liveStartTime,
    );
  }
}

extension SortMethodStore on SortMethod {
  String get storeValue => name;
  static SortMethod fromStore(String? v) {
    if (v == null) return SortMethod.watchDuration;
    return SortMethod.values.firstWhere(
      (e) => e.name == v,
      orElse: () => SortMethod.watchDuration,
    );
  }
}
