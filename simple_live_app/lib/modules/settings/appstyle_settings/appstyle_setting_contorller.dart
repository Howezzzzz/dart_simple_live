import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get_core/src/get_main.dart';
import 'package:get/get_instance/src/extension_instance.dart';
import 'package:get/get_navigation/src/extension_navigation.dart';
import 'package:get/get_rx/src/rx_types/rx_types.dart';
import 'package:get/get_state_manager/src/simple/get_controllers.dart';
import 'package:material_ui/material_ui.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/models/font_model.dart';
import 'package:simple_live_app/requests/http_client.dart';
import 'package:simple_live_app/services/local_storage_service.dart';

class AppStyleSettingController extends GetxController {
  static AppStyleSettingController get instance => Get.find<AppStyleSettingController>();

  var themeMode = 0.obs;
  var isDynamic = false.obs;
  var styleColor = 0xff3498db.obs;
  Rx<String?> curFontName = Rx<String?>(null);
  Rx<FontModel?> curFontModel = Rx<FontModel?>(null);
  final RxList<FontModel> fontList = <FontModel>[].obs;
  final RxMap<FontModel, String> fontMap = <FontModel, String>{}.obs;
  Rx<DownloadState> fontState = DownloadState.notDownloaded.obs;

  Future<void> init() async {
    styleColor.value = LocalStorageService.instance.getValue(LocalStorageService.kStyleColor, 0xff3498db);

    isDynamic.value = LocalStorageService.instance.getValue(LocalStorageService.kIsDynamic, false);
    await fetchFonts();
    await userFontInit();
  }

  Future<void> fontDelete() async {
    final dbPath = AppSettingsController.instance.dbPath;
    final fontDir = Directory("$dbPath/fonts/${curFontModel.value!.id}");
    try {
      // 删除整个目录（包括目录本身和所有内容）
      await fontDir.delete(recursive: true);
      await fontDir.create(recursive: true);
      var download = await fontDownloadCheck(curFontModel.value!.id);
      if (download == false) {
        fontState.value = DownloadState.notDownloaded;
      }
      SmartDialog.showToast("已删除${curFontModel.value!.name}字体");
      Log.d('目录${fontDir.path}已清空并重新创建');
    } catch (e, s) {
      Log.e('操作失败: $e', s);
    }
  }

  void fontReset() {
    if (Platform.isWindows) {
      curFontName.value = "Microsoft YaHei";
      LocalStorageService.instance.setValue(LocalStorageService.kCustomFont, curFontName.value);
    } else {
      curFontName.value = null;
      LocalStorageService.instance.removeValue(LocalStorageService.kCustomFont);
    }
    SmartDialog.showToast("已重置为默认字体！");
  }

  void changeFontFamily() {
    curFontName.value = curFontModel.value?.id;
    LocalStorageService.instance.setValue(LocalStorageService.kCustomFont, curFontName.value);
    SmartDialog.showToast("已设置全局字体为${curFontModel.value?.name}");
  }

  Future<void> onFontSelected(FontModel fontModel) async {
    var fontName = fontModel.id;
    curFontModel.value = fontModel;
    if (await fontDownloadCheck(fontName)) {
      fontState.value = DownloadState.downloaded;
      // 存在则加载并应用
      await loadFont(fontName);
    } else {
      fontState.value = DownloadState.notDownloaded;
    }
  }

  /// 字体下载源（2026-10-21 Howe 定：加国内可达源兜底，摆脱单点）。
  /// 字体仓库很大、单个字体文件 ~23MB（**超出 jsDelivr 单文件上限，实测该源返回 403**），
  /// 故 gh-proxy / ghproxy.cc 直连 raw 在前（实测 206 可下），jsDelivr 仅作小文件兑底。
  static const List<String> _fontBaseUrls = [
    "https://gh-proxy.com/https://raw.githubusercontent.com/SlotSun/fonts/master/",
    "https://ghproxy.cc/https://raw.githubusercontent.com/SlotSun/fonts/master/",
    "https://gcore.jsdelivr.net/gh/SlotSun/fonts@master/",
  ];

  Future<void> downloadFont() async {
    final dbPath = AppSettingsController.instance.dbPath;
    var fontName = curFontModel.value!.id;
    final fontDir = Directory("$dbPath/fonts/$fontName");
    if (!await fontDir.exists()) {
      await fontDir.create(recursive: true);
    }
    Log.d("开始下载----$fontName");
    fontState.value = DownloadState.downloading;
    var allOk = true;
    for (var filePath in curFontModel.value!.files) {
      final fileName = filePath.split('/').last;
      final file = File("${fontDir.path}/$fileName");
      if (await file.exists()) continue; // 已存在则跳过（保留原语义）
      final ok = await _downloadFontFile(filePath, file.path);
      if (!ok) {
        allOk = false;
        Log.e("字体文件下载失败（所有源）：$filePath", StackTrace.current);
        break; // 单个文件全源失败 → 中止，不加载残缺字体
      }
    }
    if (!allOk) {
      fontState.value = DownloadState.notDownloaded;
      SmartDialog.showToast("下载失败，请检查网络后重试");
      return;
    }
    fontState.value = DownloadState.downloaded;
    await loadFont(fontName);
  }

  /// 多源依次尝试下载单个字体文件（首个成功即用）；失败源清理 .part 残留。
  Future<bool> _downloadFontFile(String filePath, String savePath) async {
    for (final baseUrl in _fontBaseUrls) {
      try {
        await HttpClient.instance.download("$baseUrl$filePath", savePath);
        return true;
      } catch (e) {
        Log.w("字体源失败（$baseUrl）：$filePath -> $e");
        // HttpClient.download 先写 $savePath.part、成功后 rename；失败时清掉 .part 残留
        try {
          final part = File("$savePath.part");
          if (await part.exists()) await part.delete();
        } catch (_) {}
      }
    }
    return false;
  }

  Future<void> userFontInit() async {
    var fontName = LocalStorageService.instance.getNullValue<String?>(LocalStorageService.kCustomFont, null);
    Log.d('获取当前字体$fontName');
    if (fontName != null && fontName != "Microsoft YaHei") {
      // 确认本地是否存在此字体
      if (await fontDownloadCheck(fontName)) {
        // 存在则加载并应用
        await loadFont(fontName);
      } else {
        // 不存在则使用默认字体
        fontName = null;
      }
    }
    curFontName.value = fontName;
    if (curFontName.value != null) {
      curFontModel.value =
          fontMap.keys.firstWhere((element) => element.id == curFontName.value, orElse: () => fontMap.keys.first);
    } else {
      curFontModel.value = fontMap.keys.first;
    }
    // maybe curFontName = null
    fontState.value =
        await fontDownloadCheck(curFontModel.value!.id) ? DownloadState.downloaded : DownloadState.notDownloaded;

    Log.d("当前字体模型：${curFontModel.value!.id}");
  }

  Future<void> loadFont(String fontName) async {
    final dbPath = AppSettingsController.instance.dbPath;
    final fontDir = Directory("$dbPath/fonts/$fontName");
    final loader = FontLoader(fontName);

    await for (final entity in fontDir.list()) {
      if (entity is File && entity.path.endsWith('.ttf')) {
        loader.addFont(entity.readAsBytes().then(ByteData.sublistView));
      }
    }
    await loader.load();
    Log.d('已加载$fontName 词库');
  }

  /// 字体是否「完整下载」（供 UI 状态与启动加载判断）。
  /// 2026-10-21 加固：已知期望文件数时要求文件齐全，避免「部分下载」被误判为已下载
  /// → 下次启动 loadFont 加载残缺字族（复核 P2）。取不到期望数时退回原「≥1 文件」语义。
  Future<bool> fontDownloadCheck(String fontName) async {
    final dbPath = AppSettingsController.instance.dbPath;
    final fontDir = Directory("$dbPath/fonts/$fontName");
    if (!await fontDir.exists()) return false;
    final ttfCount = await fontDir.list().where((e) => e is File && e.path.endsWith('.ttf')).length;
    if (ttfCount == 0) return false;
    final expected = _expectedFontFileCount(fontName);
    return expected <= 0 || ttfCount >= expected;
  }

  /// 该字体的期望文件数（从已加载字体清单取；取不到返回 0 = 不校验）。
  int _expectedFontFileCount(String fontName) {
    for (final f in fontMap.keys) {
      if (f.id == fontName) return f.files.length;
    }
    final cur = curFontModel.value;
    if (cur != null && cur.id == fontName) return cur.files.length;
    return 0;
  }

  Future<void> fetchFonts() async {
    try {
      final jsonStr = await rootBundle.loadString('assets/fonts/fonts-manifest.json');
      final List<dynamic> list = json.decode(jsonStr);
      // 集合推导构造fontMap
      fontMap.assignAll(
        {
          for (final e in list) FontModel.fromJson(e): (e['name'] as String? ?? ''),
        },
      );
    } catch (e, s) {
      Log.e("Failed to fetch fonts manifest: $e", s);
    }
  }

  void setIsDynamic(bool e) {
    isDynamic.value = e;
    LocalStorageService.instance.setValue(LocalStorageService.kIsDynamic, e);
  }

  void changeTheme() {
    Get.dialog(
      SimpleDialog(
        title: const Text("设置主题"),
        children: [
          RadioGroup<int>(
            groupValue: themeMode.value,
            onChanged: (e) {
              Get.back();
              setTheme(e ?? 0);
            },
            child: Column(
              children: [
                RadioListTile<int>(
                  title: const Text("跟随系统"),
                  value: 0,
                ),
                RadioListTile<int>(
                  title: const Text("浅色模式"),
                  value: 1,
                ),
                RadioListTile<int>(
                  title: const Text("深色模式"),
                  value: 2,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void setTheme(int i) {
    themeMode.value = i;
    var mode = ThemeMode.values[i];

    LocalStorageService.instance.setValue(LocalStorageService.kThemeMode, i);
    Get.changeThemeMode(mode);
  }

  void setStyleColor(int e) {
    styleColor.value = e;
    LocalStorageService.instance.setValue(LocalStorageService.kStyleColor, e);
  }
}
