import 'package:material_ui/material_ui.dart';
import 'package:get/get.dart';
import 'package:remixicon/remixicon.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/app/utils/extensions/duration_2_str_utils.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/widgets/net_image.dart';

class FollowUserItem extends StatelessWidget {
  final FollowUser item;
  final Function()? onRemove;
  final Function()? onTap;
  final Function()? onLongPress;
  final bool playing;
  const FollowUserItem({
    required this.item,
    this.onRemove,
    this.onTap,
    this.onLongPress,
    this.playing = false,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    var site = Sites.allSites[item.siteId]!;
    return ListTile(
      contentPadding: AppStyle.edgeInsetsL16.copyWith(right: 4),
      leading: Stack(
        children: [
          NetImage(
            item.face,
            width: 48,
            height: 48,
            borderRadius: 24,
          ),
          // 正在观看：三角图标叠在主播头像上
          if (playing)
            Positioned.fill(
              child: Center(
                child: Container(
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(
                    color: Colors.black.withAlpha(110),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.play_arrow,
                    color: Colors.white,
                    size: 18,
                  ),
                ),
              ),
            ),
        ],
      ),
      title: Text(
        (item.remark ?? '').isNotEmpty ? item.remark! : item.userName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      // 每条信息单独一行：状态 / 平台 / 时长 / 标签
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // 状态行（放在平台上面）：直播中→「已开播 X」、未开播→「未开播」、未知→「读取中」
          // 两种状态都只占这一行 → 条目天然等高（Howe 2026-10-16 定的方案）
          Obx(
            () => Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: item.liveStatus.value == 2 ? Colors.green : Colors.grey,
                      borderRadius: AppStyle.radius12,
                    ),
                  ),
                  AppStyle.hGap4,
                  Text(
                    getStatusText(item),
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.normal,
                      color: item.liveStatus.value == 2 ? null : Colors.grey,
                    ),
                  ),
                ],
              ),
            ),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.asset(
                site.logo,
                width: 16,
              ),
              AppStyle.hGap4,
              Text(
                site.name,
                style: const TextStyle(
                  fontSize: 12,
                  color: Colors.grey,
                ),
              ),
            ],
          ),
          Obx(() {
            final mode = AppSettingsController.instance.followTimeMode.value;
            if (mode != FollowTimeMode.watchDuration) {
              // 开播时长已并入上方状态行（直播中→「已开播 X」）→ 此处不再单独占行
              return const SizedBox.shrink();
            }
            // 保持原显示逻辑：watchDuration 仍是活跃写入字段，避免旧数据（watchDurationSec 未回填）显示回退
            return Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                // ignore: deprecated_member_use_from_same_package
                item.watchDuration ?? "00:00:00",
                style: const TextStyle(
                  fontSize: 12,
                  color: Colors.grey,
                ),
              ),
            );
          }),
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              item.tag.length > 8 ? '${item.tag.substring(0, 8)}...' : item.tag,
              style: const TextStyle(
                fontSize: 12,
                color: Colors.grey,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      trailing: playing
          ? null
          : (onRemove == null
              ? null
              : IconButton(
                  onPressed: () {
                    onRemove?.call();
                  },
                  icon: const Icon(Remix.dislike_line),
                )),
      onTap: onTap,
      onLongPress: onLongPress,
    );
  }

  /// 状态行文案（与状态圆点同行，所以直播/未开播天然等高）：
  /// - 直播中（开播时长模式）→ 「已开播 X」；无开播时间戳或观看时长模式 → 「直播中」
  /// - 未开播 → 「未开播」；状态未知 → 「读取中」
  String getStatusText(FollowUser item) {
    final status = item.liveStatus.value;
    if (status == 0) {
      return "读取中";
    }
    if (status != 2) {
      return "未开播";
    }
    if (AppSettingsController.instance.followTimeMode.value == FollowTimeMode.watchDuration) {
      return "直播中";
    }
    final startTime = item.liveStartTime.value;
    if (startTime == null) {
      return "直播中";
    }
    final liveDuration = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(startTime * 1000));
    return "已开播 ${liveDuration.toLiveStartedString()}";
  }
}
