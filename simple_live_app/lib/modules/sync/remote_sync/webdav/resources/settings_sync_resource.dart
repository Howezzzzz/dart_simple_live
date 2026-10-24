import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/modules/sync/remote_sync/webdav/interface/sync_resource.dart';
import 'package:simple_live_app/services/local_storage_service.dart';

class SettingsSyncResource implements SyncResource<Map<String, dynamic>> {
  @override
  String get fileName => "SimpleLive_Settings.json";

  /// 同步时要排除的本地键（设备本地/安全状态）——抽为静态列表便于回归测试（见 ISS-211）
  static const List<String> excludedSyncKeys = [
    LocalStorageService.kHiveDbVer,
    LocalStorageService.kWebDAVPassword,
    kAppSafeEnable,
    kAppAuthorName,
  ];

  @override
  Future<Map<String, dynamic>> loadLocal() async {
    var settingList = LocalStorageService.instance.settingsBox.toMap();
    // 不同步：数据库版本 / webdav 密码（防旧密码覆盖）/ 安全模式状态与哨兵。
    // 原因：安全模式是设备本地状态（密钥存于各设备系统安全存储），跨设备同步会使对端
    // appSafeEnable=true 但密钥解不开 → 触发破坏性 reset() 清空全部账号（见 ISS-211）
    for (final key in excludedSyncKeys) {
      settingList.remove(key);
    }
    // make cur and remote data_struct: {'Platform.operatingSystem':settingList}
    var curLocal = {
      LocalStorageService.kHiveDbVer: AppSettingsController.instance.dbVer,
      Platform.operatingSystem: settingList
    };
    return curLocal;
  }

  @override
  Map<String, dynamic>? loadRemote(Archive archive) {
    final file = archive.findFile(fileName);
    if (file == null) return null;
    final jsonData = jsonDecode(utf8.decode(file.content));
    // {khiveDbVer:xx, platform_xx: settingMap}
    return jsonData['data'] as Map<String, dynamic>?;
  }

  @override
  Future<void> saveLocal(Map<String, dynamic> data) async {
    try {
      var platform = Platform.operatingSystem;
      if (data.containsKey(platform)) {
        data[platform].forEach(
          (key, value) {
            LocalStorageService.instance.setValue(key, value);
          },
        );
      } else {
        Log.i("缺少$platform对应平台用户设置备份");
      }
      // 低于v1.8.5需要升级数据
      LocalStorageService.instance.setValue(
        LocalStorageService.kHiveDbVer,
        (data as Map).containsKey(LocalStorageService.kHiveDbVer) ? data[LocalStorageService.kHiveDbVer] : "10805",
      );
      // 同步后直接更新数值
      await AppSettingsController.instance.onInit();
    } catch (e) {
      Log.e("同步用户设置失败：$e", StackTrace.current);
    }
  }

  @override
  void saveRemote(Archive archive, Map<String, dynamic> data) {
    final bytes = utf8.encode(jsonEncode({'data': data}));
    archive.addFile(
      ArchiveFile(fileName, bytes.length, bytes),
    );
  }

  @override
  Map<String, dynamic> merge(Map<String, dynamic> local, Map<String, dynamic> remote) {
    return {...local, ...remote};
  }
}
