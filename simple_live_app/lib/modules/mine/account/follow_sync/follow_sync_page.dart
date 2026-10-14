import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:simple_live_app/modules/mine/account/follow_sync/follow_sync_controller.dart';
import 'package:simple_live_app/services/follow_sync_service.dart';
import 'package:simple_live_app/widgets/net_image.dart';

/// 「从账号同步关注的主播」预览页。
class FollowSyncPage extends GetView<FollowSyncController> {
  const FollowSyncPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("同步关注的主播")),
      body: Obx(() {
        switch (controller.state.value) {
          case FollowSyncState.loading:
            return Obx(() => Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const CircularProgressIndicator(),
                      const SizedBox(height: 16),
                      Text("正在获取关注列表…已获取 ${controller.fetched.value} 条"),
                    ],
                  ),
                ));
          case FollowSyncState.error:
            return _buildError(context);
          case FollowSyncState.ready:
            return _buildReady(context);
        }
      }),
    );
  }

  Widget _buildError(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 48),
            const SizedBox(height: 12),
            const Text("关注列表获取失败（接口不可用或未登录）"),
            const SizedBox(height: 8),
            Text(
              controller.error.value,
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: controller.fetch,
              child: const Text("重试"),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildReady(BuildContext context) {
    if (controller.candidates.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            "没有获取到关注的主播。\n可能是：账号未登录、平台隐私设置隐藏了关注列表，或确实没有关注任何主播。",
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    final visible = controller.visible;
    return Column(
      children: [
        Obx(() => Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      "共 ${controller.candidates.length} 个 · 新增 ${controller.newCount} · 已关注 ${controller.existCount}",
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                  const Text("只看在播"),
                  Switch(
                    value: controller.onlyLive.value,
                    onChanged: (v) => controller.onlyLive.value = v,
                  ),
                ],
              ),
            )),
        if (controller.candidates.length > 80)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Text(
              "⚠️ 关注较多（${controller.candidates.length} 条）：全部导入后，App 刷新开播状态会向平台发大量请求，可能触发风控（表现为部分房间取不到详情/显示未开播）。建议只导入正在直播或常看的。",
              style: const TextStyle(fontSize: 12, color: Colors.orange),
            ),
          ),
        Expanded(
          child: visible.isEmpty
              ? const Center(child: Text("当前没有正在直播的主播"))
              : Obx(
                  () => ListView.builder(
                    itemCount: visible.length,
                    itemBuilder: (context, index) {
                      final c = visible[index];
                      return _tile(c);
                    },
                  ),
                ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
            child: Row(
              children: [
                TextButton(
                  onPressed: () => controller.selectAll(true),
                  child: const Text("全选"),
                ),
                TextButton(
                  onPressed: () => controller.selectAll(false),
                  child: const Text("全不选"),
                ),
                const Spacer(),
                Obx(() => FilledButton(
                      onPressed: controller.selected.isEmpty ||
                              controller.importing.value
                          ? null
                          : () => _doImport(context),
                      child: Text("导入选中 (${controller.selected.length})"),
                    )),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _tile(FollowSyncCandidate c) {
    return Obx(() => CheckboxListTile(
          value: controller.selected.contains(c.id),
          onChanged: (v) => controller.toggle(c.id, v ?? false),
          secondary: c.face.isEmpty
              ? const CircleAvatar(child: Icon(Icons.person))
              : NetImage(c.face, width: 40, height: 40, borderRadius: 20),
          title: Row(
            children: [
              Flexible(
                child: Text(
                  c.userName.isEmpty ? c.roomId : c.userName,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (c.live) ...[
                const SizedBox(width: 6),
                const Icon(Icons.circle, size: 8, color: Colors.red),
              ],
            ],
          ),
          subtitle: Text(
            "房间号 ${c.roomId}${c.existing ? " · 已关注" : ""}",
            style: const TextStyle(fontSize: 12),
          ),
        ));
  }

  Future<void> _doImport(BuildContext context) async {
    final added = await controller.doImport();
    SmartDialog.showToast("导入完成：新增 $added 个");
    Get.back();
  }
}
