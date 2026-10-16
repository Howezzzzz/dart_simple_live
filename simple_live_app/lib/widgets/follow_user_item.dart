import 'package:material_ui/material_ui.dart';
import 'package:get/get.dart';
import 'package:remixicon/remixicon.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/app/utils/follow_status_text.dart';
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
    return Container(
      decoration: BoxDecoration(
        gradient: playing
            ? LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: [
                  Colors.red.withValues(alpha: 0.06),
                  Colors.transparent,
                ],
              )
            : null,
      ),
      child: ListTile(
        contentPadding: AppStyle.edgeInsetsL16.copyWith(right: 4),
        leading: Stack(
          children: [
            NetImage(
              item.face,
              width: 48,
              height: 48,
              borderRadius: 24,
            ),
            // 正在观看：头像上叠一个播放三角
            if (playing)
              Positioned.fill(
                child: Center(
                  child: Container(
                    width: 26,
                    height: 26,
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.43),
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
        // 主播名独占一行（状态不再与名字同行）
        title: Text(
          item.remark?.isNotEmpty == true ? item.remark! : item.userName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // 状态行（在主播名下面一行）：直播中→「开播了X」、未开播→「未开播」、未知→「读取中」
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
                    Flexible(
                      child: Text(
                        getStatusText(item),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.normal,
                          color: item.liveStatus.value == 2 ? null : Colors.grey,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // 平台行
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
            // 标签行（另起一行）
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text.rich(
                TextSpan(
                  children: [
                    WidgetSpan(
                      alignment: PlaceholderAlignment.bottom,
                      child: Icon(Remix.price_tag_3_line, size: 15, color: Colors.grey),
                    ),
                    const TextSpan(text: '_'),
                    TextSpan(text: item.tag),
                  ],
                ),
                style: const TextStyle(fontSize: 12, color: Colors.grey),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        trailing: onRemove == null
            ? null
            : IconButton(
                onPressed: () {
                  onRemove?.call();
                },
                icon: const Icon(Remix.dislike_line),
              ),
        onTap: onTap,
        onLongPress: onLongPress,
      ),
    );
  }

  String getStatusText(FollowUser item) => followStatusText(
        liveStatus: item.liveStatus.value,
        liveStartTime: item.liveStartTime.value,
        watchDurationMode: false,
      );
}
