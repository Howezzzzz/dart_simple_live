import 'package:material_ui/material_ui.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/modules/settings/appstyle_settings/appstyle_setting_contorller.dart';
import 'package:simple_live_app/widgets/settings/settings_card.dart';
import 'package:simple_live_app/widgets/settings/settings_menu.dart';
import 'package:simple_live_app/widgets/settings/settings_switch.dart';

class AppStyleSettingPage extends GetView<AppStyleSettingController> {
  const AppStyleSettingPage({super.key});

  Widget trailingBuild({required Widget widget}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Tooltip(
          message: "重置为默认字体",
          child: IconButton(
            onPressed: controller.fontReset,
            icon: Icon(Icons.settings_backup_restore_outlined),
          ),
        ),
        AppStyle.hGap4,
        Visibility(
          visible: controller.fontState.value == DownloadState.downloaded,
          child: Tooltip(
            message: "删除字体",
            child: IconButton(
              onPressed: controller.fontDelete,
              icon: Icon(Icons.delete_outline_outlined),
            ),
          ),
        ),
        Visibility(
          visible: controller.fontState.value == DownloadState.downloaded,
          child: AppStyle.hGap4,
        ),
        widget,
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // 2026-10-22 ISS-176：离开本页即取消进行中的字体下载（不再后台白跑流量）
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) controller.cancelFontDownload();
      },
      child: _CancelOnDispose(
        onDispose: controller.cancelFontDownload,
        child: Scaffold(
          appBar: AppBar(
            title: const Text("外观设置"),
          ),
          body: ListView(
            padding: AppStyle.edgeInsetsA12,
            children: [
              Padding(
                padding: AppStyle.edgeInsetsA12.copyWith(top: 0),
                child: Text(
                  "显示主题",
                  style: Get.textTheme.titleSmall,
                ),
              ),
              SettingsCard(
                child: Obx(
                  () => RadioGroup<int>(
                    groupValue: controller.themeMode.value,
                    onChanged: (e) {
                      controller.setTheme(e ?? 0);
                    },
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        RadioListTile<int>(
                          title: const Text(
                            "跟随系统",
                          ),
                          visualDensity: VisualDensity.compact,
                          value: 0,
                          contentPadding: AppStyle.edgeInsetsH12,
                        ),
                        RadioListTile<int>(
                          title: const Text(
                            "浅色模式",
                          ),
                          visualDensity: VisualDensity.compact,
                          value: 1,
                          contentPadding: AppStyle.edgeInsetsH12,
                        ),
                        RadioListTile<int>(
                          title: const Text(
                            "深色模式",
                          ),
                          visualDensity: VisualDensity.compact,
                          value: 2,
                          contentPadding: AppStyle.edgeInsetsH12,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              AppStyle.vGap12,
              Padding(
                padding: AppStyle.edgeInsetsA12,
                child: Text(
                  "主题颜色",
                  style: Get.textTheme.titleSmall,
                ),
              ),
              SettingsCard(
                child: Obx(
                  () => Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SettingsSwitch(
                        value: controller.isDynamic.value,
                        title: "动态取色",
                        onChanged: (e) {
                          controller.setIsDynamic(e);
                          Get.forceAppUpdate();
                        },
                      ),
                      if (!controller.isDynamic.value) AppStyle.divider,
                      if (!controller.isDynamic.value)
                        Padding(
                          padding: AppStyle.edgeInsetsA12,
                          child: Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children:
                                <Color>[
                                      const Color(0xffEF5350),
                                      const Color(0xff3498db),
                                      const Color(0xffF06292),
                                      const Color(0xff9575CD),
                                      const Color(0xff26C6DA),
                                      const Color(0xff26A69A),
                                      const Color(0xffFFF176),
                                      const Color(0xffFF9800),
                                    ]
                                    .map(
                                      (e) => GestureDetector(
                                        onTap: () {
                                          controller.setStyleColor(e.v);
                                          Get.forceAppUpdate();
                                        },
                                        child: Container(
                                          width: 36,
                                          height: 36,
                                          decoration: BoxDecoration(
                                            color: e,
                                            borderRadius: AppStyle.radius4,
                                            border: Border.all(
                                              color: Colors.grey.withAlpha(50),
                                              width: 1,
                                            ),
                                          ),
                                          child: Obx(
                                            () => Center(
                                              child: Icon(
                                                Icons.check,
                                                color: controller.styleColor.value == e.v
                                                    ? Colors.white
                                                    : Colors.transparent,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    )
                                    .toList(),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              AppStyle.vGap12,
              Padding(
                padding: AppStyle.edgeInsetsA12,
                child: Text(
                  "字体设置",
                  style: Get.textTheme.titleSmall,
                ),
              ),
              SettingsCard(
                child: Obx(
                  () => SettingsMenu(
                    title: controller.curFontModel.value!.name,
                    value: controller.curFontModel.value!,
                    valueMap: controller.fontMap,
                    onChanged: (e) {
                      controller.onFontSelected(e);
                    },
                    trailing: Obx(() {
                      switch (controller.fontState.value) {
                        case DownloadState.notDownloaded:
                          return trailingBuild(
                            widget: Tooltip(
                              message: "下载字体",
                              child: IconButton(
                                icon: const Icon(Icons.download_outlined),
                                onPressed: () => controller.downloadFont(),
                              ),
                            ),
                          );

                        case DownloadState.downloading:
                          return trailingBuild(
                            widget: SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          );
                        case DownloadState.downloaded:
                          return trailingBuild(
                            widget: Tooltip(
                              message: "应用字体",
                              child: IconButton(
                                icon: const Icon(Icons.check_circle_outline_outlined),
                                onPressed: () => controller.changeFontFamily(),
                              ),
                            ),
                          );
                      }
                    }),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 离页兜底：路由被**替换/移除**（`Get.off*`、`removeRoute`、外层 Navigator 销毁）时
/// `PopScope` 不会回调，用 dispose 兜住——对齐 `update_flow_page` 的既有做法（2026-10-22 复核建议）。
class _CancelOnDispose extends StatefulWidget {
  const _CancelOnDispose({required this.onDispose, required this.child});

  final VoidCallback onDispose;
  final Widget child;

  @override
  State<_CancelOnDispose> createState() => _CancelOnDisposeState();
}

class _CancelOnDisposeState extends State<_CancelOnDispose> {
  @override
  void dispose() {
    widget.onDispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

extension ColorExt on Color {
  static int _floatToInt8(double x) {
    return (x * 255.0).round() & 0xff;
  }

  int get v => _floatToInt8(a) << 24 | _floatToInt8(r) << 16 | _floatToInt8(g) << 8 | _floatToInt8(b) << 0;
}
