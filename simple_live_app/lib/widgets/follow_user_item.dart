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
          // 直播状态（放在平台上面）
          Obx(
            () => Offstage(
              offstage: item.liveStatus.value == 0,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: item.liveStatus.value == 2
                            ? Colors.green
                            : Colors.grey,
                        borderRadius: AppStyle.radius12,
                      ),
                    ),
                    AppStyle.hGap4,
                    Text(
                      getStatus(item.liveStatus.value),
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.normal,
                        color:
                            item.liveStatus.value == 2 ? null : Colors.grey,
                      ),
                    ),
                  ],
                ),
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
            if (mode == FollowTimeMode.watchDuration) {
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
            }
            // 开播时长模式：仅直播中且有开播时间戳时显示
            final startTime = item.liveStartTime.value;
            if (item.liveStatus.value != 2 || startTime == null) {
              return const SizedBox.shrink();
            }
            final liveDuration = DateTime.now()
                .difference(DateTime.fromMillisecondsSinceEpoch(startTime * 1000));
            return Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                liveDuration.toLiveStartedString(),
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

  String getStatus(int status) {
    if (status == 0) {
      return "读取中";
    } else if (status == 1) {
      return "未开播";
    } else {
      return "直播中";
    }
  }
}
