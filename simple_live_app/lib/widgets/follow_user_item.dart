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
import 'dart:ui' as ui;

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
      leading: NetImage(
        item.face,
        width: 48,
        height: 48,
        borderRadius: 24,
      ),
      title: Text.rich(
        TextSpan(
          text: item.remark?.isNotEmpty == true ? item.remark : item.userName,
          children: [
            WidgetSpan(
              alignment: ui.PlaceholderAlignment.middle,
              child: Obx(
                () => Offstage(
                  offstage: item.liveStatus.value == 0,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AppStyle.hGap12,
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
                        getStatus(item.liveStatus.value),
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
            ),
          ],
        ),
      ),
      subtitle: Wrap(
        runSpacing: 1.0,
        children: [
          Image.asset(
            site.logo,
            width: 20,
          ),
          AppStyle.hGap4,
          Text(
            site.name,
            style: const TextStyle(
              fontSize: 12,
              color: Colors.grey,
            ),
          ),
          AppStyle.hGap4,
          Obx(() {
            final mode = AppSettingsController.instance.followTimeMode.value;
            if (mode == FollowTimeMode.watchDuration) {
              // 保持原显示逻辑：watchDuration 仍是活跃写入字段，避免旧数据（watchDurationSec 未回填）显示回退
              return Text(
                // ignore: deprecated_member_use_from_same_package
                item.watchDuration ?? "00:00:00",
                style: const TextStyle(
                  fontSize: 12,
                  color: Colors.grey,
                ),
              );
            }
            // 开播时长模式：仅直播中且有开播时间戳时显示
            final startTime = item.liveStartTime.value;
            if (item.liveStatus.value != 2 || startTime == null) {
              return const SizedBox.shrink();
            }
            final liveDuration = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(startTime * 1000));
            return Text(
              liveDuration.toLiveStartedString(),
              style: const TextStyle(
                fontSize: 12,
                color: Colors.grey,
              ),
            );
          }),
          AppStyle.hGap4,
          Text(
            item.tag.length > 8 ? '${item.tag.substring(0, 8)}...' : item.tag,
            style: const TextStyle(
              fontSize: 12,
              color: Colors.grey,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
      trailing: playing
          ? const SizedBox(
              width: 64,
              child: Center(
                child: Icon(
                  Icons.play_arrow,
                ),
              ),
            )
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
