import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
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
import 'package:simple_live_app/app/utils/font_file_check.dart';
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

  /// 2026-10-22 ISS-176：字体下载取消令牌（页面离开时取消）
  CancelToken? _fontDownloadCancel;

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
    // 2026-10-22 复核必改 B：换字体前先取消在跑的下载（否则旧任务变孤儿下载、状态错乱）
    cancelFontDownload();
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
    // 2026-10-22 ISS-176：防重入/防并发——重复点会并发写同一 .part；
    // 复核必改 B：守卫必须看令牌（换字体后 fontState 会被重置，光看状态会放过重入 → 孤儿下载）
    if (_fontDownloadCancel != null) return;
    final dbPath = AppSettingsController.instance.dbPath;
    final fontModel = curFontModel.value;
    if (fontModel == null) return;
    var fontName = fontModel.id;
    final fontDir = Directory("$dbPath/fonts/$fontName");
    if (!await fontDir.exists()) {
      await fontDir.create(recursive: true);
    }
    Log.d("开始下载----$fontName");
    fontState.value = DownloadState.downloading;
    // 2026-10-22 ISS-176：取消令牌（离开字体设置页时取消，不再后台白跑流量）
    final cancel = _fontDownloadCancel = CancelToken();
    var allOk = true;
    var canceled = false;
    try {
      for (var filePath in fontModel.files) {
        final fileName = filePath.split('/').last;
        final file = File("${fontDir.path}/$fileName");
        if (await file.exists()) {
          // 2026-10-22 ISS-175：已有文件先做内容校验，坏的就删掉重下
          // （否则会被当作「已存在」跳过，一直用坏字体）
          final check = await _checkFontFile(file);
          if (check.problem == null) continue; // 已存在且合法 → 跳过（保留原语义）
          Log.w(
            "字体文件校验不通过，删除重下：${file.path} -> ${check.problem}"
            "${check.unreadable ? "（读取异常）" : ""}",
          );
          try {
            await file.delete();
          } catch (_) {}
        }
        final ok = await _downloadFontFile(filePath, file.path, cancel);
        if (!ok) {
          if (cancel.isCancelled) {
            canceled = true;
            break; // 取消不算失败，不回弹提示（用户已离开页面）
          }
          allOk = false;
          Log.e("字体文件下载失败（所有源）：$filePath", StackTrace.current);
          break; // 单个文件全源失败 → 中止，不加载残缺字体
        }
      }
    } catch (e, s) {
      // 2026-10-22 复核必改 A：任何异常都要落到确定态，
      // 否则状态恒为 downloading → 守卫永久拦住后续下载（只能重启）
      Log.e("字体下载异常：$fontName", s);
      allOk = false;
    } finally {
      _fontDownloadCancel = null;
    }
    if (canceled) {
      Log.d("字体下载已取消----$fontName");
      // 取消不硬写 notDownloaded：若文件其实已齐全（取消发生在最后一个下完后）就按已下载
      fontState.value = await fontDownloadCheck(fontName) ? DownloadState.downloaded : DownloadState.notDownloaded;
      return;
    }
    if (!allOk) {
      fontState.value = DownloadState.notDownloaded;
      SmartDialog.showToast("下载失败，请检查网络后重试");
      return;
    }
    fontState.value = DownloadState.downloaded;
    await loadFont(fontName);
  }

  /// 离开字体设置页时调用：取消进行中的下载（ISS-176）
  void cancelFontDownload() {
    final token = _fontDownloadCancel;
    if (token == null || token.isCancelled) return;
    Log.d("取消字体下载（离开页面）");
    token.cancel("页面已离开");
  }

  /// 读取文件头做内容级校验（ISS-175）。
  /// 返回 (problem, unreadable)：problem=null 通过；unreadable=true 表示**读不出来**
  /// （I/O 问题，不能据此认定字体损坏——复核建议区分，避免杀软锁文件/网络盘抖动被判成损坏）。
  Future<({String? problem, bool unreadable})> _checkFontFile(File file) async {
    try {
      final raf = await file.open();
      try {
        // 同一句柄取长度，避免两次打开之间的竞态（复核建议）
        final len = await raf.length();
        final head = await raf.read(len < FontFileCheck.headBytes ? len : FontFileCheck.headBytes);
        return (problem: FontFileCheck.problem(head, len), unreadable: false);
      } finally {
        await raf.close();
      }
    } catch (e) {
      return (problem: "读取失败：$e", unreadable: true);
    }
  }

  /// 多源依次尝试下载单个字体文件（首个成功即用）；失败源清理 .part 残留。
  /// 2026-10-22：新增取消（ISS-176）与内容级校验（ISS-175，不良内容换下一个源）。
  Future<bool> _downloadFontFile(String filePath, String savePath, CancelToken cancel) async {
    for (final baseUrl in _fontBaseUrls) {
      if (cancel.isCancelled) return false;
      try {
        await HttpClient.instance.download("$baseUrl$filePath", savePath, cancel: cancel);
        final check = await _checkFontFile(File(savePath));
        if (check.problem == null) return true;
        Log.w("字体内容校验不通过（$baseUrl）：$filePath -> ${check.problem}");
        try {
          final f = File(savePath);
          if (await f.exists()) await f.delete(); // 换下一个源重试
        } catch (_) {}
      } catch (e) {
        if (cancel.isCancelled) {
          // 取消：清残留并立即结束，不再尝试其它源
          try {
            final part = File("$savePath.part");
            if (await part.exists()) await part.delete();
          } catch (_) {}
          return false;
        }
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
      curFontModel.value = fontMap.keys.firstWhere(
        (element) => element.id == curFontName.value,
        orElse: () => fontMap.keys.first,
      );
    } else {
      curFontModel.value = fontMap.keys.first;
    }
    // maybe curFontName = null
    fontState.value = await fontDownloadCheck(curFontModel.value!.id)
        ? DownloadState.downloaded
        : DownloadState.notDownloaded;

    Log.d("当前字体模型：${curFontModel.value!.id}");
  }

  Future<void> loadFont(String fontName) async {
    final dbPath = AppSettingsController.instance.dbPath;
    final fontDir = Directory("$dbPath/fonts/$fontName");
    final loader = FontLoader(fontName);

    // 2026-10-22 复核 P2：本函数挂在启动链（init → userFontInit → loadFont）且无兜底，
    // 任一文件读取失败会让 runApp 不执行（白屏）；本批又让 6 个 .otf 家族首次走进这条路径。
    try {
      await for (final entity in fontDir.list()) {
        // 2026-10-22 修复：原只认 .ttf → 6 个纯 .otf 家族（32 文件）根本加载不了
        if (entity is File && FontFileCheck.isFontFileName(entity.path)) {
          loader.addFont(entity.readAsBytes().then(ByteData.sublistView));
        }
      }
      await loader.load();
      Log.d('已加载$fontName 词库');
    } catch (e, s) {
      Log.e('加载字体失败（$fontName），回退系统默认字体', s);
    }
  }

  /// 字体是否「完整下载」（供 UI 状态与启动加载判断）。
  /// 2026-10-21 加固：已知期望文件数时要求文件齐全，避免「部分下载」被误判为已下载
  /// → 下次启动 loadFont 加载残缺字族（复核 P2）。取不到期望数时退回原「≥1 文件」语义。
  Future<bool> fontDownloadCheck(String fontName) async {
    final dbPath = AppSettingsController.instance.dbPath;
    final fontDir = Directory("$dbPath/fonts/$fontName");
    if (!await fontDir.exists()) return false;
    final expectedFiles = _expectedFontFiles(fontName);
    if (expectedFiles != null && expectedFiles.isNotEmpty) {
      // 2026-10-22 复核 P3：不再只数个数（目录里残留的多余文件会掩盖缺失），
      // 改为按清单逐个文件「存在 + 内容合法」精确校（每家族 ≤9 个文件）
      for (final path in expectedFiles) {
        final file = File("${fontDir.path}/${path.split('/').last}");
        if (!await file.exists()) return false;
        final check = await _checkFontFile(file);
        if (check.problem != null) {
          Log.w(
            "字体文件校验不通过：${file.path} -> ${check.problem}"
            "${check.unreadable ? "（读取异常，非内容损坏）" : ""}",
          );
          return false;
        }
      }
      return true;
    }
    // 清单取不到（异常情况）→ 退回「≥1 个字体文件 + 内容校验」的旧语义
    var count = 0;
    await for (final entity in fontDir.list()) {
      if (entity is File && FontFileCheck.isFontFileName(entity.path)) {
        final check = await _checkFontFile(entity);
        if (check.problem != null) {
          Log.w("字体文件校验不通过：${entity.path} -> ${check.problem}");
          return false;
        }
        count++;
      }
    }
    return count > 0;
  }

  /// 该字体的期望文件相对路径（清单里找不到返回 null → 退回数量校）
  List<String>? _expectedFontFiles(String fontName) {
    for (final f in fontMap.keys) {
      if (f.id == fontName) return f.files;
    }
    final cur = curFontModel.value;
    if (cur != null && cur.id == fontName) return cur.files;
    return null;
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
