import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:remixicon/remixicon.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/app/utils/grid_columns.dart';
import 'package:simple_live_app/modules/follow_user/follow_user_controller.dart';
import 'package:simple_live_app/routes/app_navigation.dart';
import 'package:simple_live_app/routes/route_path.dart';
import 'package:simple_live_app/services/follow_service.dart';
import 'package:simple_live_app/widgets/filter_button.dart';
import 'package:simple_live_app/widgets/follow_user_card.dart';
import 'package:simple_live_app/widgets/follow_user_item.dart';
import 'package:simple_live_app/widgets/keep_alive_wrapper.dart';
import 'package:simple_live_app/widgets/page_grid_view.dart';

class FollowUserPage extends GetView<FollowUserController> {
  const FollowUserPage({super.key});

  @override
  Widget build(BuildContext context) {
    // 紧凑样式（关注条目卡）列数：ceil 封顶 + 最小列宽夹逼（列宽 ≤340 不拉伸；
    // 手机竖屏仍 1 列，与旧算法一致）。旧 floor 算法会把列宽拉到接近 2*340，
    // 且列数随窗口宽微小变化跳变 → 网格整体重排、条目位置漂移。
    var count = gridColumnsForWidth(MediaQuery.of(context).size.width);
    // 卡片样式列数：floor(width/200) —— 常规宽度下卡宽 ≥200；窄屏被下限强抬到 2 列时
    // 卡宽可能略 <200（沿用旧行为）；上限 10 收住超宽屏（2560/3840）的无穷铺列。
    var c = MediaQuery.of(context).size.width ~/ 200;
    if (c < 2) {
      c = 2;
    } else if (c > 10) {
      c = 10;
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text("关注用户"),
        actions: [
          IconButton(
            icon: const Icon(Icons.sync),
            tooltip: "同步关注的主播",
            onPressed: () => controller.openFollowSync(),
          ),
          PopupMenuButton(
            itemBuilder: (context) {
              return const [
                PopupMenuItem(
                  value: 0,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Remix.trophy_line),
                      AppStyle.hGap12,
                      Text("赛事订阅"),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 1,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Remix.blender_line),
                      AppStyle.hGap12,
                      Text("模式切换"),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 2,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Remix.sort_asc),
                      AppStyle.hGap12,
                      Text("按序排列"),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 4,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Remix.heart_line),
                      AppStyle.hGap12,
                      Text("关注设置"),
                    ],
                  ),
                ),
              ];
            },
            onSelected: (value) {
              if (value == 4) {
                Get.toNamed(RoutePath.kSettingsFollow);
              } else if (value == 0) {
                SmartDialog.showToast("此功能暂未开放！敬请期待！");
              } else if (value == 1) {
                controller.showFollowStyleDialog();
              } else if (value == 2) {
                controller.showSortDialog();
              }
            },
          ),
        ],
        leading: Obx(
          () => FollowService.instance.updating.value
              ? const IconButton(
                  onPressed: null,
                  icon: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                    ),
                  ),
                )
              : IconButton(
                  onPressed: () {
                    controller.refreshData();
                  },
                  icon: const Icon(Icons.refresh),
                ),
        ),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: AppStyle.edgeInsetsL8,
            child: Row(
              children: [
                Expanded(
                  child: Obx(
                    () => SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Wrap(
                        spacing: 12,
                        children: controller.tagList.map(
                          (option) {
                            return FilterButton(
                              text: option.tag,
                              selected: controller.filterMode.value == option,
                              onTap: () {
                                controller.setFilterMode(option);
                              },
                            );
                          },
                        ).toList(),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          // 平台筛选（仅当关注里有多个平台时显示）
          // Obx 包住整个门控：platforms 读的是 RxList(followList)，异步加载完成后需能重建
          // （原门控在 Obx 外读 Rx，列表异步到达时可能不出现筛选行）
          Obx(
            () => controller.platforms.length > 1
                ? Padding(
                    padding: AppStyle.edgeInsetsL8.copyWith(top: 8, bottom: 4),
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Wrap(
                        spacing: 12,
                        children: [
                          FilterButton(
                            leading: const Icon(Icons.apps, size: 16, color: Colors.grey),
                            text: "全部平台",
                            selected: controller.platformFilter.value.isEmpty,
                            onTap: () => controller.setPlatformFilter(''),
                          ),
                          ...controller.platforms.map(
                            (id) => FilterButton(
                              leading: Sites.allSites[id] == null
                                  ? const Icon(Icons.live_tv, size: 16)
                                  : Image.asset(
                                      Sites.allSites[id]!.logo,
                                      width: 16,
                                      height: 16,
                                    ),
                              text: Sites.allSites[id]?.name ?? id,
                              selected: controller.platformFilter.value == id,
                              onTap: () => controller.setPlatformFilter(id),
                            ),
                          ),
                        ],
                      ),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
          Expanded(
            child: KeepAliveWrapper(
              child: Obx(
                () {
                  // temp
                  final hide = AppSettingsController.instance.hideRemoveFollowButton.value;
                  var mode = AppSettingsController.instance.followStyleNotGrid.value;
                  var crossCount = mode ? count : c;
                  var padding = mode ? null : AppStyle.edgeInsetsA12;
                  double mainAxisSpacing = mode ? 0.0 : 12.0;
                  return PageGridView(
                    pageController: controller,
                    padding: padding,
                    firstRefresh: true,
                    showPCRefreshButton: false,
                    mainAxisSpacing: mainAxisSpacing,
                    crossAxisSpacing: 12,
                    crossAxisCount: crossCount,
                    alignRows: mode,
                    itemBuilder: (_, i) {
                      var item = controller.list[i];
                      var site = Sites.allSites[item.siteId]!;
                      return mode
                          ? FollowUserItem(
                              item: item,
                              onRemove: () {
                                controller.removeFollow(item);
                              },
                              onTap: () {
                                AppNavigator.toLiveRoomDetail(site: site, roomId: item.roomId);
                              },
                              onLongPress: () {
                                // 长按弹出操作：设置标签或查看详情
                                controller.showBottomMenu(item);
                              },
                            )
                          : FollowUserCard(
                              item,
                              onFollowRemove: hide ? null : () => controller.removeFollow(item),
                              onLongPress: () {
                                // 长按弹出操作：设置标签或查看详情
                                controller.showBottomMenu(item);
                              },
                            );
                    },
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}
