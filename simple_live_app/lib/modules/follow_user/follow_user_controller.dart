// ignore_for_file: invalid_use_of_protected_member

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:get/get.dart';
import 'package:remixicon/remixicon.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/controller/base_controller.dart';
import 'package:simple_live_app/app/event_bus.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/models/db/account.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/follow_user_tag.dart';
import 'package:simple_live_app/routes/app_navigation.dart';
import 'package:simple_live_app/routes/route_path.dart';
import 'package:simple_live_app/services/follow_service.dart';
import 'package:simple_live_app/services/platform_service.dart';

class FollowUserController extends BasePageController<FollowUser> {
  StreamSubscription<dynamic>? onUpdatedIndexedStream;
  StreamSubscription<dynamic>? onUpdatedListStream;

  /// 0:全部 1:直播中 2:未直播
  var filterMode = FollowUserTag(id: "0", tag: "全部", userId: []).obs;
  RxList<FollowUserTag> tagList = [
    FollowUserTag(id: "0", tag: "全部", userId: []),
    FollowUserTag(id: "1", tag: "直播中", userId: []),
    FollowUserTag(id: "2", tag: "未开播", userId: []),
  ].obs;

  // 用户自定义标签
  RxList<FollowUserTag> userTagList = <FollowUserTag>[].obs;

  // 用户自定义显示顺序 - default：watchDuration
  Rx<SortMethod> sortMethod = SortMethod.watchDuration.obs;

  // 排序方式
  var sortMap = {
    SortMethod.watchDuration: "观看时长",
    SortMethod.siteId: "直播平台",
    SortMethod.recently: "最近添加",
    SortMethod.userNameASC: "用户名A-Z",
    SortMethod.userNameDESC: "用户名Z-A",
    SortMethod.tag: "自定义标签",
  };

  // 关注列表样式
  var followStyleMap = {true: "紧凑模式", false: "卡片模式"};

  @override
  void onInit() {
    onUpdatedIndexedStream = EventBus.instance.listen(
      EventBus.kBottomNavigationBarClicked,
      (index) {
        if (index == 1) {
          scrollToTopOrRefresh();
        }
      },
    );
    onUpdatedListStream = FollowService.instance.updatedListStream.listen(
      (event) {
        updateTagList();
        filterData();
      },
    );

    sortMethod = AppSettingsController.instance.followSortMethod;
    super.onInit();
  }

  @override
  Future refreshData() async {
    await FollowService.instance.loadData();
    updateTagList();
    super.refreshData();
  }

  @override
  /// 平台筛选：空串=全部平台，否则为站点 id（bilibili/douyu/...）
  var platformFilter = ''.obs;

  /// 当前关注里出现过的平台（按 Sites 定义顺序）
  List<String> get platforms {
    final ids = <String>{
      for (final f in FollowService.instance.followList) f.siteId,
    };
    final res = <String>[];
    for (final id in Sites.allSites.keys) {
      if (ids.remove(id)) {
        res.add(id);
      }
    }
    res.addAll(ids);
    return res;
  }

  void setPlatformFilter(String siteId) {
    platformFilter.value = siteId;
    refreshData();
  }

  /// 从关注页进入「同步关注的主播」：
  /// 仅对已登录且支持网页登录/关注接口的平台（B站/斗鱼）开放；多个则先让其选择。
  void openFollowSync() {
    final candidates = PlatformService.instance.accountList
        .where((a) =>
            a.isActive &&
            (a.siteId == Constant.kBiliBili || a.siteId == Constant.kDouyu))
        .toList();
    if (candidates.isEmpty) {
      SmartDialog.showToast("请先在「账号管理」登录 哔哩哔哩/斗鱼 账号");
      return;
    }
    if (candidates.length == 1) {
      _goFollowSync(candidates.first.siteId);
      return;
    }
    Utils.showBottomSheet(
      title: "从哪个平台同步关注？",
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: candidates.map<Widget>((Account ac) {
          final site = Sites.allSites[ac.siteId];
          return ListTile(
            leading: site == null
                ? const Icon(Icons.live_tv)
                : Image.asset(site.logo, width: 32, height: 32),
            title: Text(site?.name ?? ac.siteId),
            subtitle: Text(ac.userName ?? ""),
            onTap: () {
              Get.back();
              _goFollowSync(ac.siteId);
            },
          );
        }).toList(),
      ),
    );
  }

  void _goFollowSync(String siteId) {
    Get.toNamed(RoutePath.kFollowSync, arguments: siteId)?.then((_) {
      refreshData();
    });
  }

  Future<List<FollowUser>> getData(int page, int pageSize) async {
    if (page > 1) {
      return Future.value([]);
    }
    FollowService.instance.filterDataByTag(filterMode.value);
    var base = FollowService.instance.curTagFollowList.value;
    if (platformFilter.value.isNotEmpty) {
      base = base.where((u) => u.siteId == platformFilter.value).toList();
    }
    return base;
  }

  void updateTagList() {
    userTagList.assignAll(FollowService.instance.followTagList);
    tagList.value = tagList.take(3).toList();
    for (var i in userTagList) {
      if (!tagList.contains(i)) {
        tagList.add(i);
      }
    }
  }

  // 数据清洗：不关心中间 data_flow，最终由filterData决定显示数据
  void filterData() {
    bool hideOffline = AppSettingsController.instance.hideOfflineFollow.value;

    FollowService.instance.filterDataByTag(filterMode.value, hideOffline: hideOffline);
    list.assignAll(FollowService.instance.curTagFollowList);
    if (platformFilter.value.isNotEmpty) {
      list.retainWhere((user) => user.siteId == platformFilter.value);
    }
  }

  // 用户自定义关注样式
  Future<void> showFollowStyleDialog() async {
    var res = await Utils.showMapOptionDialog(
      title: "关注样式切换",
      followStyleMap,
      AppSettingsController.instance.followStyleNotGrid.value,
    );
    if (res != null) {
      AppSettingsController.instance.setFollowStyleNotGrid(res);
    }
  }

  // 用户自定义顺序dialog
  Future<void> showSortDialog() async {
    var res = await Utils.showMapOptionDialog(sortMap, sortMethod.value, title: "排序方式");
    if (res != null) {
      sortMethod.value = res;
      AppSettingsController.instance.setFollowSortMethod(sortMethod.value);
      if (filterMode.value.tag == "未开播" || filterMode.value.tag == "全部" || filterMode.value.tag == "直播中") {
        FollowService.instance.liveListSort();
      }
      filterData();
    }
  }

  void setFilterMode(FollowUserTag tag) {
    filterMode.value = tag;
    filterData();
  }

  void removeFollow(FollowUser follow) async {
    var result = await Utils.showAlertDialog("确定要取消关注${follow.userName}吗?", title: "取消关注");
    if (!result) {
      return;
    }
    // 取消关注同时删除标签内的 userId
    if (follow.tag != "全部") {
      var tag = tagList.firstWhereOrNull((tag) => tag.tag == follow.tag);
      if (tag != null) {
        tag.userId.remove(follow.id);
        updateTag(tag);
      }
    }
    await FollowService.instance.removeFollowUser(follow.id);
    filterData();
  }

  Future<void> updateFollow(FollowUser follow) async {
    await FollowService.instance.addFollow(follow);
  }

  void setFollowTag(FollowUser follow, FollowUserTag targetTag) {
    FollowService.instance.setFollowTag(follow, targetTag);
    filterData();
  }

  Future<void> updateTag(FollowUserTag followUserTag) async {
    await FollowService.instance.updateFollowUserTag(followUserTag);
  }

  // 弹出底部菜单栏
  void showBottomMenu(FollowUser item) {
    Get.bottomSheet(
      SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Remix.price_tag_3_line),
              title: const Text('设置标签'),
              onTap: () {
                Get.back();
                setFollowTagDialog(item);
              },
            ),
            ListTile(
              leading: const Icon(Remix.information_line),
              title: const Text('查看详情'),
              onTap: () {
                Get.back();
                AppNavigator.toFollowInfo(item);
              },
            ),
          ],
        ),
      ),
      backgroundColor: Get.theme.cardColor,
    );
  }

  void setFollowTagDialog(FollowUser follow) {
    /// 控制单选ui
    List<FollowUserTag> copiedList = [
      tagList.first,
      ...tagList.skip(3),
    ];
    Rx<FollowUserTag> checkTag = tagList.indexOf(filterMode.value) < 3 ? copiedList.first.obs : filterMode.value.obs;
    final ScrollController scrollController = ScrollController();
    Get.dialog(
      AlertDialog(
        contentPadding: const EdgeInsets.all(16.0),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12.0),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 标题栏
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  '设置标签',
                  style: TextStyle(
                    fontSize: 18,
                  ),
                ),
                IconButton(
                  icon: const Icon(
                    Icons.check,
                  ),
                  onPressed: () {
                    setFollowTag(follow, checkTag.value);
                    Get.back();
                  },
                ),
              ],
            ),
            const Divider(),
            Obx(
              () {
                int selectedIndex = copiedList.indexOf(checkTag.value);
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (selectedIndex >= 0) {
                    scrollController.animateTo(
                      selectedIndex * 60.0, // 假设每项高度为 60
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeInOut,
                    );
                  }
                });
                return SizedBox(
                  height: 300,
                  width: 300,
                  child: RadioGroup<FollowUserTag>(
                    groupValue: checkTag.value,
                    onChanged: (value) {
                      checkTag.value = value!;
                    },
                    child: ListView.builder(
                      controller: scrollController,
                      itemCount: copiedList.length,
                      itemBuilder: (context, index) {
                        var tagItem = copiedList[index];
                        return Container(
                          decoration: BoxDecoration(
                            border: Border(
                              bottom: BorderSide(color: Colors.grey.shade300, width: 1.0),
                            ),
                          ),
                          child: RadioListTile<FollowUserTag>(
                            title: Text(tagItem.tag),
                            value: tagItem,
                          ),
                        );
                      },
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  void onClose() {
    onUpdatedIndexedStream?.cancel();
    onUpdatedListStream?.cancel();
    super.onClose();
  }
}
