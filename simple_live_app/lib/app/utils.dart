import 'dart:io';
import 'dart:math' as math;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/services.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:remixicon/remixicon.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:intl/intl.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'package:material_ui/material_ui.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/utils/permission_handler.dart';
import 'package:simple_live_app/requests/common_request.dart';
import 'package:simple_live_app/modules/update_flow/update_flow_page.dart';

typedef TextValidate = bool Function(String text);

class Utils {
  static late PackageInfo packageInfo;
  static DateFormat dateFormat = DateFormat("MM-dd HH:mm");
  static DateFormat dateFormatWithYear = DateFormat("yyyy-MM-dd HH:mm");
  static DateFormat timeFormat = DateFormat("HH:mm:ss");

  /// 处理时间
  static String parseTime(DateTime? dt) {
    if (dt == null) {
      return "";
    }

    var dtNow = DateTime.now();
    if (dt.year == dtNow.year && dt.month == dtNow.month && dt.day == dtNow.day) {
      return "${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}";
    }

    if (dt.year == dtNow.year) {
      return dateFormat.format(dt);
    }

    return dateFormatWithYear.format(dt);
  }

  /// 提示弹窗
  /// - `content` 内容
  /// - `title` 弹窗标题
  /// - `confirm` 确认按钮内容，留空为确定
  /// - `cancel` 取消按钮内容，留空为取消
  static Future<bool> showAlertDialog(
    String content, {
    String title = '',
    String confirm = '',
    String cancel = '',
    bool selectable = false,
    List<Widget>? actions,
  }) async {
    var result = await Get.dialog(
      AlertDialog(
        title: Text(title),
        content: Container(
          constraints: const BoxConstraints(
            maxHeight: 400,
          ),
          child: SingleChildScrollView(
            child: Padding(
              padding: AppStyle.edgeInsetsV12,
              child: selectable ? SelectableText(content) : Text(content),
            ),
          ),
        ),
        actions: [
          ...?actions,
          TextButton(
            onPressed: (() => Get.back(result: false)),
            child: Text(cancel.isEmpty ? "取消" : cancel),
          ),
          TextButton(
            onPressed: (() => Get.back(result: true)),
            child: Text(confirm.isEmpty ? "确定" : confirm),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  /// 提示弹窗
  /// - `content` 内容
  /// - `title` 弹窗标题
  /// - `confirm` 确认按钮内容，留空为确定
  static Future<bool> showMessageDialog(String content,
      {String title = '', String confirm = '', bool selectable = false}) async {
    var result = await Get.dialog(
      AlertDialog(
        title: Text(title),
        content: Padding(
          padding: AppStyle.edgeInsetsV12,
          child: selectable ? SelectableText(content) : Text(content),
        ),
        actions: [
          TextButton(
            onPressed: (() => Get.back(result: true)),
            child: Text(confirm.isEmpty ? "确定" : confirm),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  static void showRightDialog({
    required String title,
    Function()? onDismiss,
    required Widget child,
    double width = 320,
    bool useSystem = false,
  }) {
    SmartDialog.show(
      alignment: Alignment.topRight,
      animationBuilder: (controller, child, animationParam) {
        //从右到左
        return SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(1, 0),
            end: Offset.zero,
          ).animate(controller.view),
          child: child,
        );
      },
      useSystem: useSystem,
      maskColor: Colors.transparent,
      animationTime: const Duration(milliseconds: 200),
      builder: (context) => Material(
        color: Get.theme.cardColor,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(4),
          bottomLeft: Radius.circular(4),
        ),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          width: width + MediaQuery.of(context).padding.right,
          child: Padding(
            padding: EdgeInsets.only(
              right: MediaQuery.of(context).padding.right,
            ),
            child: SafeArea(
              left: false,
              right: false,
              child: MediaQuery(
                data: const MediaQueryData(padding: EdgeInsets.zero),
                child: Column(
                  children: [
                    ListTile(
                      visualDensity: VisualDensity.compact,
                      contentPadding: EdgeInsets.zero,
                      leading: IconButton(
                        onPressed: () {
                          SmartDialog.dismiss(status: SmartStatus.allCustom).then(
                            (value) => onDismiss?.call(),
                          );
                        },
                        icon: const Icon(Icons.arrow_back),
                      ),
                      title: Text(
                        title,
                        style: Get.textTheme.titleMedium,
                      ),
                    ),
                    Divider(
                      height: 1,
                      color: Colors.grey.withAlpha(25),
                    ),
                    Expanded(
                      child: child,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  static void showScRightDialog({
    String? title,
    Function()? onDismiss,
    required Widget child,
    int? duration,
    double width = 300,
    bool useSystem = false,
  }) {
    SmartDialog.show(
      alignment: Alignment.topRight,
      animationBuilder: (controller, child, animationParam) {
        //从右到左
        return SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(1, 0),
            end: Offset.zero,
          ).animate(controller.view),
          child: child,
        );
      },
      tag: 'sc',
      keepSingle: true,
      maskColor: Colors.transparent,
      animationTime: const Duration(milliseconds: 200),
      displayTime: duration != null ? Duration(seconds: duration) : null,
      builder: (context) => Material(
        color: duration != null ? Colors.transparent : Get.theme.cardColor,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(4),
          bottomLeft: Radius.circular(4),
        ),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          width: width + MediaQuery.of(context).padding.right,
          child: Padding(
            padding: EdgeInsets.only(
              right: MediaQuery.of(context).padding.right,
            ),
            child: SafeArea(
              left: false,
              right: false,
              child: MediaQuery(
                data: const MediaQueryData(padding: EdgeInsets.zero),
                child: Column(
                  children: [
                    // hide title when auto-sc
                    ...(title != null
                        ? [
                            ListTile(
                              visualDensity: VisualDensity.compact,
                              contentPadding: EdgeInsets.zero,
                              leading: IconButton(
                                onPressed: () {
                                  SmartDialog.dismiss(status: SmartStatus.allCustom).then(
                                    (value) => onDismiss?.call(),
                                  );
                                },
                                icon: const Icon(Icons.arrow_back),
                              ),
                              title: Text(
                                title,
                                style: Get.textTheme.titleMedium,
                              ),
                            ),
                            Divider(
                              height: 1,
                              color: Colors.grey.withAlpha(25),
                            ),
                          ]
                        : []),
                    Expanded(
                      child: child,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  static void hideRightDialog() {
    SmartDialog.dismiss(status: SmartStatus.allCustom);
  }

  static Future showBottomSheet({
    required String title,
    required Widget child,
    double maxWidth = 600,
  }) async {
    var result = await showModalBottomSheet(
      context: Get.context!,
      constraints: BoxConstraints(
        maxWidth: maxWidth,
      ),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(12),
          topRight: Radius.circular(12),
        ),
      ),
      builder: (_) => Column(
        children: [
          ListTile(
            contentPadding: const EdgeInsets.only(
              left: 12,
            ),
            title: Text(title),
            trailing: IconButton(
              onPressed: Get.back,
              icon: const Icon(Remix.close_line),
            ),
          ),
          Expanded(
            child: child,
          ),
        ],
      ),
    );
    return result;
  }

  /// 文本编辑的弹窗
  /// - `content` 编辑框默认的内容
  /// - `title` 弹窗标题
  /// - `confirm` 确认按钮内容
  /// - `cancel` 取消按钮内容
  static Future<String?> showEditTextDialog(
    String content, {
    String title = '',
    String? hintText,
    String confirm = '',
    String cancel = '',
    TextValidate? validate,
    List<Widget>? actions,
    TextEditingController? textController,
  }) async {
    final TextEditingController textEditingController = textController ?? TextEditingController(text: content);
    var result = await Get.dialog(
      AlertDialog(
        title: Text(title),
        content: Padding(
          padding: AppStyle.edgeInsetsT12,
          child: TextFormField(
            controller: textEditingController,
            autofocus: true,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              contentPadding: AppStyle.edgeInsetsA12,
              hintText: hintText ?? title,
            ),
            autovalidateMode: AutovalidateMode.onUserInteraction,
            validator: (text) {
              if (validate == null) return null;
              return validate(text ?? '') ? null : '内容格式不正确';
            },
          ),
        ),
        actions: [
          ...?actions,
          TextButton(
            onPressed: Get.back,
            child: const Text("取消"),
          ),
          TextButton(
            onPressed: () {
              if (validate != null && !validate(textEditingController.text)) {
                return;
              }

              Get.back(result: textEditingController.text);
            },
            child: const Text("确定"),
          ),
        ],
      ),
      // barrierColor:
      //     Get.isDarkMode ? Colors.grey.withOpacity(.3) : Colors.black38,
    );
    return result;
  }

  /// 多行文本编辑的弹窗
  /// - `items` 文本项配置
  /// - `title` 弹窗标题
  /// - `confirm` 确认按钮内容
  /// - `cancel` 取消按钮内容
  static Future<Map<String, String>?> showEditTextsDialog(
    List<TextEditItem> items, {
    String title = '',
    String confirm = '',
    String cancel = '',
  }) async {
    final controllers = items.map((item) => TextEditingController(text: item.value)).toList();
    final result = await Get.dialog<Map<String, String>>(
      AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (int i = 0; i < items.length; i++) ...[
                if (i > 0) const SizedBox(height: 12),
                TextField(
                  controller: controllers[i],
                  autofocus: i == 0,
                  obscureText: items[i].obscureText,
                  keyboardType: items[i].keyboardType,
                  decoration: InputDecoration(
                    border: const OutlineInputBorder(),
                    contentPadding: AppStyle.edgeInsetsA12,
                    labelText: items[i].label,
                    hintText: items[i].hintText,
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: Get.back,
            child: Text(
              cancel.isEmpty ? '取消' : cancel,
            ),
          ),
          TextButton(
            onPressed: () {
              for (int i = 0; i < items.length; i++) {
                final validate = items[i].validate;
                if (validate != null && !validate(controllers[i].text)) {
                  return;
                }
              }
              Get.back(
                result: {
                  for (int i = 0; i < items.length; i++) items[i].key: controllers[i].text,
                },
              );
            },
            child: Text(
              confirm.isEmpty ? '确定' : confirm,
            ),
          ),
        ],
      ),
    );
    for (final controller in controllers) {
      controller.dispose();
    }
    return result;
  }

  static Future<T?> showOptionDialog<T>(
    List<T> contents,
    T value, {
    String title = '',
  }) async {
    var result = await Get.dialog(
      SimpleDialog(
        title: Text(title),
        children: [
          RadioGroup<T>(
            groupValue: value,
            onChanged: (e) {
              Get.back(result: e);
            },
            child: Column(
              children: contents
                  .map(
                    (e) => RadioListTile<T>(
                      title: Text(e.toString()),
                      value: e,
                    ),
                  )
                  .toList(),
            ),
          ),
        ],
      ),
    );
    return result;
  }

  static Future<T?> showInformationHelpDialog<T>({
    required List<Widget> content,
    Widget? title,
    List<Widget>? actions,
  }) async {
    var result = await Get.dialog(
      AlertDialog(
        title: title ?? const Text("帮助"),
        scrollable: true,
        content: SingleChildScrollView(child: ListBody(children: content)),
        actions: actions ??
            [
              TextButton(
                onPressed: Get.back,
                child: const Text("确定"),
              ),
            ],
      ),
    );
    return result;
  }

  static Future showStatement() async {
    var text = await rootBundle.loadString("assets/statement.txt");

    var result = await showAlertDialog(
      text,
      selectable: true,
      title: "免责声明",
      confirm: "已阅读并同意",
      cancel: "退出",
    );
    if (!result) {
      exit(0);
    }
  }

  static Future<T?> showMapOptionDialog<T>(
    Map<T, String> contents,
    T value, {
    String title = '',
  }) async {
    var result = await Get.dialog(
      SimpleDialog(
        title: Text(title),
        children: [
          RadioGroup<T>(
            groupValue: value,
            onChanged: (e) {
              Get.back(result: e);
            },
            child: Column(
              children: contents.keys
                  .map(
                    (e) => RadioListTile<T>(
                      title: Text((contents[e] ?? '-').tr),
                      value: e,
                    ),
                  )
                  .toList(),
            ),
          ),
        ],
      ),
    );
    return result;
  }

  static void checkUpdate({bool showMsg = false}) async {
    try {
      int currentVer = Utils.parseVersion(packageInfo.version);
      CommonRequest request = CommonRequest();
      var versionInfo = await request.checkUpdate();
      if (versionInfo.versionNum > currentVer) {
        // 2026-10-20 两轮修复：点「更新」后的下载/安装流程改走**全屏页面**（Get.to）。
        // 弹窗(Get.dialog)在该 App 与 SmartDialog.observer 叠加时存在内容不渲染问题（灰屏），
        // 页面 route 与普通页面同一渲染路径，无 barrier/遮罩问题。
        Get.to(() => UpdateFlowPage(version: versionInfo));
      } else {
        if (showMsg) {
          SmartDialog.showToast("当前已经是最新版本了");
        }
      }
    } catch (e) {
      Log.logPrint(e);
      if (showMsg) {
        SmartDialog.showToast("检查更新失败");
      }
    }
  }

  /// 版本号 → 单一整数，供「谁更新」比较。**App / CI / scripts 三处必须同一公式**。
  ///
  /// 公式（2026-10-25 统一，ISS-163）：`major*1000000 + minor*1000 + patch`；
  /// 各段上限 1000（CI 到 1000 进位，见 `publish_app_dev.yaml`）。
  /// 旧实现「逐段补零拼接」隐含「每段最多两位」，段到 100 时与 CI 乘法公式分叉
  /// （如 1.100.41：拼接 110041 vs 公式 20041）→ 现统一为同一公式，杜绝分叉。
  /// 兼容带构建号输入（`1.08.41+10841`）；无法解析的段按 0 处理，不抛异常。
  static int parseVersion(String version) {
    final sp = version.split('+').first.split('.');
    int seg(int i) => i < sp.length ? (int.tryParse(sp[i].trim()) ?? 0) : 0;
    return seg(0) * 1000000 + seg(1) * 1000 + seg(2);
  }

  /// 版本号显示格式：**major 不补零，minor/patch 恒两位**（2026-10-20 Howe 定）。
  /// 进位时保持段内两位，不跨点进位：`1.8.24 → 1.08.24`、`1.9.99 → 1.10.00`。
  /// 兼容带构建号输入（`1.8.24+10824`）与 Flutter 归一化后的版本（`1.10.0 → 1.10.00`）。
  static String formatVersion(String version) {
    final build = version.contains('+') ? '+${version.split('+').last}' : '';
    final sp = version.split('+').first.split('.');
    if (sp.length != 3) return version;
    return '${sp[0]}.${sp[1].padLeft(2, '0')}.${sp[2].padLeft(2, '0')}$build';
  }

  static String onlineToString(int num) {
    if (num >= 10000) {
      return "${(num / 10000.0).toStringAsFixed(1)}万";
    }
    return num.toString();
  }

  /// 检查相册权限
  static Future<bool> checkPhotoPermission() async {
    try {
      if (!Platform.isIOS) {
        return true;
      }
      var status = await Permission.photos.status;
      if (status == PermissionStatus.granted) {
        return true;
      }
      status = await Permission.photos.request();
      if (status.isGranted) {
        return true;
      } else {
        SmartDialog.showToast(
          "请授予相册访问权限",
        );
        return false;
      }
    } catch (e) {
      return false;
    }
  }

  static final DeviceInfoPlugin deviceInfo = DeviceInfoPlugin();

  /// 检查文件权限
  static Future<bool> checkStorgePermission() async {
    try {
      if (!Platform.isAndroid) {
        return true;
      }
      Permission permission = Permission.storage;
      var androidIndo = await deviceInfo.androidInfo;
      if (androidIndo.version.sdkInt >= 33) {
        permission = Permission.manageExternalStorage;
      }

      var status = await permission.status;
      if (status == PermissionStatus.granted) {
        return true;
      }
      status = await permission.request();
      if (status.isGranted) {
        return true;
      } else {
        SmartDialog.showToast(
          "请授予文件访问权限",
        );
        return false;
      }
    } catch (e) {
      return false;
    }
  }

  ///16进制颜色转换
  static Color convertHexColor(String hexColor) {
    hexColor = hexColor.replaceAll("#", "");
    if (hexColor.length == 4) {
      hexColor = "00$hexColor";
    }

    if (hexColor.length == 6) {
      var R = int.parse(hexColor.substring(0, 2), radix: 16);
      var G = int.parse(hexColor.substring(2, 4), radix: 16);
      var B = int.parse(hexColor.substring(4, 6), radix: 16);
      return Color.fromARGB(255, R, G, B);
    }
    if (hexColor.length == 8) {
      var A = int.parse(hexColor.substring(0, 2), radix: 16);
      var R = int.parse(hexColor.substring(2, 4), radix: 16);
      var G = int.parse(hexColor.substring(4, 6), radix: 16);
      var B = int.parse(hexColor.substring(6, 8), radix: 16);

      return Color.fromARGB(A, R, G, B);
    }

    return Colors.white;
  }

  /// 复制内容到剪贴板
  static void copyToClipboard(String text) async {
    try {
      await Clipboard.setData(ClipboardData(text: text));
      SmartDialog.showToast("已复制到剪贴板");
    } catch (e) {
      Log.logPrint(e);
      SmartDialog.showToast("复制到剪贴板失败: $e");
    }
  }

  /// 获取剪贴板内容
  static Future<String?> getClipboard() async {
    try {
      var content = await Clipboard.getData(Clipboard.kTextPlain);
      if (content == null) {
        SmartDialog.showToast("无法读取剪贴板内容");
        return null;
      }
      return content.text;
    } catch (e) {
      Log.logPrint(e);
      SmartDialog.showToast("读取剪切板内容失败：$e");
    }
    return null;
  }

  static bool isRegexFormat(String keyword) {
    return keyword.startsWith('/') && keyword.endsWith('/') && keyword.length > 2;
  }

  static String removeRegexFormat(String keyword) {
    return keyword.substring(1, keyword.length - 1);
  }

  static String parseFileSize(int size) {
    if (size < 1024) {
      return "$size B";
    }
    if (size < 1024 * 1024) {
      return "${(size / 1024).toStringAsFixed(2)} KB";
    }
    if (size < 1024 * 1024 * 1024) {
      return "${(size / 1024 / 1024).toStringAsFixed(2)} MB";
    }
    return "${(size / 1024 / 1024 / 1024).toStringAsFixed(2)} GB";
  }

  /// 随屏幕缩放比例调整
  static double scaleValue({
    required double value,
    required double playerH,
    required double designH,
    double upSens = 0.8,
    double downSens = 0.5,
    required double minSize,
    required double maxSize,
  }) {
    if (designH <= 0 || minSize >= maxSize) {
      return value;
    }
    // 限制
    double safeUpSens = upSens.clamp(0.0, 1.5);
    double safeDownSens = downSens.clamp(0.0, 1.0);
    var ratio = playerH / designH;
    // 双向控制放缩比率
    var adjustedRatio = ratio > 1 ? math.pow(ratio, safeUpSens).toDouble() : 1 - (1 - ratio) * safeDownSens;

    var result = value * adjustedRatio;
    var clamped = result.clamp(minSize, maxSize);
    return clamped.roundToDouble();
  }
}

class TextEditItem {
  final String key;
  final String value;
  final String? label;
  final String? hintText;
  final TextValidate? validate;
  final bool obscureText;
  final TextInputType? keyboardType;

  const TextEditItem({
    required this.key,
    this.value = '',
    this.label,
    this.hintText,
    this.validate,
    this.obscureText = false,
    this.keyboardType,
  });
}
